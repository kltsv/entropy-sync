/// `vault_daemon` test-spec — "Materializing remote changes (RV4)":
/// the racing-local-edit guards. A remote winner must never overwrite a
/// cursor-less local file (a creation the watcher has not flushed yet), a
/// remote tombstone must never trash one, and an edit based on stale disk
/// content must meet the freshly grafted remote winner as a **real conflict**
/// (a sibling branch) instead of silently fast-forwarding it.
library;

import 'dart:convert';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  test(
      'a remote winner never overwrites a cursor-less local file '
      '(created, not yet ingested)', () async {
    final one = await h.spawn('one');
    final two = await h.spawn('two');
    await h.settle([one, two], rounds: 1);

    // Both devices create the same daily note. Device two's debounce has not
    // flushed (no cursor entry) when device one's version arrives.
    one.write('daily/2026-08-30.md', 'from one\n');
    await one.shell.reconcile(); // one's version reaches the server

    two.write('daily/2026-08-30.md', 'from two\n'); // no ingest yet
    await two.shell.engine.syncNow(); // grafts one's rev as the winner
    await two.shell.materializeChange(two.docId('daily/2026-08-30.md'));

    // Two's content was NOT destroyed: the file is intact and was ingested
    // as a local change (pending push).
    expect(two.file('daily/2026-08-30.md').readAsStringSync(), 'from two\n');
    expect(two.shell.store.pendingPushCount, greaterThan(0));

    // Everything converges; each edit survives in its author's history.
    await h.settle([one, two]);
    expect(two.recordedVersions('daily/2026-08-30.md'),
        contains(sha256OfText('from two\n')));
    final winner = await h.decryptServerText(two, 'daily/2026-08-30.md');
    expect(one.file('daily/2026-08-30.md').readAsStringSync(), winner);
    expect(two.file('daily/2026-08-30.md').readAsStringSync(), winner);
    expect(one.recordedVersions('daily/2026-08-30.md'),
        contains(sha256OfText('from one\n')));
  });

  test('a remote tombstone never trashes a cursor-less recreated file',
      () async {
    final one = await h.spawn('one');
    final two = await h.spawn('two');
    await h.settle([one, two], rounds: 1);
    one.write('note.md', 'v1\n');
    await h.settle([one, two]); // both synced; two holds a cursor

    // Two deletes the file and syncs the tombstone (cursor gone, the
    // id→path index survives)…
    two.file('note.md').deleteSync();
    await two.shell.reconcile();

    // …then recreates the path; the watcher has not flushed (no cursor).
    two.write('note.md', 'recreated on two\n');

    // A newer remote tombstone arrives (another device edited then deleted).
    await h.seedServerDoc(one, 'note.md', utf8.encode('v2 on one\n'));
    await h.deleteServerDoc(one, 'note.md');
    await two.shell.engine.syncNow();
    await two.shell.materializeChange(two.docId('note.md'));

    // Not trashed: the recreated file is intact and rides as a local edit.
    expect(two.file('note.md').readAsStringSync(), 'recreated on two\n');

    // Live beats deleted: the recreation wins everywhere.
    await h.settle([one, two]);
    expect(await h.decryptServerText(two, 'note.md'), 'recreated on two\n');
    expect(one.file('note.md').readAsStringSync(), 'recreated on two\n');
  });

  test(
      'a local edit racing a grafted remote winner becomes a real conflict; '
      'the losing binary is rescued (RV9)', () async {
    final mac = await h.spawn('mac');
    await mac.shell.reconcile();
    final base = [0x89, 0x50, 0x01];
    mac.writeBytes('img/sketch.png', base);
    await mac.shell.reconcile(); // base synced; cursor records the base rev

    // A remote edit reaches the server while the local save has not flushed:
    // the disk differs from the cursor when the pull grafts the remote rev.
    final remote = [0x89, 0x50, 0xaa, 0xaa];
    await h.seedServerDoc(mac, 'img/sketch.png', remote);
    final local = [0x89, 0x50, 0xbb];
    mac.writeBytes('img/sketch.png', local);

    // Continuous-mode ordering: graft FIRST, then the change materializes.
    await mac.shell.engine.syncNow();
    await mac.shell.materializeChange(mac.docId('img/sketch.png'));

    // The racing edit was ingested as a SIBLING of the stale base — a real
    // conflict — not as a child of the fresh remote winner (which would
    // silently drop the remote bytes with no rescue).
    expect(mac.shell.store.conflicts(), hasLength(1));

    await mac.shell.reconcile(); // rescue + resolve + materialize
    await mac.shell.reconcile(); // push the resolution

    // Deterministic winner on disk; the losing bytes rest in history as a
    // `conflict` rescue file — neither edit is lost.
    final onDisk = mac.file('img/sketch.png').readAsBytesSync().toList();
    expect(onDisk, anyOf(equals(local), equals(remote)));
    expect(
        (await h.decryptServerBytes(mac, 'img/sketch.png')).toList(), onDisk);
    final loser = onDisk.toString() == local.toString() ? remote : local;
    final rescues = [
      for (final (header, bytes) in mac.histFiles('img/sketch.png'))
        if (header.type == HistFileType.conflict) bodyOf(bytes).toList(),
    ];
    expect(rescues, hasLength(1));
    expect(rescues.single, loser);
    expect(mac.notifications, hasLength(1));
    expect(mac.shell.store.conflicts(), isEmpty);
  });
}

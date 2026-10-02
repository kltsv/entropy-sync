/// `vault_daemon` test-spec — "First scan and folder ownership" and
/// "Local change detection (R10, RV4)".
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  test(
      'first scan is the initial sync: a clean replica pushes every file '
      '(D5, N8)', () async {
    final mac = h.handleFor('mac');
    mac.write('a.md', 'alpha\n');
    mac.write('notes/b.md', 'beta\n');
    mac.writeBytes('img/c.png', [0x89, 0x50, 0x4e, 0x47, 0x00, 0x01, 0x02]);

    await h.spawn('mac');
    await mac.shell.reconcile();

    final expected = {
      mac.docId('a.md'),
      mac.docId('notes/b.md'),
      mac.docId('img/c.png'),
    };
    // One wire document per file in the replica (plus the pulled `meta`) —
    // no migration step, no pre-existing database consulted.
    expect(
      mac.shell.store.allDocIds.where((id) => id != 'meta').toSet(),
      expected,
    );
    // The server received all three as initial encrypted revisions.
    for (final id in expected) {
      final doc = h.serverStore().get(id);
      expect(doc, isNotNull);
      expect(doc!.deleted, isFalse);
      expect(doc.body!.keys.toSet(), {'v', 'n', 'c'});
      expect(h.serverStore().revsOf(id).length, 1);
    }
    // History begins now: no versions predate the scan.
    expect(Directory(p.join(mac.vaultRoot, '.hist')).existsSync(), isFalse);
  });

  test(
      'an external file write becomes a pushed revision and a history '
      'record (S2, RV6)', () async {
    final mac = h.handleFor('mac');
    mac.write('a.md', 'existing\n');
    await h.spawn('mac');
    await mac.shell.reconcile(); // connected and settled

    // The "editor" is not the daemon: a plain write on disk.
    mac.write('notes/todo.md', '# Todo\n- buy milk\n');
    await mac.shell.reconcile();

    // Encrypted and pushed: the server received ciphertext under the HMAC id.
    final id = mac.docId('notes/todo.md');
    final doc = h.serverStore().get(id);
    expect(doc, isNotNull);
    expect(doc!.body!.keys.toSet(), {'v', 'n', 'c'});
    expect(jsonEncode(doc.body), isNot(contains('buy milk')));
    expect(await h.decryptServerText(mac, 'notes/todo.md'),
        '# Todo\n- buy milk\n');

    // `localState(notes/todo.md, content)` was called: a version appears
    // under `.hist/notes/todo.md/`, recorded by this machine.
    final headers = mac.histHeaders('notes/todo.md');
    expect(headers, hasLength(1));
    expect(headers.single.type, HistFileType.snapshot);
    expect(headers.single.version, sha256OfText('# Todo\n- buy milk\n'));
    expect(headers.single.writer, 'mac');
  });

  test('deleting a file pushes a delete and records absence (RV6)', () async {
    final mac = h.handleFor('mac');
    mac.write('a.md', 'to be deleted\n');
    await h.spawn('mac');
    await mac.shell.reconcile(); // a.md synced

    mac.file('a.md').deleteSync();
    await mac.shell.reconcile();

    // A tombstone on the wire.
    final doc = h.serverStore().get(mac.docId('a.md'));
    expect(doc, isNotNull);
    expect(doc!.deleted, isTrue);

    // `localState(a.md, absent)`: history records the deletion.
    final headers = mac.histHeaders('a.md');
    expect(headers, hasLength(1));
    expect(headers.single.type, HistFileType.deleted);
    expect(headers.single.prev, sha256OfText('to be deleted\n'));
    expect(headers.single.writer, 'mac');
  });

  test(
      'rapid successive writes coalesce through the per-path debounce '
      '(R10, RV4)', () async {
    final mac = await h.spawn('mac');
    await mac.shell.reconcile(); // connected and settled

    // Five rapid writes to foo.md and one to bar.md land within one debounce
    // window; only the final state of each path is flushed (the per-path
    // debounce flush is `ingestPath` — the seam the real watcher drives).
    for (var i = 1; i <= 5; i++) {
      mac.write('foo.md', 'draft $i\n');
    }
    mac.write('bar.md', 'bar once\n');
    await mac.shell.ingestPath('foo.md');
    await mac.shell.ingestPath('bar.md');
    await mac.shell.reconcile(); // settle: push

    // foo.md yields ONE pushed revision carrying the final content — not
    // five; bar.md debounced independently into its own single revision.
    final fooId = mac.docId('foo.md');
    expect(h.serverStore().revsOf(fooId).length, 1);
    expect(await h.decryptServerText(mac, 'foo.md'), 'draft 5\n');
    final barId = mac.docId('bar.md');
    expect(h.serverStore().revsOf(barId).length, 1);
    expect(await h.decryptServerText(mac, 'bar.md'), 'bar once\n');

    // History too saw only the final state — no intermediate versions.
    expect(mac.recordedVersions('foo.md'), {sha256OfText('draft 5\n')});
  });

  test('unchanged files are skipped by the mtime+size fast path (RV4)',
      () async {
    final mac = h.handleFor('mac');
    mac.write('a.md', 'alpha\n');
    mac.write('notes/b.md', 'beta\n');
    await h.spawn('mac');
    await mac.shell.reconcile(); // settled

    mac.hashes = 0;
    await mac.shell.scanDisk(); // a full rescan with no file modified

    // No file content was read or hashed — mtime + size matched
    // `last_synced` for every path — and nothing was pushed.
    expect(mac.hashes, 0);
    expect(mac.shell.store.pendingPushCount, 0);
    expect(h.serverStore().revsOf(mac.docId('a.md')).length, 1);
  });

  test('a touched-but-identical file is hashed once and not pushed (RV4)',
      () async {
    final mac = h.handleFor('mac');
    mac.write('a.md', 'alpha\n');
    await h.spawn('mac');
    await mac.shell.reconcile(); // settled

    // Bump the mtime without changing the bytes.
    final bumped = DateTime.now().add(const Duration(seconds: 3));
    mac.file('a.md').setLastModifiedSync(bumped);

    mac.hashes = 0;
    await mac.shell.scanDisk();

    // The changed mtime forced exactly one content hash; the hash equalled
    // `last_synced`, so no revision was pushed and no history version was
    // written.
    expect(mac.hashes, 1);
    expect(mac.shell.store.pendingPushCount, 0);
    expect(h.serverStore().revsOf(mac.docId('a.md')).length, 1);
    expect(mac.histDir('a.md').existsSync(), isFalse);
  });

  test('the startup scan catches edits made while the daemon was down (R10)',
      () async {
    final mac = h.handleFor('mac');
    mac.write('a.md', 'one\n');
    await h.spawn('mac');
    await mac.shell.reconcile(); // settled
    await mac.shell.stop(); // the daemon goes down

    // Edits made behind the daemon's back.
    mac.write('a.md', 'two\n');
    mac.write('new.md', 'fresh\n');

    // The daemon starts again: same state root, persisted replica + cursor.
    await h.spawn('mac');
    await mac.shell.reconcile(); // the startup scan

    // Both disk ≠ last_synced differences were treated as local edits:
    // encrypted, pushed, and recorded to history via `localState`.
    expect(h.serverStore().revsOf(mac.docId('a.md')).length, 2);
    expect(await h.decryptServerText(mac, 'a.md'), 'two\n');
    expect(await h.decryptServerText(mac, 'new.md'), 'fresh\n');
    expect(mac.recordedVersions('a.md'), contains(sha256OfText('two\n')));
    expect(mac.recordedVersions('new.md'), contains(sha256OfText('fresh\n')));
  });

  test('the periodic rescan catches events the watcher missed (R10)', () async {
    // No watcher is wired at all here — the "suppressed watcher".
    final mac = await h.spawn('mac');
    await mac.shell.reconcile(); // settled

    mac.write('b.md', 'missed by the watcher\n');
    // The rescan period elapses: the periodic timer fires exactly
    // `shell.reconcile()` (see `bin/entropyd.dart` `_run`).
    await mac.shell.reconcile();

    // The rescan detected disk ≠ last_synced and ingested the edit exactly
    // as if the watcher had fired — pushed and history-recorded.
    expect(await h.decryptServerText(mac, 'b.md'), 'missed by the watcher\n');
    expect(mac.recordedVersions('b.md'),
        {sha256OfText('missed by the watcher\n')});
  });
}

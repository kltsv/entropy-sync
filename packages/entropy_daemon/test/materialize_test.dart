/// `vault_daemon` test-spec — "Materializing remote changes (RV4)".
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  test(
      'a remote change is materialized atomically with metadata and '
      'baseline updated (RV4, RV6)', () async {
    final phone = await h.spawn('phone');
    await phone.shell.reconcile(); // connected and settled

    // A new revision of x.md lands on the fake server, from "another
    // device" (same key material; a whole second in the past so the mtime
    // assertion is meaningful).
    final docMtime =
        ((DateTime.now().millisecondsSinceEpoch ~/ 1000) - 3600) * 1000;
    await h.seedServerDoc(phone, 'x.md', utf8.encode('remote content\n'),
        mtime: docMtime);

    await phone.shell.reconcile();

    // The complete new content is on disk; no temp file leaked (the write
    // went through temp-in-same-directory + rename).
    expect(phone.file('x.md').readAsStringSync(), 'remote content\n');
    expect(
      phone.vaultPaths().where((rel) => rel.contains('.entropy-sync.tmp')),
      isEmpty,
    );

    // The file's mtime came from the logical document.
    final mtime = phone.file('x.md').statSync().modified.millisecondsSinceEpoch;
    expect((mtime - docMtime).abs(), lessThan(1000));

    // `last_synced` was updated…
    expect(
        phone.shell.lastSynced['x.md']?.hash, sha256OfText('remote content\n'));
    // …and `remoteApplied(x.md, content)` recorded NO version — receivers
    // never record synced changes (RV6).
    expect(phone.histDir('x.md').existsSync(), isFalse);
    expect(phone.shell.store.pendingPushCount, 0);
  });

  test('a pulled revision does not echo back as a new edit (RV4)', () async {
    final one = await h.spawn('one');
    final two = await h.spawn('two');
    await h.settle([one, two], rounds: 1);

    one.write('x.md', 'made on device one\n');
    await h.settle([one, two]);

    // x.md appeared on D2's disk with the same content.
    expect(two.file('x.md').readAsStringSync(), 'made on device one\n');

    // D2 updated `last_synced` before its own write became visible: the
    // materialization did not enqueue a spurious push — no echo loop, no new
    // revision minted for the pulled content.
    expect(two.shell.store.pendingPushCount, 0);
    expect(h.serverStore().revsOf(one.docId('x.md')).length, 1);

    await two.shell.reconcile(); // even further passes mint nothing
    expect(h.serverStore().revsOf(one.docId('x.md')).length, 1);
    expect(two.shell.store.pendingPushCount, 0);
  });

  test(
      'a local edit racing a pull is ingested first; the daemon never '
      'merges (R9)', () async {
    final mac = await h.spawn('mac');
    await mac.shell.reconcile();
    mac.write('foo.md', 'base\n');
    await mac.shell.reconcile(); // base pushed, history root recorded

    // A remote revision is pending on the server…
    await h.seedServerDoc(mac, 'foo.md', utf8.encode('base\nremote v2\n'));
    // …and before materialization the on-disk file is edited locally.
    mac.write('foo.md', 'base\nlocal v2\n');

    await mac.shell.reconcile();
    await mac.shell.reconcile(); // push the conflict resolution

    // The local edit was ingested first — encrypted, pushed, and recorded
    // via `localState`; it is not lost.
    expect(mac.recordedVersions('foo.md'),
        contains(sha256OfText('base\nlocal v2\n')));

    // The two revisions met in the server's conflict machinery: the tree
    // carries the base, both competing revisions, and the resolution
    // tombstone.
    final revs = h.serverStore().revsOf(mac.docId('foo.md'));
    expect(revs.length, greaterThanOrEqualTo(4));

    // No content merge: the surviving file is exactly one of the two
    // versions, byte for byte, and matches the server's winner.
    final onDisk = mac.file('foo.md').readAsStringSync();
    expect(['base\nlocal v2\n', 'base\nremote v2\n'], contains(onDisk));
    expect(await h.decryptServerText(mac, 'foo.md'), onDisk);
  });

  test('a remote deletion moves the file to the system trash (RV4)', () async {
    final mac = h.handleFor('mac');
    mac.write('gone.md', 'still here\n');
    await h.spawn('mac');
    await mac.shell.reconcile(); // gone.md synced

    // The document is deleted on the fake server by "another device".
    await h.deleteServerDoc(mac, 'gone.md');
    await mac.shell.reconcile();

    // gone.md left the vault into the trash — recoverable, never
    // irreversibly unlinked. (The shell is constructed with the
    // deterministic state-dir trash target; the production default is the
    // OS trash with this same directory as fallback.)
    expect(mac.file('gone.md').existsSync(), isFalse);
    final trashed = File('${mac.trashDir}/gone.md');
    expect(trashed.existsSync(), isTrue);
    expect(trashed.readAsStringSync(), 'still here\n');

    // `remoteApplied(gone.md, absent)`: this daemon records no history
    // version for the deletion, and the cursor forgets the path.
    expect(mac.histDir('gone.md').existsSync(), isFalse);
    expect(mac.shell.lastSynced['gone.md'], isNull);
  });
}

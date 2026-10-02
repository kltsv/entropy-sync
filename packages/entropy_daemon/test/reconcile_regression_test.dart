/// `vault_daemon` test-spec — reconcile-pass regressions: passes
/// serialize behind a per-shell mutex (a concurrent request coalesces into
/// one following pass), a no-op reconcile decrypts nothing (the cursor's
/// recorded revision skips unchanged winners), the surfaced conflict list is
/// rebuilt from the store's live conflicts (resolved ones drop off), and
/// files above the inline threshold ingest through the constant-memory
/// streamed encryption path.
library;

import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  test('overlapping reconcile requests serialize and coalesce (one pass)',
      () async {
    final mac = await h.spawn('mac');
    await mac.shell.reconcile();
    mac.write('x.md', 'one\n');

    // A reconcile requested while one is queued joins it…
    final f1 = mac.shell.reconcile();
    final f2 = mac.shell.reconcile();
    expect(identical(f1, f2), isTrue,
        reason: 'a second concurrent request coalesces into the queued pass');
    // …and overlapping requests never interleave: exactly one revision is
    // minted for the edit, no matter how many passes were requested.
    await Future.wait([f1, f2, mac.shell.reconcile()]);
    await mac.shell.reconcile();

    expect(h.serverStore().revsOf(mac.docId('x.md')).length, 1);
    expect(mac.recordedVersions('x.md'), {sha256OfText('one\n')});
    expect(mac.shell.store.pendingPushCount, 0);
  });

  test('a no-op reconcile hashes and decrypts nothing (rev-keyed skip)',
      () async {
    final mac = h.handleFor('mac');
    mac.write('a.md', 'alpha\n');
    mac.writeBytes('img/pic.png', List<int>.generate(4096, (i) => i % 251));
    await h.spawn('mac');
    await mac.shell.reconcile();
    await mac.shell.reconcile(); // settle cursor revisions

    mac.hashes = 0;
    await mac.shell.reconcile();

    // Nothing changed anywhere: the scan's mtime+size fast path skips every
    // file, and materialization skips every document by its recorded winner
    // revision — no content is hashed (and hence nothing was decrypted).
    expect(mac.hashes, 0);
    expect(mac.shell.store.pendingPushCount, 0);
  });

  test('resolved conflicts drop off the conflict list on the next reconcile',
      () async {
    final mac = await h.spawn('mac');
    await mac.shell.reconcile();
    mac.writeBytes('img/pic.png', [0x00, 0x01, 0x02]);
    await mac.shell.reconcile(); // base synced

    // A remote binary edit and a different local one form a live conflict.
    await h.seedServerDoc(mac, 'img/pic.png', [0x00, 0xaa, 0xab]);
    mac.writeBytes('img/pic.png', [0x00, 0xba]);
    await mac.shell.ingestPath('img/pic.png');
    await mac.shell.reconcile(); // rescue + resolve happen in-pass

    expect(mac.shell.conflictPaths, contains('img/pic.png'));

    // The conflict is resolved: the next pass rebuilds the list from the
    // store's live conflicts and the entry drops off (no unbounded growth).
    await mac.shell.reconcile();
    expect(mac.shell.store.conflicts(), isEmpty);
    expect(mac.shell.conflictPaths, isEmpty);
  });

  test(
      'a file above the inline threshold ingests through the streamed path '
      'and round-trips byte-for-byte', () async {
    final mac = await h.spawn('mac', inlineThresholdBytes: 64);
    await mac.shell.reconcile();

    final big = List<int>.generate(3000, (i) => (i * 7) % 251);
    mac.writeBytes('media/blob.bin', big);
    mac.hashes = 0;
    await mac.shell.reconcile();

    // The whole-bytes hasher seam was never fed the large content: its
    // digest was computed from the stream, and encryption ran from disk
    // through `encryptStreamed` (constant memory).
    expect(mac.hashes, 0);
    expect(mac.shell.store.pendingPushCount, 0);
    expect(mac.shell.lastSynced['media/blob.bin']?.hash, sha256Of(big));

    // It rode as an encrypted attachment, not an inline body.
    final doc = h.serverStore().get(mac.docId('media/blob.bin'));
    expect(doc, isNotNull);
    expect(doc!.attachment, isNotNull);

    // A second device materializes the exact original bytes.
    final desk = await h.spawn('desk', inlineThresholdBytes: 64);
    await desk.shell.reconcile();
    expect(desk.file('media/blob.bin').readAsBytesSync().toList(), big);
  });
}

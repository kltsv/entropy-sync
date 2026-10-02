/// `vault_daemon` test-spec — "First scan and folder ownership": a
/// fresh replica must not treat a **populated** database as D5's initial
/// sync. The initial reconcile pulls first: files identical to the pulled
/// winners repair the cursor without minting revisions, differing files
/// become real local edits that meet the pulled winner in the conflict
/// machinery, and brand-new files push as recorded local edits. Seeding
/// (baseline-only history) remains exclusive to an empty database.
library;

import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  test(
      're-attaching a restored vault to a populated database repairs the '
      'cursor instead of reseeding (D5 scope)', () async {
    // Device one populates the database; edited.md reaches generation 2.
    final one = await h.spawn('one');
    await one.shell.reconcile();
    one.write('notes/same.md', 'unchanged content\n');
    one.write('notes/edited.md', 'server version\n');
    await one.shell.reconcile();
    one.write('notes/edited.md', 'server version v2\n');
    await one.shell.reconcile();

    // "Restore from backup": a machine with the vault FILES but no state —
    // one file identical to the server, one edited offline, one brand new.
    final back = h.handleFor('backup');
    back.write('notes/same.md', 'unchanged content\n');
    back.write('notes/edited.md', 'offline local edit\n');
    back.write('notes/new.md', 'created offline\n');
    await h.spawn('backup');
    await back.shell.reconcile();
    await h.settle([one, back]);

    // Identical file: the cursor was repaired — no revision minted, no
    // same-content conflict, no notification flood.
    expect(h.serverStore().revsOf(back.docId('notes/same.md')).length, 1);
    expect(back.notifications.where((n) => n.contains('same.md')), isEmpty);
    expect(
        back.file('notes/same.md').readAsStringSync(), 'unchanged content\n');

    // Brand-new file: a REAL local edit — pushed and recorded to history by
    // this machine (not a baseline-only seed).
    expect(
        await h.decryptServerText(back, 'notes/new.md'), 'created offline\n');
    final newRecords = back
        .histHeaders('notes/new.md')
        .where((e) => e.version == sha256OfText('created offline\n'))
        .toList();
    expect(newRecords, isNotEmpty);
    expect(newRecords.first.writer, 'backup');

    // Differing file: a real conflict — the offline edit was recorded by
    // this machine, both versions survive, and everything converges on one
    // deterministic winner.
    final editRecords = back
        .histHeaders('notes/edited.md')
        .where((e) => e.version == sha256OfText('offline local edit\n'))
        .toList();
    expect(editRecords, isNotEmpty,
        reason: 'the offline local edit must be recorded, not silently lost');
    expect(editRecords.first.writer, 'backup');
    final winner = await h.decryptServerText(one, 'notes/edited.md');
    expect(['offline local edit\n', 'server version v2\n'], contains(winner));
    expect(back.file('notes/edited.md').readAsStringSync(), winner);
    expect(one.file('notes/edited.md').readAsStringSync(), winner);
  });

  test('the first scan into an EMPTY database still seeds and pushes (D5)',
      () async {
    final mac = h.handleFor('mac');
    mac.write('a.md', 'alpha\n');
    await h.spawn('mac');
    await mac.shell.reconcile();

    // Seed semantics: pushed as a single initial revision, history baseline
    // only — no version recorded until the first real edit.
    expect(h.serverStore().revsOf(mac.docId('a.md')).length, 1);
    expect(await h.decryptServerText(mac, 'a.md'), 'alpha\n');
    expect(mac.histDir('a.md').existsSync(), isFalse);

    // The first real edit anchors history as usual.
    mac.write('a.md', 'alpha v2\n');
    await mac.shell.reconcile();
    expect(mac.recordedVersions('a.md'), contains(sha256OfText('alpha v2\n')));
  });
}

/// `vault_daemon` test-spec — "Rename detection with marker linking
/// (R16, RV7)".
library;

import 'package:entropy_hist/entropy_hist.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  /// A settled vault with `notes/a.md` and existing versions under
  /// `.hist/notes/a.md/`.
  Future<VaultHandle> vaultWithHist(String content) async {
    final mac = await h.spawn('mac');
    await mac.shell.reconcile();
    mac.write('notes/a.md', content);
    await mac.shell.reconcile(); // pushed + root snapshot recorded
    expect(mac.recordedVersions('notes/a.md'), isNotEmpty);
    return mac;
  }

  test(
      'a content-hash match within the window is a rename: wire tombstone + '
      'create, history marker pair (RV7)', () async {
    const content = 'the moved note body\n';
    final mac = await vaultWithHist(content);
    final oldFiles =
        mac.histHeaders('notes/a.md').map((e) => e.filename).toSet();

    // Within the debounce window: notes/a.md disappears, notes/b.md appears
    // with the same content — one scan sees both.
    mac.file('notes/a.md').deleteSync();
    mac.write('notes/b.md', content);
    await mac.shell.reconcile();

    // On the wire the old id is tombstoned and a new document is created —
    // ids are path-derived; there is no "move" operation.
    expect(h.serverStore().get(mac.docId('notes/a.md'))!.deleted, isTrue);
    expect(h.serverStore().get(mac.docId('notes/b.md'))!.deleted, isFalse);
    expect(await h.decryptServerText(mac, 'notes/b.md'), content);

    // History: the old folder gains a `deleted` marker with `renamed_to`…
    final aHeaders = mac.histHeaders('notes/a.md');
    final marker = aHeaders.where((e) => e.type == HistFileType.deleted).single;
    expect(marker.renamedTo, 'notes/b.md');
    expect(marker.prev, sha256OfText(content));
    // …the new folder gains a `snapshot` with `renamed_from`…
    final bHeaders = mac.histHeaders('notes/b.md');
    final snapshot =
        bHeaders.where((e) => e.type == HistFileType.snapshot).single;
    expect(snapshot.renamedFrom, 'notes/a.md');
    expect(snapshot.version, sha256OfText(content));
    // …and NO history folder was moved or renamed: the old folder keeps all
    // its prior versions in place.
    final aFilesNow = aHeaders.map((e) => e.filename).toSet();
    expect(aFilesNow.containsAll(oldFiles), isTrue);
  });

  test(
      'no match degrades to delete + create without losing old history '
      '(R16)', () async {
    final mac = await vaultWithHist('the original note\n');
    final oldFiles =
        mac.histHeaders('notes/a.md').map((e) => e.filename).toSet();

    // The appeared file carries very different content — no hash match.
    mac.file('notes/a.md').deleteSync();
    mac.write('notes/b.md', 'something entirely unrelated\n');
    await mac.shell.reconcile();

    // notes/a.md is tombstoned; notes/b.md is a fresh document.
    expect(h.serverStore().get(mac.docId('notes/a.md'))!.deleted, isTrue);
    expect(await h.decryptServerText(mac, 'notes/b.md'),
        'something entirely unrelated\n');

    // `.hist/notes/a.md/` is preserved in place (append-only): the old
    // versions remain, joined by a plain `deleted` marker.
    final aHeaders = mac.histHeaders('notes/a.md');
    expect(
        aHeaders.map((e) => e.filename).toSet().containsAll(oldFiles), isTrue);
    final marker = aHeaders.where((e) => e.type == HistFileType.deleted).single;
    expect(marker.prev, sha256OfText('the original note\n'));

    // notes/b.md starts a fresh history root; NO rename markers anywhere.
    final bHeaders = mac.histHeaders('notes/b.md');
    expect(bHeaders.single.type, HistFileType.snapshot);
    expect(bHeaders.single.version,
        sha256OfText('something entirely unrelated\n'));
    for (final header in [...aHeaders, ...bHeaders]) {
      expect(header.renamedTo, isNull);
      expect(header.renamedFrom, isNull);
    }
  });

  test('empty files are never rename-paired (R16)', () async {
    final mac = await h.spawn('mac');
    await mac.shell.reconcile();
    mac.write('notes/scratch.md', '');
    await mac.shell.reconcile(); // empty note synced

    // In one window: the empty note vanishes and an unrelated empty note
    // appears (all empty files share one hash — pairing them would link two
    // unrelated files in append-only history forever).
    mac.file('notes/scratch.md').deleteSync();
    mac.write('drafts/chapter1.md', '');
    await mac.shell.reconcile();

    // Plain delete + create — no rename linkage.
    expect(h.serverStore().get(mac.docId('notes/scratch.md'))!.deleted, isTrue);
    expect(
        h.serverStore().get(mac.docId('drafts/chapter1.md'))!.deleted, isFalse);
    for (final header in [
      ...mac.histHeaders('notes/scratch.md'),
      ...mac.histHeaders('drafts/chapter1.md'),
    ]) {
      expect(header.renamedTo, isNull);
      expect(header.renamedFrom, isNull);
    }
  });

  test('ambiguous duplicate-content matches degrade to delete + create (R16)',
      () async {
    const tpl = 'the shared template body\n';
    final mac = await h.spawn('mac');
    await mac.shell.reconcile();
    mac.write('notes/a.md', tpl);
    mac.write('notes/b.md', tpl);
    await mac.shell.reconcile(); // two identical notes synced

    // Both disappear and ONE file with the same content appears in the same
    // window: which one "moved" is a pure guess — so nobody guesses.
    mac.file('notes/a.md').deleteSync();
    mac.file('notes/b.md').deleteSync();
    mac.write('notes/c.md', tpl);
    await mac.shell.reconcile();

    expect(h.serverStore().get(mac.docId('notes/a.md'))!.deleted, isTrue);
    expect(h.serverStore().get(mac.docId('notes/b.md'))!.deleted, isTrue);
    expect(await h.decryptServerText(mac, 'notes/c.md'), tpl);
    for (final header in [
      ...mac.histHeaders('notes/a.md'),
      ...mac.histHeaders('notes/b.md'),
      ...mac.histHeaders('notes/c.md'),
    ]) {
      expect(header.renamedTo, isNull);
      expect(header.renamedFrom, isNull);
    }
  });
}

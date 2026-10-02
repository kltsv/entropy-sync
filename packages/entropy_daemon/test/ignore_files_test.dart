/// `vault_daemon` test-spec — "Ignore files (RV8)": the `.syncignore` /
/// `.histignore` vault ignore files, the documented gitignore pattern subset
/// they share with the profile exclusion list, and the no-tombstone rule for
/// paths that *become* excluded.
library;

import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:entropy_sync/entropy_sync.dart';
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('ignore pattern engine (RV8 syntax subset)', () {
    ExclusionMatcher m(List<String> patterns) => ExclusionMatcher(patterns);

    test('a pattern without / is a basename glob at any depth', () {
      final basename = m(['draft.md']);
      expect(basename.excludes('draft.md'), isTrue);
      expect(basename.excludes('notes/draft.md'), isTrue);
      expect(basename.excludes('a/b/c/draft.md'), isTrue);
      expect(basename.excludes('drafts.md'), isFalse);
      expect(basename.excludes('notes/mydraft.md'), isFalse);

      final glob = m(['*.tmp']);
      expect(glob.excludes('x.tmp'), isTrue);
      expect(glob.excludes('a/b/c.tmp'), isTrue);
      expect(glob.excludes('x.tmpz'), isFalse);
      expect(glob.excludes('x.md'), isFalse);
    });

    test('a matching directory segment excludes everything beneath it', () {
      final byName = m(['build']);
      expect(byName.excludes('build'), isTrue);
      expect(byName.excludes('a/build/x.md'), isTrue,
          reason: 'the directory named build is ignored, so its contents are');
      expect(byName.excludes('builds/x.md'), isFalse);

      final byGlob = m(['*.tmp']);
      expect(byGlob.excludes('a.tmp/inside.md'), isTrue);
    });

    test(
        'a pattern with / is anchored at the vault root; a leading / is '
        'stripped and equivalent', () {
      for (final matcher in [
        m(['/inbox/scratch.md']),
        m(['inbox/scratch.md']),
      ]) {
        expect(matcher.excludes('inbox/scratch.md'), isTrue);
        expect(matcher.excludes('sub/inbox/scratch.md'), isFalse);
        expect(matcher.excludes('inbox/scratch.md.bak'), isFalse);
        expect(matcher.excludes('inbox'), isFalse);
      }
    });

    test('a trailing / matches the directory and everything under it', () {
      final matcher = m(['cache/']);
      expect(matcher.excludes('cache'), isTrue);
      expect(matcher.excludes('cache/a.md'), isTrue);
      expect(matcher.excludes('cache/a/b/c.md'), isTrue);
      expect(matcher.excludes('cachex/a.md'), isFalse);
      expect(matcher.excludes('x/cache/a.md'), isFalse, reason: 'anchored');
    });

    test('* matches within one segment in anchored patterns', () {
      final matcher = m(['notes/*.md']);
      expect(matcher.excludes('notes/a.md'), isTrue);
      expect(matcher.excludes('notes/sub/a.md'), isFalse);
      expect(matcher.excludes('notes/a.txt'), isFalse);
    });

    test('** spans segments, including zero', () {
      final middle = m(['assets/**/raw.bin']);
      expect(middle.excludes('assets/raw.bin'), isTrue);
      expect(middle.excludes('assets/a/raw.bin'), isTrue);
      expect(middle.excludes('assets/a/b/c/raw.bin'), isTrue);
      expect(middle.excludes('assets/a/raw.bin.x'), isFalse);
      expect(middle.excludes('raw.bin'), isFalse);

      final leading = m(['**/build/']);
      expect(leading.excludes('build'), isTrue);
      expect(leading.excludes('a/b/build/x.md'), isTrue);
      expect(leading.excludes('a/builder/x.md'), isFalse);

      final trailing = m(['gen/**']);
      expect(trailing.excludes('gen/a.md'), isTrue);
      expect(trailing.excludes('gen/a/b.md'), isTrue);
      expect(trailing.excludes('genx/a.md'), isFalse);
    });

    test('blank lines, comments, and unsupported negation are skipped', () {
      expect(
        ExclusionMatcher.parseIgnoreLines(
            '# a comment\n\n   \n!keep.md\ndraft.md\n'),
        ['draft.md'],
      );
      // A negation line compiles to nothing: it neither excludes its literal
      // text nor un-excludes anything.
      final matcher = m(['!keep.md', '# note']);
      expect(matcher.excludes('keep.md'), isFalse);
      expect(matcher.excludes('!keep.md'), isFalse);
      expect(matcher.excludes('# note'), isFalse);
    });

    test(
        'the profile exclusion list compiles through the same engine '
        '(byte-compatible defaults)', () {
      final matcher = m(VaultProfile.defaultExclusions);
      expect(matcher.excludes('notes/.DS_Store'), isTrue);
      expect(matcher.excludes('.trash/old.md'), isTrue);
      expect(matcher.excludes('.obsidian/workspace-mobile.json'), isTrue);
      expect(matcher.excludes('sub/.obsidian/workspace.json'), isFalse);
      expect(matcher.excludes('.hist/notes/a.md/x.snapshot'), isFalse);
      expect(matcher.excludes('.obsidian/app.json'), isFalse);
    });

    test('a nested source anchors its patterns to its own directory', () {
      final nested = ExclusionMatcher.fromSources([
        IgnoreSource('notes', ['/drafts/', '*.tmp', 'cache/', 'a/**/b.md']),
      ]);
      // Anchored: binds to notes/, not to the root.
      expect(nested.excludes('notes/drafts'), isTrue);
      expect(nested.excludes('notes/drafts/a.md'), isTrue);
      expect(nested.excludes('drafts/b.md'), isFalse);
      expect(nested.excludes('other/notes/drafts/a.md'), isFalse);
      // Basename: any depth, but only beneath notes/.
      expect(nested.excludes('notes/deep/x.tmp'), isTrue);
      expect(nested.excludes('x.tmp'), isFalse);
      // Directory and double-star forms, likewise relative.
      expect(nested.excludes('notes/cache/c.md'), isTrue);
      expect(nested.excludes('cache/c.md'), isFalse);
      expect(nested.excludes('notes/a/x/y/b.md'), isTrue);
      expect(nested.excludes('a/x/b.md'), isFalse);
      // An ignore file never matches the directory it sits in.
      expect(nested.excludes('notes'), isFalse);
    });

    test('sources are additive: any applicable file excludes', () {
      final matcher = ExclusionMatcher.fromSources([
        IgnoreSource('', ['secret']), // a basename: any depth
        IgnoreSource('sub', ['!secret', 'local.md']),
      ]);
      expect(matcher.excludes('sub/secret/x.md'), isTrue,
          reason: 'the nested negation is inert — nothing re-includes');
      expect(matcher.excludes('secret/y.md'), isTrue);
      expect(matcher.excludes('sub/local.md'), isTrue);
      expect(matcher.excludes('other/local.md'), isFalse);
    });
  });

  group('IgnoreFileTree', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('entropy-ignore'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    void write(String rel, String content) {
      final f = File(p.join(tmp.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    test('re-reads offered files by mtime+size and reports rule changes', () {
      final tree = IgnoreFileTree(tmp.path, names: {'.syncignore'});
      expect(tree.offer('notes/.syncignore'), isTrue);
      expect(tree.offer('notes/a.md'), isFalse, reason: 'not a rule file');
      expect(tree.refresh(), isFalse, reason: 'missing file, no rules yet');
      expect(tree.known, isEmpty,
          reason: 'a file that is not there is dropped');

      write('notes/.syncignore', 'a.md\n');
      tree.offer('notes/.syncignore');
      expect(tree.refresh(), isTrue);
      expect(tree.sources('.syncignore').single.dir, 'notes');
      expect(tree.sources('.syncignore').single.patterns, ['a.md']);
      expect(tree.refresh(), isFalse, reason: 'unchanged mtime+size');

      write('notes/.syncignore', '# off\nb.md\n');
      expect(tree.refresh(), isTrue);
      expect(tree.sources('.syncignore').single.patterns, ['b.md']);

      File(p.join(tmp.path, 'notes/.syncignore')).deleteSync();
      expect(tree.refresh(), isTrue, reason: 'rules dropped with the file');
      expect(tree.sources('.syncignore'), isEmpty);
      expect(tree.refresh(), isFalse);
    });

    test('discover walks the tree for every tracked name', () {
      write('.syncignore', 'x\n');
      write('a/b/.histignore', 'y\n');
      write('a/.syncignore', 'z\n');
      write('a/note.md', 'not a rule file');
      final tree =
          IgnoreFileTree(tmp.path, names: {'.syncignore', '.histignore'});
      tree.discover();
      expect(tree.refresh(), isTrue);
      expect(tree.sources('.syncignore').map((s) => s.dir), ['', 'a']);
      expect(tree.sources('.histignore').map((s) => s.dir), ['a/b']);
      expect(tree.sources('.histignore').single.patterns, ['y']);
    });
  });

  group('Ignore files (RV8)', () {
    late Harness h;

    setUp(() async => h = await Harness.start());
    tearDown(() => h.stop());

    test(
        '.syncignore patterns exclude paths from sync in every supported '
        'form', () async {
      final mac = h.handleFor('mac');
      mac.write('.syncignore', '''
# comments and blank lines change nothing

!negation.md
draft.md
/inbox/scratch.md
cache/
*.tmp
assets/**/raw.bin
''');
      // One file per pattern form…
      mac.write('draft.md', 'basename at root');
      mac.write('notes/draft.md', 'basename at depth');
      mac.write('inbox/scratch.md', 'anchored');
      mac.write('cache/c.md', 'under ignored dir');
      mac.write('cache/sub/d.md', 'deep under ignored dir');
      mac.write('junk/x.tmp', 'basename glob');
      mac.write('assets/raw.bin', 'double-star, zero segments');
      mac.write('assets/deep/nested/raw.bin', 'double-star, many segments');
      // …plus controls: an ordinary note, and the file a supported negation
      // WOULD have re-admitted — the `!` line must be inert, not inverted.
      mac.write('notes/keep.md', 'control');
      mac.write('negation.md', 'the ! line is a comment, nothing more');

      await h.spawn('mac');
      await mac.shell.reconcile();

      final expected = {
        mac.docId('.syncignore'), // the ignore file is an ordinary vault file
        mac.docId('notes/keep.md'),
        mac.docId('negation.md'),
      };
      expect(
        h.serverStore().allDocIds.where((id) => id != 'meta').toSet(),
        expected,
        reason: 'no ignored path produces a document or reaches the server',
      );
      expect(
        mac.shell.store.allDocIds.where((id) => id != 'meta').toSet(),
        expected,
      );
    });

    test(
        'newly ignoring an already-synced path stops sync without deleting '
        'anything', () async {
      final mac = await h.spawn('mac');
      final desk = await h.spawn('desk');
      mac.write('notes/big.md', 'big v1');
      mac.write('notes/same.md', 'same v1');
      await h.settle([mac, desk]);
      expect(desk.file('notes/big.md').readAsStringSync(), 'big v1');
      final sameRevBefore =
          h.serverStore().get(mac.docId('notes/same.md'))!.rev;

      // Ignore both paths; reconcile. The next pass picks the rules up.
      mac.write('.syncignore', 'notes/big.md\nnotes/same.md\n');
      await mac.shell.reconcile();

      // Never tombstoned on the server; local files stay; cursor dropped.
      for (final path in ['notes/big.md', 'notes/same.md']) {
        final serverDoc = h.serverStore().get(mac.docId(path));
        expect(serverDoc, isNotNull);
        expect(serverDoc!.deleted, isFalse,
            reason: 'exclusion is never mistaken for deletion');
        expect(mac.file(path).existsSync(), isTrue);
        expect(mac.shell.lastSynced[path], isNull, reason: 'cursor dropped');
      }
      // The second device keeps its copies (the rules ride along to it too).
      await desk.shell.reconcile();
      expect(desk.file('notes/big.md').readAsStringSync(), 'big v1');
      expect(desk.file('notes/same.md').readAsStringSync(), 'same v1');

      // A local edit while ignored is neither pushed nor hist-recorded.
      mac.write('notes/big.md', 'big v2 edited while ignored');
      await mac.shell.reconcile();
      expect(await h.decryptServerText(mac, 'notes/big.md'), 'big v1');
      expect(mac.recordedVersions('notes/big.md'), isEmpty);
      expect(mac.shell.unsynced, 0);

      // Un-ignore: the next scan re-admits both paths. The edited file is
      // ingested as an ordinary local edit (recorded to history, pushed into
      // the conflict machinery); the untouched file just repairs its cursor,
      // minting no revision.
      mac.write('.syncignore', '# nothing ignored\n');
      await mac.shell.reconcile();
      expect(mac.shell.lastSynced['notes/big.md'], isNotNull);
      expect(mac.shell.lastSynced['notes/same.md'], isNotNull);
      expect(
        mac.recordedVersions('notes/big.md'),
        contains(sha256OfText('big v2 edited while ignored')),
        reason: 'an ordinary local edit is recorded by its author',
      );
      expect(
          h.serverStore().get(mac.docId('notes/same.md'))!.rev, sameRevBefore,
          reason: 'identical content repairs the cursor, minting no revision');
      expect(mac.recordedVersions('notes/same.md'), isEmpty);

      // Both devices converge (desk un-ignores too once the rules sync).
      await h.settle([mac, desk], rounds: 4);
      expect(
        desk.file('notes/big.md').readAsStringSync(),
        mac.file('notes/big.md').readAsStringSync(),
      );
    });

    test('the ignore file itself syncs, so rules are shared across devices',
        () async {
      final mac = await h.spawn('mac');
      mac.write('.syncignore', 'secret/\n');
      await mac.shell.reconcile();

      final desk = await h.spawn('desk');
      await desk.shell.reconcile();
      expect(desk.file('.syncignore').existsSync(), isTrue,
          reason: '.syncignore materializes as an ordinary file');
      expect(desk.file('.syncignore').readAsStringSync(), 'secret/\n');

      // The receiving shell honors the pulled rules on its next pass.
      desk.write('secret/x.md', 'must not sync');
      await desk.shell.reconcile();
      expect(desk.shell.store.get(desk.docId('secret/x.md')), isNull);
      expect(h.serverStore().get(desk.docId('secret/x.md')), isNull);
    });

    test('a remote change for an ignored path is not materialized', () async {
      // B pushes the file first (the rule file has not propagated to B).
      final desk = await h.spawn('desk');
      desk.write('notes/skip.md', 'from desk');
      await desk.shell.reconcile();

      // A ignores the path locally, then pulls.
      final mac = h.handleFor('mac');
      mac.write('.syncignore', 'notes/skip.md\n');
      await h.spawn('mac');
      await mac.shell.reconcile();

      expect(mac.shell.store.get(mac.docId('notes/skip.md')), isNotNull,
          reason: 'replication is document-level: the doc IS grafted');
      expect(mac.file('notes/skip.md').existsSync(), isFalse,
          reason: 'but never written into the vault');
      expect(mac.shell.lastSynced['notes/skip.md'], isNull);

      // Another pass (the memoized ignored-doc path) changes nothing.
      await mac.shell.reconcile();
      expect(mac.file('notes/skip.md').existsSync(), isFalse);
      expect(mac.shell.lastSynced['notes/skip.md'], isNull);
    });

    test(
        'nested ignore files anchor to their directory and travel with the '
        'vault', () async {
      final mac = h.handleFor('mac');
      mac.write('notes/.syncignore', '/drafts/\n');
      mac.write('notes/.histignore', 'scratch.md\n');
      mac.write('notes/drafts/a.md', 'never synced');
      mac.write('drafts/b.md', 'synced — the anchor is notes/, not the root');
      mac.write('notes/scratch.md', 'synced, not tracked');
      mac.write('deep/scratch.md', 'synced and tracked');
      mac.write('notes/keep.md', 'control');
      // A draft in this machine's working state must never become a document.
      mac.write('.hist-state/merge/notes/keep.md.draft', '<<<<<<< live');
      await h.spawn('mac');
      await mac.shell.reconcile();

      expect(h.serverStore().get(mac.docId('notes/drafts/a.md')), isNull);
      expect(h.serverStore().get(mac.docId('drafts/b.md')), isNotNull);
      expect(h.serverStore().get(mac.docId('notes/keep.md')), isNotNull);
      expect(
        h.serverStore().get(mac.docId('.hist-state/merge/notes/keep.md.draft')),
        isNull,
        reason: '.hist-state/ is a built-in exclusion',
      );

      // The rules travel: both nested files materialize on the second device.
      final desk = await h.spawn('desk');
      await desk.shell.reconcile();
      expect(desk.file('notes/.syncignore').readAsStringSync(), '/drafts/\n');
      expect(desk.file('notes/.histignore').readAsStringSync(), 'scratch.md\n');

      // …and are honoured there: the basename pattern reaches only beneath
      // notes/.
      desk.write('notes/scratch.md', 'edited on desk');
      desk.write('deep/scratch.md', 'edited on desk too');
      await desk.shell.reconcile(); // ingest + version cut (idle 0)
      await desk.shell.reconcile(); // flush hist files
      expect(desk.histDir('notes/scratch.md').existsSync(), isFalse,
          reason: 'hist-ignored beneath notes/');
      expect(desk.recordedVersions('deep/scratch.md'),
          contains(sha256OfText('edited on desk too')));
      desk.write('notes/drafts/c.md', 'never synced from desk either');
      await desk.shell.reconcile();
      expect(h.serverStore().get(desk.docId('notes/drafts/c.md')), isNull);
    });

    test('.histignore excludes from history tracking but not from sync',
        () async {
      final mac = h.handleFor('mac');
      mac.write('.histignore', 'journal/\n');
      mac.write('journal/day.md', 'day v1');
      mac.write('notes/a.md', 'a v1');
      await h.spawn('mac');
      await mac.shell.reconcile(); // first scan seeds baselines

      mac.write('journal/day.md', 'day v2');
      mac.write('notes/a.md', 'a v2');
      await mac.shell.reconcile(); // ingest + version cut (idle 0)
      await mac.shell.reconcile(); // flush hist files → next scan syncs them

      // Both files sync; the ignore file itself synced too.
      expect(await h.decryptServerText(mac, 'journal/day.md'), 'day v2');
      expect(await h.decryptServerText(mac, 'notes/a.md'), 'a v2');
      expect(h.serverStore().get(mac.docId('.histignore')), isNotNull);

      // Only the control file gained history.
      expect(
          mac.recordedVersions('notes/a.md'), contains(sha256OfText('a v2')));
      expect(mac.histDir('journal/day.md').existsSync(), isFalse,
          reason: 'hist-ignored paths gain no history folder');

      // A losing BINARY conflict on a hist-ignored path is still rescued as
      // a `conflict` copy — rescue bypasses the filter (RV9 is data-safety).
      final base = [0x00, 0x01, 0x02, 0x03];
      mac.writeBytes('journal/pic.bin', base);
      await mac.shell.reconcile();
      final remote = [0x00, 0xaa, 0xab, 0xac];
      final local = [0x00, 0xba, 0xbb];
      await h.seedServerDoc(mac, 'journal/pic.bin', remote);
      mac.writeBytes('journal/pic.bin', local);
      await mac.shell.ingestPath('journal/pic.bin');
      await mac.shell.engine.syncNow();
      final report = mac.shell.store.conflicts().single;
      final loserBytes = (await mac.shell.crypto.decryptBody(WireDoc(
        id: report.losers.single.id,
        body: report.losers.single.body,
        deleted: false,
      )))
          .inlineContent!;

      await mac.shell.rescueConflict(report);
      final rescues = [
        for (final (header, bytes) in mac.histFiles('journal/pic.bin'))
          if (header.type == HistFileType.conflict) bodyOf(bytes).toList(),
      ];
      expect(rescues, hasLength(1));
      expect(rescues.single, loserBytes.toList());
      expect(mac.shell.store.conflicts(), isEmpty, reason: 'resolved');
    });

    test(
        'a profile-exclusion change never tombstones an already-synced path '
        '(regression)', () async {
      final mac = await h.spawn('mac');
      mac.write('logs/x.md', 'log v1');
      await mac.shell.reconcile();
      final serverDoc = h.serverStore().get(mac.docId('logs/x.md'));
      expect(serverDoc, isNotNull);
      final revBefore = serverDoc!.rev;

      // The profile is edited to exclude `logs/` — a daemon re-registration
      // replaces the shell over the same state.
      await h.spawn('mac',
          exclusions: [...VaultProfile.defaultExclusions, 'logs/']);
      await mac.shell.reconcile();

      final after = h.serverStore().get(mac.docId('logs/x.md'));
      expect(after, isNotNull);
      expect(after!.deleted, isFalse,
          reason: 'a newly-excluded path must not read as a local deletion');
      expect(after.rev, revBefore);
      expect(mac.file('logs/x.md').existsSync(), isTrue);
      expect(mac.shell.lastSynced['logs/x.md'], isNull,
          reason: 'the cursor entry is dropped instead');
      expect(
        mac
            .histHeaders('logs/x.md')
            .where((e) => e.type == HistFileType.deleted),
        isEmpty,
        reason: 'no phantom deletion recorded to history',
      );
    });
  });
}

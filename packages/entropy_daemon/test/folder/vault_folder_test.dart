/// `vault_folder` test-spec.
///
/// The watcher and the clock are injected, so raw events and quiet periods are
/// driven directly rather than waited for.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as c;
import 'package:entropy_hist/entropy_hist.dart' show ExclusionMatcher;
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late StreamController<String> events;
  late int now;
  late VaultFolder folder;
  late List<FolderState> seen;

  String root() => p.join(tmp.path, 'vault');

  VaultFolder build({List<String> exclusions = const []}) {
    final f = VaultFolder(
      root: root(),
      cursor: FolderCursor(p.join(tmp.path, 'state', 'folder.json')),
      exclusions: exclusions,
      events: events.stream,
      clock: () => now,
      coalesceMillis: 1500,
      trashFallbackDir: p.join(tmp.path, 'trash'),
    );
    seen = [];
    f.states.listen(seen.add);
    return f;
  }

  /// The same service, with the seams the pass-level cases drive: a counting
  /// (or poisoned) whole-content hasher, an inline limit, and an injected
  /// record.
  VaultFolder buildTuned({
    List<String> exclusions = const [],
    int inlineLimitBytes = 1 << 20,
    String Function(List<int> bytes)? hasher,
    FolderCursor? cursor,
  }) {
    final f = VaultFolder(
      root: root(),
      cursor: cursor ?? FolderCursor(p.join(tmp.path, 'state', 'folder.json')),
      exclusions: exclusions,
      events: events.stream,
      clock: () => now,
      inlineLimitBytes: inlineLimitBytes,
      trashFallbackDir: p.join(tmp.path, 'trash'),
      hasher: hasher,
    );
    seen = [];
    f.states.listen(seen.add);
    return f;
  }

  String sha256Hex(List<int> bytes) => c.sha256.convert(bytes).toString();

  void write(String rel, String content) {
    final file = File(p.join(root(), rel));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  /// Let the injected watcher's events reach the service, then let the path
  /// go quiet and emit.
  Future<void> quiet() async {
    await Future<void>.delayed(Duration.zero); // events are delivered async
    now += 2000;
    await folder.settle();
    await Future<void>.delayed(Duration.zero); // the broadcast delivers async
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('folder_');
    Directory(root()).createSync(recursive: true);
    events = StreamController<String>.broadcast();
    now = 1700000000000;
    folder = build();
  });
  tearDown(() async {
    await folder.close();
    await events.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('one owner (R4)', () {
    test('every subscriber gets the same state and the same hash', () async {
      final second = <FolderState>[];
      folder.states.listen(second.add);

      write('a.md', 'hello');
      events.add('a.md');
      await quiet();

      expect(seen, hasLength(1));
      expect(second, hasLength(1));
      expect(identical(seen.single, second.single), isTrue,
          reason: 'hashed once, shared by every subscriber');
      expect(seen.single.hash, isNotNull);
    });

    test('a path escaping the root is refused, and nothing is written',
        () async {
      await expectLater(
        folder.materialize('../escape.md', [1, 2, 3], by: 'sync'),
        throwsA(isA<FolderRefused>()),
      );
      expect(File(p.join(tmp.path, 'escape.md')).existsSync(), isFalse);
      expect(folder.relativeOf(p.join(tmp.path, 'escape.md')), isNull);
    });
  });

  group('raw events become settled states (D7)', () {
    test('an autosave burst is one state', () async {
      write('n.md', 'one');
      events.add('n.md');
      now += 300;
      write('n.md', 'two');
      events.add('n.md');
      now += 300;
      write('n.md', 'final');
      events.add('n.md');
      await quiet();

      expect(seen, hasLength(1));
      expect(String.fromCharCodes(seen.single.content!), 'final');
    });

    test('delete-then-create inside the window is one edit', () async {
      write('n.md', 'before');
      events.add('n.md');
      await quiet();
      seen.clear();

      File(p.join(root(), 'n.md')).deleteSync();
      events.add('n.md');
      now += 200;
      write('n.md', 'after');
      events.add('n.md');
      await quiet();

      expect(seen, hasLength(1));
      expect(seen.single.isAbsent, isFalse,
          reason: 'no life ended — this is one ordinary edit');
      expect(String.fromCharCodes(seen.single.content!), 'after');
    });

    test('an unchanged re-save emits nothing', () async {
      write('n.md', 'same');
      events.add('n.md');
      await quiet();
      seen.clear();

      write('n.md', 'same'); // byte-identical
      events.add('n.md');
      await quiet();

      expect(seen, isEmpty);
    });
  });

  group('attribution (R5)', () {
    test('a materialization names the module that asked', () async {
      await folder.materialize('m.md', 'from sync'.codeUnits, by: 'sync');

      expect(seen, hasLength(1));
      final origin = seen.single.origin;
      expect(origin, isA<Materialized>());
      expect((origin as Materialized).by, 'sync');
      // The bytes are on disk before the state is emitted.
      expect(File(p.join(root(), 'm.md')).readAsStringSync(), 'from sync');
    });

    test('an edit by anything else is local', () async {
      write('e.md', 'typed by a human');
      events.add('e.md');
      await quiet();

      expect(seen.single.origin, isA<LocalEdit>());
    });

    test('attribution survives a late, coalesced watcher event', () async {
      await folder.materialize('m.md', 'written'.codeUnits, by: 'sync');
      seen.clear();

      // The watcher only now reports our own write, mixed into a burst.
      events.add('m.md');
      await quiet();

      expect(seen, isEmpty,
          reason: 'matched by content — never a phantom local edit');
    });

    test('a subscriber acts on the distinction naming no other module',
        () async {
      // This subscriber is the whole point of R2: it mentions no module.
      final recorded = <String>[];
      folder.states.listen((s) {
        if (s.origin is LocalEdit) recorded.add(s.path);
      });

      await folder.materialize('remote.md', 'x'.codeUnits, by: 'sync');
      write('mine.md', 'y');
      events.add('mine.md');
      await quiet();

      expect(recorded, ['mine.md']);
    });
  });

  group('ordering', () {
    test('a pending local edit is emitted before a write on the same path',
        () async {
      write('race.md', 'local edit');
      events.add('race.md');
      await Future<void>.delayed(Duration.zero);
      // Not settled yet — the write arrives now.
      await folder.settleNow('race.md');
      await folder.materialize('race.md', 'remote winner'.codeUnits,
          by: 'sync');
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(2));
      expect(seen.first.origin, isA<LocalEdit>());
      expect(String.fromCharCodes(seen.first.content!), 'local edit');
      expect(seen.last.origin, isA<Materialized>());
    });
  });

  group("the service's own record (R6)", () {
    test('detection works with no subscriber and across restarts', () async {
      write('kept.md', 'v1');
      events.add('kept.md');
      await quiet();
      await folder.close();

      // A new service over the same folder and the same cursor.
      final events2 = StreamController<String>.broadcast();
      final folder2 = VaultFolder(
        root: root(),
        cursor: FolderCursor(p.join(tmp.path, 'state', 'folder.json')),
        events: events2.stream,
        clock: () => now,
        trashFallbackDir: p.join(tmp.path, 'trash'),
      );
      final after = <FolderState>[];
      folder2.states.listen(after.add);

      events2.add('kept.md'); // unchanged since it was last seen
      await Future<void>.delayed(Duration.zero);
      now += 2000;
      await folder2.settle();
      await Future<void>.delayed(Duration.zero);
      expect(after, isEmpty, reason: 'already seen — not new');

      write('kept.md', 'v2'); // changed while nobody was looking
      events2.add('kept.md');
      await Future<void>.delayed(Duration.zero);
      now += 2000;
      await folder2.settle();
      await Future<void>.delayed(Duration.zero);
      expect(after, hasLength(1));

      await folder2.close();
      await events2.close();
    });

    test('a scan gives a late subscriber the folder truth', () async {
      write('a.md', 'one');
      write('b/c.md', 'two');

      final scanned = await folder.scan();

      expect(scanned.keys, containsAll(['a.md', 'b/c.md']));
      expect(scanned['a.md'], isNotEmpty);
    });
  });

  group('exclusions belong to the folder (R7)', () {
    test('an excluded path is invisible and unwritable', () async {
      await folder.close();
      folder = build(exclusions: ['.DS_Store', 'secret/']);

      write('secret/x.md', 'nope');
      events.add('secret/x.md');
      await quiet();
      expect(seen, isEmpty);

      expect((await folder.scan()).keys, isNot(contains('secret/x.md')));
      await expectLater(
        folder.materialize('secret/x.md', [1], by: 'sync'),
        throwsA(isA<FolderRefused>()),
      );
    });
  });

  group('writes (R4)', () {
    test('a materialization is atomic and carries its mtime', () async {
      const when = 1700000123000;
      await folder.materialize('m.md', 'body'.codeUnits,
          by: 'sync', mtimeMillis: when);

      final file = File(p.join(root(), 'm.md'));
      expect(file.readAsStringSync(), 'body');
      expect(file.lastModifiedSync().millisecondsSinceEpoch, when);
      expect(File('${file.path}.entropy-tmp').existsSync(), isFalse,
          reason: 'no temporary file left beside it');
    });

    test('a removal goes to the trash and leaves its directory', () async {
      await folder.materialize('a/b/c.md', 'gone soon'.codeUnits, by: 'sync');
      seen.clear();

      await folder.remove('a/b/c.md', by: 'sync');
      await Future<void>.delayed(Duration.zero);

      expect(File(p.join(root(), 'a/b/c.md')).existsSync(), isFalse);
      expect(Directory(p.join(root(), 'a/b')).existsSync(), isTrue,
          reason: 'another device may be about to fill it');
      expect(seen.single.isAbsent, isTrue);
      expect((seen.single.origin as Materialized).by, 'sync');
    });
  });

  group('a full pass (R6)', () {
    test('an unchanged file is not read or hashed', () async {
      var hashes = 0;
      await folder.close();
      folder = buildTuned(hasher: (bytes) {
        hashes += 1;
        return sha256Hex(bytes);
      });

      write('a.md', 'alpha');
      write('notes/b.md', 'beta');
      expect((await folder.rescan()).states, hasLength(2));
      expect(hashes, 2, reason: 'first sight of each file');

      hashes = 0;
      expect((await folder.rescan()).states, isEmpty);
      expect(hashes, 0, reason: 'size and mtime alone settled it');

      // A touch that changes no bytes costs exactly one hash…
      final file = File(p.join(root(), 'a.md'));
      file.setLastModifiedSync(
        file.lastModifiedSync().add(const Duration(seconds: 3)),
      );
      expect((await folder.rescan()).states, isEmpty);
      expect(hashes, 1);

      // …and only once: the record now agrees with the new stat.
      expect((await folder.rescan()).states, isEmpty);
      expect(hashes, 1);
    });

    test('one unreadable file costs its own state, not the pass', () async {
      await folder.close();
      folder = buildTuned(hasher: (bytes) {
        if (utf8.decode(bytes, allowMalformed: true).contains('POISON')) {
          throw const FileSystemException('simulated unreadable file');
        }
        return sha256Hex(bytes);
      });

      write('good.md', 'fine');
      write('bad.md', 'POISON');

      final pass = await folder.rescan();
      expect(pass.states.map((s) => s.path), ['good.md']);
      expect(pass.failures.keys, ['bad.md']);

      // The failure left no record behind, so a later pass reports the path
      // as an ordinary change once it can be read.
      write('bad.md', 'healed');
      final next = await folder.rescan();
      expect(next.states.map((s) => s.path), ['bad.md']);
      expect(next.failures, isEmpty);
    });

    test('everything that changed arrives in one batch', () async {
      write('a.md', 'the moved body');
      await folder.rescan();

      File(p.join(root(), 'a.md')).deleteSync();
      write('b.md', 'the moved body');

      final pass = await folder.rescan();
      expect(pass.states.map((s) => s.path).toSet(), {'a.md', 'b.md'});
      expect(pass.states.singleWhere((s) => s.path == 'a.md').isAbsent, isTrue);
      final appeared = pass.states.singleWhere((s) => s.path == 'b.md');
      expect(appeared.isAbsent, isFalse);
      expect(appeared.hash, sha256Hex(utf8.encode('the moved body')),
          reason: 'the pair is recognisable by content, in one pass');
      expect((await folder.rescan()).states, isEmpty,
          reason: 'nothing was withheld for a later pass');
    });
  });

  group('large content stays on disk', () {
    test('a file above the inline limit reports its hash, not its bytes',
        () async {
      var wholeHashes = 0;
      await folder.close();
      folder = buildTuned(
        inlineLimitBytes: 64,
        hasher: (bytes) {
          wholeHashes += 1;
          return sha256Hex(bytes);
        },
      );

      final big = List<int>.generate(3000, (i) => (i * 7) % 251);
      File(p.join(root(), 'big.bin')).writeAsBytesSync(big);

      final state = (await folder.rescan()).states.single;
      expect(state.isAbsent, isFalse, reason: 'present, just not carried');
      expect(state.content, isNull);
      expect(state.hash, sha256Hex(big));
      expect(state.sizeBytes, 3000);
      expect(wholeHashes, 0, reason: 'hashed from a stream, never held whole');
      expect((await folder.read('big.bin')).toList(), big);
    });
  });

  group('the record can be corrected (R6)', () {
    test('a state a consumer could not apply is reported again', () async {
      write('n.md', 'one');
      final first = await folder.rescan();
      expect(first.states, hasLength(1));
      expect((await folder.rescan()).states, isEmpty);

      // The consumer failed on that state: show it again.
      folder.invalidate('n.md');
      final again = await folder.rescan();
      expect(again.states.single.path, 'n.md');

      // The same for a deletion — restoring what preceded it reports the
      // path gone again.
      final settled = again.states.single;
      File(p.join(root(), 'n.md')).deleteSync();
      expect((await folder.rescan()).states.single.isAbsent, isTrue);
      expect((await folder.rescan()).states, isEmpty);
      folder.replay(
        'n.md',
        hash: settled.hash!,
        sizeBytes: settled.sizeBytes,
        mtimeMillis: settled.mtimeMillis,
      );
      expect((await folder.rescan()).states.single.isAbsent, isTrue);
    });

  });

  group('exclusions change while the service runs (R7)', () {
    test('becoming excluded is not a deletion; un-excluding re-admits',
        () async {
      write('logs/x.md', 'v1');
      expect((await folder.rescan()).states, hasLength(1));

      folder.applyExclusions(['logs/']);
      expect((await folder.rescan()).states, isEmpty,
          reason: 'excluded, not deleted — no state ever says otherwise');

      write('logs/x.md', 'v2 while ignored');
      expect((await folder.rescan()).states, isEmpty);

      folder.applyExclusions(const []);
      final readmitted = (await folder.rescan()).states.single;
      expect(readmitted.path, 'logs/x.md');
      expect(String.fromCharCodes(readmitted.content!), 'v2 while ignored',
          reason: 'nothing that happened while it was excluded is missed');
    });

    test('the working-state folder is excluded built-in', () async {
      // No configured exclusions at all.
      write('.hist-state/merge/plan.md.draft', '<<<<<<< live');
      events.add('.hist-state/merge/plan.md.draft');
      await quiet();
      expect(seen, isEmpty);

      expect((await folder.rescan()).states, isEmpty);
      expect((await folder.scan()).keys,
          isNot(contains(startsWith('.hist-state'))));
      await expectLater(
        folder.materialize('.hist-state/x', [1], by: 'sync'),
        throwsA(isA<FolderRefused>()),
        reason: 'nothing under .hist-state/ can be written through the '
            'service, whatever the configured rules say',
      );
      expect(folder.excludes('.hist-state/anything'), isTrue);
    });
  });

  group('ignore files nest', () {
    Set<String> reported(FolderScan scan) =>
        {for (final s in scan.states) s.path};

    test('a nested ignore file anchors to its own directory', () async {
      write('notes/.syncignore', '/drafts/\n*.tmp\n');
      write('notes/drafts/a.md', 'excluded: anchored to notes/');
      write('drafts/b.md', 'kept: the anchor is notes/, not the root');
      write('notes/deep/x.tmp', 'excluded: basename beneath notes/');
      write('x.tmp', 'kept: the basename pattern reaches only beneath');
      write('notes/keep.md', 'kept');

      final paths = reported(await folder.rescan());

      expect(paths, isNot(contains('notes/drafts/a.md')));
      expect(paths, isNot(contains('notes/deep/x.tmp')));
      expect(paths, containsAll(['drafts/b.md', 'x.tmp', 'notes/keep.md']));
      expect(paths, contains('notes/.syncignore'),
          reason: 'the ignore file itself is an ordinary vault file');
    });

    test('nesting is additive, and negation stays inert', () async {
      write('.syncignore', 'secret\n'); // a basename: any depth
      write('sub/.syncignore', '!secret\nlocal.md\n');
      write('sub/secret/x.md', 'excluded by the root file — not re-included');
      write('secret/y.md', 'excluded by the root file');
      write('sub/local.md', 'excluded by the nested file');
      write('other/local.md', 'kept: outside the nested file\'s directory');

      final paths = reported(await folder.rescan());

      expect(paths, isNot(contains('sub/secret/x.md')));
      expect(paths, isNot(contains('secret/y.md')));
      expect(paths, isNot(contains('sub/local.md')));
      expect(paths, contains('other/local.md'));
    });

    test('a nested ignore file that changes applies on the next pass',
        () async {
      write('sub/scratch.md', 'v1');
      expect(reported(await folder.rescan()), contains('sub/scratch.md'));

      write('sub/.syncignore', 'scratch.md\n');
      final excluded = await folder.rescan();
      expect(reported(excluded), isNot(contains('sub/scratch.md')),
          reason: 'excluded, not deleted');
      expect(excluded.states.where((s) => s.isAbsent), isEmpty);

      File(p.join(root(), 'sub/.syncignore')).deleteSync();
      final readmitted = await folder.rescan();
      expect(readmitted.states.map((s) => s.path), contains('sub/scratch.md'));
      expect(
          readmitted.states
              .firstWhere((s) => s.path == 'sub/scratch.md')
              .isAbsent,
          isFalse,
          reason: 'reported as new — the same behaviour the root file has');
    });

    test('a module reads its own rule file through the same engine', () async {
      write('.histignore', 'journal/\n');
      write('notes/.histignore', 'scratch.md\n');
      write('notes/a.md', 'x');
      final before = folder.rulesVersion;
      await folder.rescan();

      expect(folder.rulesVersion, greaterThan(before),
          reason: 'a tracked rule file changed the generation');
      final sources = folder.ignoreSources(VaultFolder.histIgnoreFile);
      expect(sources.map((s) => s.dir), ['', 'notes']);
      expect(sources.map((s) => s.patterns), [
        ['journal/'],
        ['scratch.md'],
      ]);
      // The folder itself does not act on it: nothing is excluded from the
      // folder by a .histignore rule.
      expect(folder.excludes('journal/day.md'), isFalse);
      expect(ExclusionMatcher.fromSources(sources).excludes('notes/scratch.md'),
          isTrue);
      expect(ExclusionMatcher.fromSources(sources).excludes('deep/scratch.md'),
          isFalse);
    });
  });
}

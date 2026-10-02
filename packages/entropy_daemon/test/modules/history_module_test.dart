/// `vault_daemon` test-spec — "Module hosting" (`daemon-modules` R2):
/// the history module alone over the folder service, with no sync module
/// anywhere in the picture — it consumes the attributed stream and needs
/// nothing else.
library;

import 'dart:async';
import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late StreamController<String> events;
  late VaultFolder folder;
  late HistoryModule history;
  late int now;

  String root() => p.join(tmp.path, 'vault');

  void write(String rel, String content) {
    final f = File(p.join(root(), rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    // A same-size rewrite within one mtime tick would look unchanged to the
    // folder's mtime+size fast path; pin the mtime to the test clock instead.
    f.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(now));
  }

  Future<List<HistFileHeader>> headers(String rel) =>
      FsHistStore(root()).listHeaders(rel);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('history-module');
    Directory(root()).createSync(recursive: true);
    events = StreamController<String>.broadcast();
    now = 1700000000000;
    folder = VaultFolder(
      root: root(),
      cursor: FolderCursor.inMemory(),
      events: events.stream,
      clock: () => now,
      trashFallbackDir: p.join(tmp.path, 'trash'),
    );
    final writer = HistWriter(
      store: FsHistStore(root()),
      now: () => now,
      writerName: 'laptop',
    );
    history = HistoryModule(
      folder: folder,
      writer: writer,
      queue: HistCommitQueue(hist: writer, now: () => now, idleMillis: 0),
    );
  });
  tearDown(() async {
    await folder.close();
    await events.close();
    tmp.deleteSync(recursive: true);
  });

  test(
      'commits local states and adopts materialized ones, naming no other '
      'module', () async {
    write('notes/a.md', 'one\n');
    for (final state in (await folder.rescan()).states) {
      await history.onLocalState(state);
    }
    await history.flushIdle();
    expect((await headers('notes/a.md')).map((x) => x.type),
        [HistFileType.snapshot]);

    // An edit: offered, committed once quiet.
    now += 1000;
    write('notes/a.md', 'two\n');
    for (final state in (await folder.rescan()).states) {
      await history.onLocalState(state);
    }
    await history.flushIdle();
    expect((await headers('notes/a.md')).map((x) => x.type),
        [HistFileType.snapshot, HistFileType.patch]);

    // A materialization by some module — history never learns which — is
    // adopted: nothing recorded, but the next edit diffs from it.
    now += 1000;
    final written = await folder.materialize(
        'notes/a.md', 'three (arrived)\n'.codeUnits,
        by: 'whoever');
    await history.onMaterialized(written);
    expect(await headers('notes/a.md'), hasLength(2), reason: 'adopted');
    now += 1000;
    write('notes/a.md', 'four\n');
    for (final state in (await folder.rescan()).states) {
      await history.onLocalState(state);
    }
    await history.flushIdle();
    final all = await headers('notes/a.md');
    final anchor = all.where((x) =>
        x.type == HistFileType.snapshot &&
        x.version == sha256Hex('three (arrived)\n'.codeUnits));
    expect(anchor, hasLength(1),
        reason: 'the arrival was the base: anchored, then patched');
    expect(all.last.type, HistFileType.patch);
    expect(all.last.prev, sha256Hex('three (arrived)\n'.codeUnits));
  });

  test(
      'a baseline is adopted, a deletion is recorded, a rename is a marker '
      'pair', () async {
    write('a.md', 'A\n');
    for (final state in (await folder.rescan()).states) {
      await history.onLocalState(state, adopt: true); // the seeding scan
    }
    await history.flushIdle();
    expect(await headers('a.md'), isEmpty, reason: 'a baseline, no version');

    now += 1000;
    write('a.md', 'B\n');
    for (final state in (await folder.rescan()).states) {
      await history.onLocalState(state);
    }
    await history.flushIdle();
    expect((await headers('a.md')).map((x) => x.type),
        [HistFileType.snapshot, HistFileType.patch],
        reason: 'the first edit anchors the adopted baseline');

    // A rename, as the host detects it from the folder's states.
    now += 1000;
    File(p.join(root(), 'a.md')).renameSync(p.join(root(), 'b.md'));
    final scan = await folder.rescan();
    final appeared = scan.states.singleWhere((s) => s.path == 'b.md');
    await history.onRename('a.md', appeared);
    expect((await headers('a.md')).last.type, HistFileType.deleted);
    expect((await headers('a.md')).last.renamedTo, 'b.md');
    expect((await headers('b.md')).single.renamedFrom, 'a.md');

    // A deletion.
    now += 1000;
    File(p.join(root(), 'b.md')).deleteSync();
    for (final state in (await folder.rescan()).states) {
      await history.onLocalState(state);
    }
    await history.flushIdle();
    expect((await headers('b.md')).last.type, HistFileType.deleted);
  });

  test(
      'a losing binary handed over by the host is rescued, and the '
      'divergence count is derived', () async {
    await history.rescueBinaryLoser('img/x.png', [0, 1, 2, 3]);
    expect((await headers('img/x.png')).single.type, HistFileType.conflict);

    write('plan.md', 'A\n');
    for (final state in (await folder.rescan()).states) {
      await history.onLocalState(state);
    }
    await history.flushIdle();
    // Another device's line arrives: divergent.
    final other = HistWriter(
        store: FsHistStore(root()), now: () => now + 5000, writerName: 'phone');
    await other.commit('plan.md', 'D\n'.codeUnits, previous: 'A\n'.codeUnits);
    expect(history.divergent, 0, reason: 'not yet noticed');
    await history.onHistoryFile('.hist/plan.md/whatever.patch');
    expect(history.divergent, 1);
    expect(history.divergentFiles, ['plan.md']);
    await history.recountAll();
    expect(history.divergent, 1);
  });
}

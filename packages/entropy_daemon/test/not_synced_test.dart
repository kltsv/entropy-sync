/// `vault_daemon` test-spec — "What is not synced (RV8)".
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
      'exclusion defaults are skipped by scan, watch, and history alike '
      '(RV8)', () async {
    final mac = h.handleFor('mac');
    // Every default-excluded shape…
    mac.write('.DS_Store', 'finder litter');
    mac.write('.trash/x.md', 'trashed note');
    mac.write('.git/HEAD', 'ref: refs/heads/main');
    mac.write('_workspace/notes.md', 'scratch');
    mac.write('.obsidian/workspace.json', '{"volatile":true}');
    mac.write('.obsidian/workspace-mobile.json', '{"volatile":true}');
    mac.write('.obsidian/plugins/obsidian-livesync/main.js', 'legacy');
    mac.write('.obsidian/plugins/remotely-save/data.json', '{}');
    // …plus a real note and real Obsidian config.
    mac.write('note.md', 'a real note\n');
    mac.write('.obsidian/app.json', '{"real":true}');

    await h.spawn('mac');
    await mac.shell.reconcile();

    // Only note.md and .obsidian/app.json became synced documents — the
    // default excludes `.obsidian/workspace*.json`, not all of `.obsidian/`.
    final nonMeta =
        h.serverStore().allDocIds.where((id) => id != 'meta').toSet();
    expect(nonMeta, {mac.docId('note.md'), mac.docId('.obsidian/app.json')});
    expect(
      mac.shell.store.allDocIds.where((id) => id != 'meta').toSet(),
      nonMeta,
    );

    // A later modification of excluded files produces no push — neither via
    // the rescan…
    mac.write('.trash/x.md', 'modified trash');
    mac.write('.obsidian/workspace.json', '{"volatile":"changed"}');
    await mac.shell.reconcile();
    // …nor via a watcher flush (excluded paths are not watched; the flush
    // seam refuses them outright).
    await mac.shell.ingestPath('.trash/x.md');
    await mac.shell.ingestPath('.obsidian/workspace.json');

    expect(mac.shell.store.pendingPushCount, 0);
    expect(
      h.serverStore().allDocIds.where((id) => id != 'meta').toSet(),
      nonMeta,
    );

    // No excluded path gained history.
    expect(Directory(p.join(mac.vaultRoot, '.hist')).existsSync(), isFalse);
  });

  test('`.hist/` is synced but never history-tracked (RV8)', () async {
    final mac = h.handleFor('mac');
    // A vault whose `.hist/notes/a.md/` already holds version files.
    const seedBody = 'seed v0\n';
    mac.file('.hist/notes/a.md/0000000000001.snapshot')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(encodeVersionFile(
        version: sha256OfText(seedBody),
        writer: 'elsewhere',
        body: utf8.encode(seedBody),
      ));
    mac.write('notes/a.md', 'v1\n');

    await h.spawn('mac');
    await mac.shell.reconcile();

    // The pre-existing history file replicated to the server as an ordinary
    // encrypted document — it rides the same layer.
    const seedPath = '.hist/notes/a.md/0000000000001.snapshot';
    expect(h.serverStore().get(mac.docId(seedPath)), isNotNull);
    expect(h.serverRawJson(), isNot(contains('seed v0')));

    // The daemon writes a new history version for a real edit…
    final before = mac.histHeaders('notes/a.md').map((e) => e.filename).toSet();
    mac.write('notes/a.md', 'v2\n');
    await mac.shell.reconcile();
    final newFiles = mac
        .histHeaders('notes/a.md')
        .map((e) => e.filename)
        .where((f) => !before.contains(f))
        .toList();
    expect(newFiles, isNotEmpty);

    // …and those new `.hist/` files sync like any other file…
    await mac.shell.reconcile();
    for (final f in newFiles) {
      expect(h.serverStore().get(mac.docId('.hist/notes/a.md/$f')), isNotNull);
    }

    // …but NO history is recorded *about* `.hist/` paths: no
    // `.hist/.hist/…` entries anywhere (no history-of-history).
    expect(
      Directory(p.join(mac.vaultRoot, '.hist', '.hist')).existsSync(),
      isFalse,
    );
    expect(
      mac.vaultPaths().where((rel) => rel.startsWith('.hist/.hist')),
      isEmpty,
    );
  });
}

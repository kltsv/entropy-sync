/// `vault_daemon` test-spec — "Conflicts (R9, RV9)".
library;

import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:entropy_sync/entropy_sync.dart';
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  /// `*.conflict` files never appear in the vault proper (N7, D2).
  void expectNoConflictFilesInVault(VaultHandle handle) {
    expect(
      handle
          .vaultPaths()
          .where((rel) => !rel.startsWith('.hist/'))
          .where((rel) => rel.contains('.conflict')),
      isEmpty,
    );
  }

  test(
      'a text conflict leaves the winner untouched and the daemon records '
      'nothing for the loser (R9, RV9)', () async {
    final a = await h.spawn('mac');
    final b = await h.spawn('desk');
    await h.settle([a, b], rounds: 1);

    a.write('plan.md', 'base\n');
    await h.settle([a, b]); // shared base + its history everywhere
    expect(b.file('plan.md').readAsStringSync(), 'base\n');

    // Both edit from the shared base while "offline"; each author's daemon
    // records its own edit via localState before reconnecting.
    const editA = 'base\nfrom A\n';
    const editB = 'base\nfrom B\n';
    await h.emulator.stop();
    a.write('plan.md', editA);
    b.write('plan.md', editB);
    await a.shell.reconcile();
    await b.shell.reconcile();
    expect(a.recordedVersions('plan.md'), contains(sha256OfText(editA)));
    expect(b.recordedVersions('plan.md'), contains(sha256OfText(editB)));

    // Reconnect and settle both.
    await h.emulator.start();
    await h.settle([a, b], rounds: 4);

    // Both vaults converge on the same deterministic winner, its bytes
    // untouched — no auto-merge.
    final onA = a.file('plan.md').readAsStringSync();
    final onB = b.file('plan.md').readAsStringSync();
    expect(onA, onB);
    expect([editA, editB], contains(onA));

    // Neither daemon wrote a new history entry for the losing text: the
    // loser is present exactly once, recorded by its author.
    final loser = onA == editA ? editB : editA;
    final loserAuthor = loser == editA ? 'mac' : 'desk';
    for (final handle in [a, b]) {
      final headers = handle.histHeaders('plan.md');
      expect(headers.where((e) => e.type == HistFileType.conflict), isEmpty);
      final loserRecords = headers
          .where((e) =>
              (e.type == HistFileType.snapshot ||
                  e.type == HistFileType.patch) &&
              e.version == sha256OfText(loser))
          .toList();
      expect(loserRecords, hasLength(1),
          reason: 'the loser is its author\'s recorded branch, nothing more');
      expect(loserRecords.single.writer, loserAuthor);
      expectNoConflictFilesInVault(handle);
    }
  });

  test('a binary conflict loser is rescued whole into history (RV9)', () async {
    final a = await h.spawn('mac');
    final b = await h.spawn('desk');
    await h.settle([a, b], rounds: 1);

    final base = [0x89, 0x50, 0x4e, 0x47, 0x00, 0x01, 0x02];
    a.writeBytes('img/logo.png', base);
    await h.settle([a, b]);
    expect(b.file('img/logo.png').existsSync(), isTrue);

    // Both sides edit the binary while offline.
    final editA = [0x89, 0x50, 0x4e, 0x47, 0x00, 0xaa, 0xaa, 0xaa, 0xaa];
    final editB = [0x89, 0x50, 0x4e, 0x47, 0x00, 0xbb, 0xbb];
    await h.emulator.stop();
    a.writeBytes('img/logo.png', editA);
    b.writeBytes('img/logo.png', editB);
    await a.shell.reconcile();
    await b.shell.reconcile();

    await h.emulator.start();
    await h.settle([a, b], rounds: 4);

    // The winner's bytes stand, identical in both vaults.
    final onA = a.file('img/logo.png').readAsBytesSync();
    final onB = b.file('img/logo.png').readAsBytesSync();
    expect(onA.toList(), onB.toList());
    expect(onA.toList(), anyOf(equals(editA), equals(editB)));
    final loser = onA.toList().toString() == editA.toString() ? editB : editA;

    // The losing binary's FULL bytes were written into
    // `.hist/img/logo.png/` as a `conflict` rescue file.
    final rescues = [
      for (final handle in [a, b])
        for (final (header, bytes) in handle.histFiles('img/logo.png'))
          if (header.type == HistFileType.conflict) (header, bytes),
    ];
    expect(rescues, isNotEmpty,
        reason: 'otherwise the losing binary would be gone forever');
    for (final (header, bytes) in rescues) {
      expect(bodyOf(bytes).toList(), loser);
      expect(header.version, sha256Of(loser));
    }

    // No `*.conflict` file appears in either vault.
    expectNoConflictFilesInVault(a);
    expectNoConflictFilesInVault(b);
  });

  test('resolution is idempotent and the owner is notified (RV9)', () async {
    final logPath = p.join(h.tmp.path, 'mac-daemon.log');
    final mac =
        await h.spawn('mac', log: DaemonLog(logPath, mirrorToStderr: false));
    await mac.shell.reconcile();

    final base = [0x00, 0x01, 0x02, 0x03];
    mac.writeBytes('img/pic.png', base);
    await mac.shell.reconcile(); // base synced

    // A remote binary edit lands server-side; a different local binary edit
    // is ingested — after one sync pass the store holds a live conflict.
    final remote = [0x00, 0xaa, 0xab, 0xac, 0xad];
    final local = [0x00, 0xba, 0xbb];
    await h.seedServerDoc(mac, 'img/pic.png', remote);
    mac.writeBytes('img/pic.png', local);
    await mac.shell.ingestPath('img/pic.png');
    await mac.shell.engine.syncNow();
    final report = mac.shell.store.conflicts().single;
    final loserBytes = (await mac.shell.crypto.decryptBody(WireDoc(
      id: report.losers.single.id,
      body: report.losers.single.body,
      deleted: false,
    )))
        .inlineContent!;

    // The conflict is handled once…
    await mac.shell.rescueConflict(report);
    List<(HistFileHeader, List<int>)> rescueFiles() => [
          for (final (header, bytes) in mac.histFiles('img/pic.png'))
            if (header.type == HistFileType.conflict)
              (header, bodyOf(bytes).toList()),
        ];
    expect(rescueFiles(), hasLength(1));
    expect(rescueFiles().single.$2, loserBytes.toList());
    expect(mac.notifications, hasLength(1));
    expect(mac.notifications.single, contains('img/pic.png'));
    expect(mac.shell.store.conflicts(), isEmpty, reason: 'resolved');

    // …then the sync module replays the same conflict event: a no-op.
    await mac.shell.rescueConflict(report);
    expect(rescueFiles(), hasLength(1),
        reason: 'no duplicate rescue file on replay');
    expect(mac.notifications, hasLength(1),
        reason: 'notified once per conflict, not per replay');
    expect(mac.shell.store.conflicts(), isEmpty,
        reason: 'resolve tolerates repetition');

    // The daemon log carries a line recording the conflict and its
    // resolution.
    expect(File(logPath).readAsStringSync(),
        contains('conflict resolved on img/pic.png'));
  });
}

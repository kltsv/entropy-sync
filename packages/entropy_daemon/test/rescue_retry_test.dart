/// `vault_daemon` test-spec — "Conflicts (R9, RV9)": a loser is marked
/// rescued only AFTER its rescue actually succeeded. A transient failure
/// (missing blob, IO error) leaves the conflict unresolved and unmarked, so
/// the next pass retries the rescue instead of silently tombstoning a binary
/// loser that was never saved.
library;

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
      'a transient blob failure holds resolution and retries; the binary '
      'loser is never dropped (RV9)', () async {
    // Small inline threshold so binaries ride as attachments (blob store).
    final a = await h.spawn('mac', inlineThresholdBytes: 8);
    final b = await h.spawn('desk', inlineThresholdBytes: 8);
    await h.settle([a, b], rounds: 1);

    final base = [0x89, 0x50, 0x4e, 0x47, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05];
    a.writeBytes('img/logo.png', base);
    await h.settle([a, b]);
    expect(b.file('img/logo.png').existsSync(), isTrue);

    // Concurrent binary edits while offline.
    final editA = List<int>.generate(24, (i) => 0xa0 + (i % 16));
    final editB = List<int>.generate(20, (i) => 0xb0 + (i % 16));
    await h.emulator.stop();
    a.writeBytes('img/logo.png', editA);
    b.writeBytes('img/logo.png', editB);
    await a.shell.reconcile();
    await b.shell.reconcile();
    await h.emulator.start();

    // Bring the conflict into b's store without letting reconcile rescue it.
    await a.shell.engine.syncNow(); // a pushes its edit
    await b.shell.engine.syncNow(); // b pushes + pulls -> live conflict
    final report = b.shell.store.conflicts().single;
    final loserDigest = report.losers.single.attachment!.digest;

    // Sabotage: the loser's blob vanishes (as if the attachment body was
    // never fetched, or the file was pruned).
    final blobFile = File(p.join(b.stateDir, 'blobs', loserDigest));
    expect(blobFile.existsSync(), isTrue);
    final hidden = File('${blobFile.path}.hidden');
    blobFile.renameSync(hidden.path);

    List<List<int>> rescueFiles() => [
          for (final (header, bytes) in b.histFiles('img/logo.png'))
            if (header.type == HistFileType.conflict) bodyOf(bytes).toList(),
        ];

    // First attempt fails transiently: NO resolution, NO rescue file, NO
    // notification — the conflict stays live for a retry.
    await b.shell.rescueConflict(report);
    expect(b.shell.store.conflicts(), hasLength(1),
        reason: 'resolving now would tombstone unrescued bytes');
    expect(rescueFiles(), isEmpty);
    expect(b.notifications, isEmpty);
    expect(b.shell.lastError, contains('conflict rescue failed'));

    // The blob returns (e.g. re-fetched): the retry rescues and resolves.
    hidden.renameSync(blobFile.path);
    await b.shell.rescueConflict(b.shell.store.conflicts().single);
    expect(b.shell.store.conflicts(), isEmpty);
    expect(rescueFiles(), hasLength(1));
    expect(b.notifications, hasLength(1));

    // The rescued bytes are one losing revision, whole and byte-faithful.
    expect(rescueFiles().single, anyOf(equals(editA), equals(editB)));
  });
}

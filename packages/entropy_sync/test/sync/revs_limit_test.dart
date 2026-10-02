/// `vault_sync` test-spec — "Revision limit and stemming" (C7, RV4).
library;

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('revision limit and stemming (C7, RV4)', () {
    test('the replica mirrors the server\'s _revs_limit and never lowers it',
        () async {
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault').revsLimit = 50;
      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      await r.engine.start();

      // Read once at start and adopted as the local cap.
      expect(r.store.revsLimit, 50);
      final reads = emulator.requestLog.where(
          (req) => req.method == 'GET' && req.path.endsWith('_revs_limit'));
      expect(reads, hasLength(1));
      // The client never changes the server's setting.
      final writes = emulator.requestLog.where(
          (req) => req.method == 'PUT' && req.path.endsWith('_revs_limit'));
      expect(writes, isEmpty);
      await r.engine.stop();
    });

    test(
        'stemming caps stored revision paths at the limit and keeps bodies '
        'only for live leaves', () async {
      final store = LocalStore(revsLimit: 50);
      final revs = <String>[];
      for (var i = 0; i < 60; i++) {
        revs.add(await store.put('d', {'edit': i}));
      }

      // The stored path holds the 50 most recent ids; the oldest 10 stemmed.
      final stored = store.revsOf('d').toSet();
      expect(stored, hasLength(50));
      expect(stored.containsAll(revs.sublist(10)), isTrue);
      for (final old in revs.sublist(0, 10)) {
        expect(store.hasRevision('d', old), isFalse);
      }
      final leaf = store.revisionedDoc('d', revs.last)!;
      expect(leaf.revisionIds, hasLength(50));
      expect(leaf.body, {'edit': 59});
      // Bodies exist only for the live leaf — no ancestor bodies retained.
      for (final rev in revs.sublist(10, 59)) {
        expect(store.revisionedDoc('d', rev), isNull);
      }
    });
  });
}

/// `vault_sync` test-spec — push batching (RV4, R8): `_bulk_docs` uploads
/// chunk by document count and byte budget, confirm progress per successful
/// chunk, and split-and-retry on a 413 from a size-capped hub or proxy —
/// the backlog never wedges behind one ever-growing request.
library;

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// A body of roughly [bytes] encoded JSON size.
Map<String, Object?> bodyOfSize(int bytes, int i) => {
      'i': i,
      'pad': 'x' * bytes,
    };

List<int> bulkDocsSizes(CouchEmulator emulator) => [
      for (final req in logFor(emulator, '_bulk_docs'))
        ((req.jsonBody as Map)['docs'] as List).length,
    ];

void main() {
  group('push chunking (RV4, R8)', () {
    test('the backlog splits into _bulk_docs chunks by document count',
        () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });
      final replicator = Replicator(
        store: r.store,
        transport: r.transport,
        replicaId: 'R',
        bulkDocsMaxCount: 10,
      );

      for (var i = 0; i < 25; i++) {
        await r.store.put('doc-$i', {'i': i});
      }
      await replicator.pushOnce();

      expect(bulkDocsSizes(emulator), [10, 10, 5]);
      expect(r.store.pendingPushCount, 0);
      expect(server.store.allDocIds, hasLength(25));
    });

    test('the backlog splits into _bulk_docs chunks by byte budget', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });
      final replicator = Replicator(
        store: r.store,
        transport: r.transport,
        replicaId: 'R',
        bulkDocsMaxBytes: 8 * 1024,
      );

      for (var i = 0; i < 12; i++) {
        await r.store.put('doc-$i', bodyOfSize(2048, i));
      }
      await replicator.pushOnce();

      final sizes = bulkDocsSizes(emulator);
      expect(sizes.length, greaterThan(2),
          reason: '~24 KB of documents must not ship as one 8 KB-budget POST');
      expect(sizes.reduce((a, b) => a + b), 12);
      expect(sizes.every((n) => n <= 4), isTrue,
          reason: 'each chunk stays within the ~8 KB budget');
      expect(r.store.pendingPushCount, 0);
      expect(server.store.allDocIds, hasLength(12));
    });

    test(
        'a 413 from a size-capped hub splits the chunk and retries smaller '
        'until the backlog uploads', () async {
      final emulator = CouchEmulator(maxRequestBodyBytes: 20 * 1024);
      await emulator.start();
      final server = emulator.db('vault');
      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      // ~48 KB combined — over the 20 KB cap; default knobs would ship it
      // as one POST.
      for (var i = 0; i < 12; i++) {
        await r.store.put('doc-$i', bodyOfSize(4096, i));
      }
      await r.replicator.pushOnce();

      expect(server.store.allDocIds, hasLength(12),
          reason: 'the whole backlog must land despite the body cap');
      expect(r.store.pendingPushCount, 0);
      expect(bulkDocsSizes(emulator).length, greaterThan(2),
          reason: 'the oversized POST was split and retried smaller');

      // The wedge is gone: the next push is a no-op, not a 413 retry loop.
      final requestsBefore = logFor(emulator, '_bulk_docs').length;
      await r.replicator.pushOnce();
      expect(logFor(emulator, '_bulk_docs').length, requestsBefore);
    });

    test(
        'a single document that alone exceeds the cap surfaces as a clear '
        'protocol error', () async {
      final emulator = CouchEmulator(maxRequestBodyBytes: 20 * 1024);
      await emulator.start();
      emulator.db('vault');
      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      await r.store.put('huge', bodyOfSize(64 * 1024, 0));
      await expectLater(
        r.replicator.pushOnce(),
        throwsA(isA<SyncException>()
            .having((e) => e.kind, 'kind', SyncErrorKind.protocol)
            .having((e) => e.statusCode, 'statusCode', 413)
            .having((e) => e.message, 'message',
                allOf(contains('huge'), contains('maximum request size')))),
      );
      // Still pending — the document is not lost, only unsendable here.
      expect(r.store.pendingPushCount, 1);
    });

    test(
        'progress is confirmed per successful chunk — a mid-push failure '
        'does not resurrect already-pushed revisions', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      var bulkDocsSends = 0;
      var failing = true;
      late final FlakyExec flaky;
      final r = makeReplica(emulator, replicaId: 'R', wrapExec: (inner) {
        flaky = FlakyExec(inner)
          ..shouldFail = (req) {
            if (!req.uri.path.endsWith('_bulk_docs')) return false;
            bulkDocsSends += 1;
            return failing && bulkDocsSends >= 2;
          };
        return flaky;
      });
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });
      final replicator = Replicator(
        store: r.store,
        transport: r.transport,
        replicaId: 'R',
        bulkDocsMaxCount: 10,
      );

      for (var i = 0; i < 25; i++) {
        await r.store.put('doc-$i', {'i': i});
      }
      await expectLater(replicator.pushOnce(), throwsA(isA<SyncException>()));

      // Chunk 1 (10 documents) was confirmed before the failure.
      expect(r.store.pendingPushCount, 15);
      expect(server.store.allDocIds, hasLength(10));

      // The retry ships only the remainder.
      failing = false;
      await replicator.pushOnce();
      expect(r.store.pendingPushCount, 0);
      expect(server.store.allDocIds, hasLength(25));
      final diffed = (logFor(emulator, '_revs_diff').last.jsonBody as Map);
      expect(diffed.keys, hasLength(15),
          reason: 'confirmed revisions are not re-negotiated');
    });
  });
}

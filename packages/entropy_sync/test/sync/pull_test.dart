/// `vault_sync` test-spec — "Pull" (RV4).
library;

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('pull (RV4)', () {
    test(
        'the changes request is longpoll with style=all_docs, heartbeat, '
        'and the stored checkpoint', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault');
      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      r.store.setCheckpoint('pull:R', '42-xyz');
      // The heartbeat keeps the parked longpoll open indefinitely (real
      // CouchDB behavior) — abort it once the request shape is captured.
      final cancel = HttpCancelToken();
      final parked = r.replicator.pullOnce(
          longpoll: true, heartbeatMs: 1000, timeoutMs: 150, cancelToken: cancel);
      await waitUntil(() => logFor(emulator, '_changes').isNotEmpty,
          reason: 'longpoll request received');

      final request = logFor(emulator, '_changes').single;
      expect(request.query['feed'], 'longpoll');
      expect(request.query['style'], 'all_docs');
      expect(request.query['heartbeat'], isNotNull);
      expect(request.query['since'], '42-xyz'); // exactly as stored

      cancel.cancel();
      await expectLater(parked, throwsA(isA<SyncException>()));
    });

    test(
        'style=all_docs surfaces conflicting leaves — a two-leaf change row '
        'fetches both', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      final leafA = '4-${hx('a')}';
      final leafB = '4-${hx('b')}';
      final shared = ['3-${hx('1')}', '2-${hx('2')}', '1-${hx('3')}'];
      server.store.graft(rdoc('d', [leafA, ...shared], body: {'side': 'a'}));
      server.store.graft(rdoc('d', [leafB, ...shared], body: {'side': 'b'}));

      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });
      await r.replicator.pullOnce();
      await waitUntil(() => r.conflicts.isNotEmpty, reason: 'conflict event');

      // Both leaves fetched and held in the tree.
      expect(r.store.revsOf('d').toSet().containsAll({leafA, leafB}), isTrue);
      // One change event for the winner…
      expect(r.changes, hasLength(1));
      expect(r.changes.single.doc.rev, leafB); // greater hash wins
      // …plus one conflict event naming the loser.
      expect(r.conflicts, hasLength(1));
      expect(r.conflicts.single.winnerRev, leafB);
      expect(r.conflicts.single.losers.single.rev, leafA);
    });

    test('attachment-less documents batch through _bulk_get', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      final revs = <String, List<String>>{};
      for (var i = 0; i < 5; i++) {
        final rev1 = await server.store.put('doc-$i', {'v': 1, 'i': i});
        final rev2 = await server.store.put('doc-$i', {'v': 2, 'i': i});
        revs['doc-$i'] = [rev2, rev1];
      }

      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });
      emulator.clearLog();
      await r.replicator.pullOnce();

      // Batched — one _bulk_get with revs=true, not five individual GETs.
      final bulkGets = logFor(emulator, '_bulk_get');
      expect(bulkGets, hasLength(1));
      expect(bulkGets.single.query['revs'], 'true');
      final docGets = emulator.requestLog.where((req) =>
          req.method == 'GET' && RegExp(r'^/vault/doc-\d$').hasMatch(req.path));
      expect(docGets, isEmpty);
      // Each grafted with its ancestor path.
      for (final e in revs.entries) {
        expect(r.store.get(e.key)!.rev, e.value.first);
        expect(r.store.revisionedDoc(e.key, e.value.first)!.revisionIds,
            [for (final rev in e.value) revHash(rev)]);
      }
    });

    test(
        'an attachment document is pulled as multipart/related and streamed '
        'into the blob store', () async {
      final emulator = CouchEmulator(
        attachmentChunkSize: 4 * 1024,
        attachmentChunkDelay: const Duration(milliseconds: 1),
      );
      await emulator.start();
      final server = emulator.db('vault');
      final bytes = List<int>.generate(256 * 1024, (i) => (i * 7) % 256);
      await server.store
          .put('big', {'kind': 'blob'}, attachment: byteStream(bytes));
      final serverDigest = server.store.get('big')!.attachment!.digest;

      // Instrument the replica's blob store: record, per received chunk,
      // whether the server had finished serving at that moment.
      final serveDoneAtChunk = <bool>[];
      final r = makeReplica(
        emulator,
        replicaId: 'R',
        blobStore: RecordingBlobStore(MemoryBlobStore(), (chunk) {
          serveDoneAtChunk.add(emulator.attachmentServes.isEmpty ||
              emulator.attachmentServes.last.done);
        }),
      );
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });
      await r.replicator.pullOnce();

      // The fetch shape: GET ?rev=…&revs=true&attachments=true with
      // Accept: multipart/related.
      final fetch = emulator.requestLog.singleWhere(
          (req) => req.method == 'GET' && req.path == '/vault/big');
      expect(fetch.query['rev'], isNotNull);
      expect(fetch.query['revs'], 'true');
      expect(fetch.query['attachments'], 'true');
      expect(fetch.accept, contains('multipart/related'));

      // Streamed: multiple chunks, the first written before the server had
      // finished serving the last — no whole-file buffering observable.
      expect(serveDoneAtChunk.length, greaterThan(1));
      expect(serveDoneAtChunk.first, isFalse);

      // The grafted document references the digest; bytes are intact.
      final doc = r.store.get('big')!;
      expect(doc.attachment!.digest, serverDigest);
      expect(
          await collectBytes(r.store.blobStore.openRead(serverDigest)), bytes);
    });

    test('checkpoints are local-only and sequences are opaque strings',
        () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      for (var i = 0; i < 3; i++) {
        await server.store.put('doc-$i', {'i': i});
      }

      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });
      await r.replicator.pullOnce();

      final checkpoint = r.store.getCheckpoint('pull:R')!;
      // Non-numeric opaque string, stored verbatim.
      expect(int.tryParse(checkpoint), isNull);
      expect(checkpoint, server.formatSeq('3'));

      await server.store.put('doc-3', {'i': 3});
      await r.replicator.pullOnce();

      final secondChanges = logFor(emulator, '_changes').last;
      // Replayed opaquely — never parsed or compared as a number.
      expect(secondChanges.query['since'], checkpoint);
      // No request ever touched a `_local/` path — no server-side
      // checkpoint documents exist.
      expect(emulator.requestLog.where((req) => req.path.contains('_local')),
          isEmpty);
    });

    test(
        'an interrupted pull resumes from the locally persisted last_seq '
        '(R8)', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      for (var i = 0; i < 500; i++) {
        await server.store.put('doc-$i', {'i': i});
      }

      var bulkGetCalls = 0;
      var rigged = true;
      late final FlakyExec flaky;
      final r = makeReplica(
        emulator,
        replicaId: 'R',
        wrapExec: (inner) {
          flaky = FlakyExec(inner)
            ..shouldFail = (req) {
              if (!req.uri.path.endsWith('_bulk_get')) return false;
              bulkGetCalls += 1;
              return rigged && bulkGetCalls > 3;
            };
          return flaky;
        },
      );
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      // First pull dies after 300 processed-and-checkpointed changes.
      await expectLater(
          r.replicator.pullOnce(limit: 100), throwsA(isA<SyncException>()));
      expect(r.store.allDocIds, hasLength(300));
      expect(r.store.getCheckpoint('pull:R'), server.formatSeq('300'));

      // Recover; the second pull transfers only the remaining ~200.
      rigged = false;
      emulator.clearLog();
      final result = await r.replicator.pullOnce(limit: 100);

      expect(result.docsTransferred, 200);
      expect(r.store.allDocIds, hasLength(500));
      // Nothing restarted from sequence zero.
      expect(logFor(emulator, '_changes').first.query['since'],
          server.formatSeq('300'));
    });

    test(
        'longpoll delivers a remote change within seconds and re-issues '
        '(R6, N10)', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault');
      final a = makeReplica(emulator, replicaId: 'A');
      final b = makeReplica(emulator,
          replicaId: 'B', longpollTimeoutMs: 5000, heartbeatMs: 100);
      addTearDown(() async {
        await a.dispose();
        await b.dispose();
        await emulator.stop();
      });

      await b.engine.start();
      // B's longpoll is parked on the server (no pending changes).
      await waitUntil(
          () => logFor(emulator, '_changes')
              .any((req) => req.query['feed'] == 'longpoll'),
          reason: 'parked longpoll');

      final stopwatch = Stopwatch()..start();
      await a.store.put('doc-live', {'v': 1});
      await a.engine.syncNow();

      // The server completes B's parked longpoll with the change row —
      // promptly, without any polling interval elapsing.
      await waitUntil(() => b.changes.isNotEmpty, reason: 'remote change');
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(b.changes.single.id, 'doc-live');
      expect(b.changes.single.origin, ChangeOrigin.remote);
      // The new last_seq persisted…
      expect(b.store.getCheckpoint('pull:B'), isNot('0'));
      expect(b.store.getCheckpoint('pull:B'), isNotNull);
      // …and a fresh longpoll immediately issued.
      await waitUntil(
          () =>
              logFor(emulator, '_changes')
                  .where((req) => req.query['feed'] == 'longpoll')
                  .length >=
              2,
          reason: 'longpoll re-issued');
      await b.engine.stop();
    });

    test(
        'a broken connection reconnects with exponential backoff and flips '
        'the online flag', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      await server.store.put('doc-0', {'v': 1});

      var failing = false;
      late final FlakyExec flaky;
      final b = makeReplica(
        emulator,
        replicaId: 'B',
        backoffBase: const Duration(milliseconds: 60),
        backoffCap: const Duration(seconds: 5),
        longpollTimeoutMs: 100,
        wrapExec: (inner) {
          flaky = FlakyExec(inner)
            ..shouldFail =
                (req) => failing && req.uri.path.endsWith('_changes');
          return flaky;
        },
      );
      addTearDown(() async {
        await b.dispose();
        await emulator.stop();
      });

      await b.engine.start();
      await waitUntil(() => b.statuses.any((s) => s.online),
          reason: 'initial online');
      await waitUntil(
          () => logFor(emulator, '_changes')
              .any((req) => req.query['feed'] == 'longpoll'),
          reason: 'longpoll parked before the outage');
      final requestsBeforeOutage = logFor(emulator, '_changes').length;

      failing = true;
      // The parked heartbeat longpoll is already in flight (not gated by the
      // rig) — complete it with a change, as a real outage would kill it; the
      // loop's next issue then fails.
      await server.store.put('doc-wake', {'v': 1});
      server.touch();
      await waitUntil(() => flaky.failureTimes.length >= 4,
          reason: 'four failed attempts');
      // No pull succeeded during the outage — the checkpoint is pinned.
      final checkpointDuringOutage = b.store.getCheckpoint('pull:B');
      failing = false;

      // online flipped false after the first failure.
      expect(b.statuses.any((s) => !s.online && s.error != null), isTrue);
      // Retry gaps increase (exponential backoff): each at least the previous.
      final times = flaky.failureTimes;
      final gaps = [
        for (var i = 1; i < 4; i++)
          times[i].difference(times[i - 1]).inMilliseconds,
      ];
      expect(gaps[1], greaterThanOrEqualTo(gaps[0]));
      expect(gaps[2], greaterThanOrEqualTo(gaps[1]));
      expect(gaps[2], greaterThan(gaps[0])); // strictly growing overall

      // Once the transport recovers, the loop resumes from the same
      // checkpoint and online: true is emitted.
      final statusCount = b.statuses.length;
      await waitUntil(() => b.statuses.skip(statusCount).any((s) => s.online),
          reason: 'recovery');
      // Rigged failures never reached the server — the first request logged
      // after the outage is the recovery pull, resuming from the checkpoint.
      final resumed = logFor(emulator, '_changes')
          .skip(requestsBeforeOutage)
          .where((req) => req.query['since'] != null)
          .toList();
      expect(resumed.first.query['since'], checkpointDuringOutage);
      await b.engine.stop();
    });
  });
}

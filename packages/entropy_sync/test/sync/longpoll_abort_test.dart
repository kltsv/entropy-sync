/// `vault_sync` test-spec — longpoll lifecycle fidelity (RV4): on real
/// CouchDB the heartbeat **overrides** any timeout, so a parked longpoll is
/// held open until a change arrives; `stop()` must therefore abort the
/// in-flight request, and an abandoned pull pass must never graft or write
/// checkpoints through a stale store.
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// An executor that strips the cancel token — models the race where `stop()`
/// cannot abort the parked request (the response is already in flight): the
/// generation check alone must keep the abandoned pass from writing.
class TokenStrippingExec implements HttpExec {
  TokenStrippingExec(this.inner);

  final HttpExec inner;

  @override
  Future<HttpExecResponse> send(HttpExecRequest request) => inner.send(
        HttpExecRequest(
          method: request.method,
          uri: request.uri,
          headers: request.headers,
          body: request.body,
          contentLength: request.contentLength,
          // cancelToken deliberately dropped.
        ),
      );
}

void main() {
  group('emulator longpoll fidelity (heartbeat overrides timeout)', () {
    test(
        'a heartbeat longpoll parks past its timeout and completes only on a '
        'change', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      var completed = false;
      final parked = r.transport
          .changes(since: '0', longpoll: true, heartbeatMs: 50, timeoutMs: 100)
          .then((batch) {
        completed = true;
        return batch;
      });
      // Well past the requested timeout: still parked (real CouchDB ignores
      // the timeout when a heartbeat is requested).
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(completed, isFalse,
          reason: 'heartbeat must override the timeout — the emulator used '
              'to complete parked longpolls on a timeout real CouchDB never '
              'honors');

      await server.store.put('wake', {'v': 1});
      server.touch();
      final batch = await parked;
      expect(completed, isTrue);
      expect(batch.rows.single.id, 'wake');
    });

    test('without a heartbeat the longpoll honors its timeout', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault');
      addTearDown(emulator.stop);

      // The production client always sends a heartbeat; drive the emulator
      // raw to pin the no-heartbeat contract.
      final client = HttpClient();
      addTearDown(client.close);
      final stopwatch = Stopwatch()..start();
      final request = await client.getUrl(emulator.baseUrl.replace(
        path: '/vault/_changes',
        queryParameters: {'feed': 'longpoll', 'since': '0', 'timeout': '150'},
      ));
      final response = await request.close();
      final body = jsonDecode(await utf8.decodeStream(response)) as Map;
      stopwatch.stop();
      expect(body['results'], isEmpty);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('stop() aborts the parked longpoll (RV4)', () {
    test('a cancelled changes request completes promptly with SyncException',
        () async {
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault');
      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      final cancel = HttpCancelToken();
      final parked = r.transport.changes(
          since: '0', longpoll: true, heartbeatMs: 100, cancelToken: cancel);
      await waitUntil(() => logFor(emulator, '_changes').isNotEmpty,
          reason: 'longpoll parked on the server');

      final stopwatch = Stopwatch()..start();
      cancel.cancel();
      await expectLater(
          parked,
          throwsA(isA<SyncException>()
              .having((e) => e.kind, 'kind', SyncErrorKind.unreachable)));
      stopwatch.stop();
      // Prompt — not the heartbeat-forever park, not a server timeout.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test(
        'stop() during a parked longpoll: the loop exits and nothing is '
        'grafted or checkpointed afterwards', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      final r = makeReplica(emulator, replicaId: 'R', heartbeatMs: 60);
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      await r.engine.start();
      await waitUntil(
          () => logFor(emulator, '_changes')
              .any((req) => req.query['feed'] == 'longpoll'),
          reason: 'longpoll parked');
      await r.engine.stop();

      final checkpointAtStop = r.store.getCheckpoint('pull:R');
      final requestsAtStop = emulator.requestLog.length;

      // A change arriving *after* stop completes the abandoned server-side
      // handler — the stopped engine must not react to it.
      await server.store.put('late-arrival', {'v': 1});
      server.touch();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(r.store.get('late-arrival'), isNull,
          reason: 'a stopped engine must never graft');
      expect(r.store.getCheckpoint('pull:R'), checkpointAtStop,
          reason: 'a stopped engine must never write checkpoints');
      expect(emulator.requestLog.length, requestsAtStop,
          reason: 'the pull loop must exit, not re-issue');

      // The engine stays usable: a fresh start() picks the change up.
      await r.engine.start();
      await waitUntil(() => r.store.get('late-arrival') != null,
          reason: 'restarted engine pulls normally');
      await r.engine.stop();
    });

    test(
        'even when the request cannot be aborted, the abandoned pass '
        'discards its results (generation check)', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      final r = makeReplica(emulator,
          replicaId: 'R',
          heartbeatMs: 60,
          wrapExec: (inner) => TokenStrippingExec(inner));
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      await r.engine.start();
      await waitUntil(
          () => logFor(emulator, '_changes')
              .any((req) => req.query['feed'] == 'longpoll'),
          reason: 'longpoll parked');
      await r.engine.stop();
      final checkpointAtStop = r.store.getCheckpoint('pull:R');

      // The parked request survives stop() (token stripped) and now
      // completes with a change row — the stale pass must discard it.
      await server.store.put('late-arrival', {'v': 1});
      server.touch();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(r.store.get('late-arrival'), isNull,
          reason: 'an abandoned pass must never graft over live state');
      expect(r.store.getCheckpoint('pull:R'), checkpointAtStop,
          reason: 'an abandoned pass must never advance checkpoints');
      expect(logFor(emulator, '_bulk_get'), isEmpty,
          reason: 'the abandoned pass must not even fetch the revisions');
    });
  });
}

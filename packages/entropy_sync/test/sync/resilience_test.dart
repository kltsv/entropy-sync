/// `vault_sync` test-spec — error containment (R17, RV4): every failure
/// surfacing from a replication pass stays inside the [SyncException] model,
/// nothing escapes the engine's unawaited loops, transfer-encoded attachments
/// fail loudly, and multipart fetches drain their connections.
library;

import 'dart:async';
import 'dart:io';

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/src/sync/transport/wire_codec.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// An executor that sabotages the *response body* of matching requests: the
/// stream errors (or ends cleanly, when [truncate]) after [cutAfterBytes] —
/// the shape of a connection dying mid-attachment-download, which the
/// between-request outage rigs can never produce.
class BodyCuttingExec implements HttpExec {
  BodyCuttingExec(this.inner);

  final HttpExec inner;
  bool Function(HttpExecRequest request)? shouldCut;
  int cutAfterBytes = 0;
  bool truncate = false;

  @override
  Future<HttpExecResponse> send(HttpExecRequest request) async {
    final response = await inner.send(request);
    if (!(shouldCut?.call(request) ?? false)) return response;
    return HttpExecResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      body: _cut(response.body),
    );
  }

  Stream<List<int>> _cut(Stream<List<int>> source) async* {
    var seen = 0;
    await for (final chunk in source) {
      yield chunk;
      seen += chunk.length;
      if (seen >= cutAfterBytes) {
        if (truncate) return; // clean early end-of-stream
        throw const HttpException('connection closed while receiving data');
      }
    }
  }
}

/// An executor rigged to throw a *non-IO* error — outside every mapping in
/// the transport — to prove the engine loops contain absolutely anything.
class PoisonExec implements HttpExec {
  PoisonExec(this.inner);

  final HttpExec inner;
  bool Function(HttpExecRequest request)? shouldPoison;

  @override
  Future<HttpExecResponse> send(HttpExecRequest request) {
    if (shouldPoison?.call(request) ?? false) {
      throw StateError('rigged non-IO failure');
    }
    return inner.send(request);
  }
}

/// An executor recording, per response, whether its body stream was consumed
/// to end-of-stream — the observable of connection reuse: dart:io returns a
/// connection to the keep-alive pool only once its response is fully drained.
class DrainTrackingExec implements HttpExec {
  DrainTrackingExec(this.inner);

  final HttpExec inner;
  final List<({String path, List<bool> doneBox})> tracks = [];

  @override
  Future<HttpExecResponse> send(HttpExecRequest request) async {
    final response = await inner.send(request);
    final doneBox = [false];
    tracks.add((path: request.uri.path, doneBox: doneBox));
    return HttpExecResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      body: response.body
          .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleDone: (sink) {
          doneBox[0] = true;
          sink.close();
        },
      )),
    );
  }
}

Future<void> seedAttachmentDoc(
  CouchEmulator emulator,
  String id,
  int size, {
  int seed = 0,
}) async {
  final bytes = List<int>.generate(size, (i) => (i * 7 + seed) % 256);
  await emulator
      .db('vault')
      .store
      .put(id, {'kind': 'blob'}, attachment: byteStream(bytes));
}

void main() {
  group('attachment download failures stay inside the SyncException model', () {
    test(
        'a connection dying mid-attachment-stream surfaces as '
        'SyncException(unreachable), not a raw IOException', () async {
      final emulator = CouchEmulator(attachmentChunkSize: 8 * 1024);
      await emulator.start();
      await seedAttachmentDoc(emulator, 'big', 256 * 1024);

      late final BodyCuttingExec cutting;
      final r = makeReplica(emulator, replicaId: 'R', wrapExec: (inner) {
        cutting = BodyCuttingExec(inner)
          ..cutAfterBytes = 32 * 1024
          ..shouldCut = (req) => req.uri.path == '/vault/big';
        return cutting;
      });
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      await expectLater(
        r.replicator.pullOnce(),
        throwsA(isA<SyncException>()
            .having((e) => e.kind, 'kind', SyncErrorKind.unreachable)),
      );
      // Nothing grafted from the broken fetch.
      expect(r.store.get('big'), isNull);
    });

    test(
        'a cleanly truncated multipart body surfaces as '
        'SyncException(protocol), not a raw FormatException', () async {
      final emulator = CouchEmulator(attachmentChunkSize: 8 * 1024);
      await emulator.start();
      await seedAttachmentDoc(emulator, 'big', 256 * 1024);

      final r = makeReplica(emulator, replicaId: 'R', wrapExec: (inner) {
        return BodyCuttingExec(inner)
          ..cutAfterBytes = 32 * 1024
          ..truncate = true
          ..shouldCut = (req) => req.uri.path == '/vault/big';
      });
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      await expectLater(
        r.replicator.pullOnce(),
        throwsA(isA<SyncException>()
            .having((e) => e.kind, 'kind', SyncErrorKind.protocol)),
      );
    });

    test(
        'the continuous engine survives a mid-attachment connection cut: '
        'error status + backoff + recovery, no escaped error', () async {
      final emulator = CouchEmulator(attachmentChunkSize: 8 * 1024);
      await emulator.start();
      await seedAttachmentDoc(emulator, 'big', 256 * 1024);

      var failing = true;
      late final BodyCuttingExec cutting;
      final r = makeReplica(emulator, replicaId: 'R', wrapExec: (inner) {
        cutting = BodyCuttingExec(inner)
          ..cutAfterBytes = 32 * 1024
          ..shouldCut = (req) => failing && req.uri.path == '/vault/big';
        return cutting;
      });
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      final escaped = <Object>[];
      await runZonedGuarded(() async {
        await r.engine.start();
        await waitUntil(
            () => r.statuses.any((s) => !s.online && s.error != null),
            reason: 'error status from the cut download');
        failing = false;
        await waitUntil(() => r.store.get('big') != null,
            reason: 'recovery after backoff');
        await r.engine.stop();
      }, (e, st) => escaped.add(e));

      expect(escaped, isEmpty,
          reason: 'nothing may escape the unawaited pull loop');
      expect(
          await collectBytes(r.store.blobStore
              .openRead(r.store.get('big')!.attachment!.digest)),
          hasLength(256 * 1024));
    });
  });

  group('the engine loops contain any error, not only SyncException', () {
    test('a non-IO error in the pull loop becomes error status + backoff',
        () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      await server.store.put('d', {'v': 1});

      var poisoning = true;
      final r = makeReplica(emulator, replicaId: 'R', wrapExec: (inner) {
        return PoisonExec(inner)
          ..shouldPoison =
              (req) => poisoning && req.uri.path.endsWith('_changes');
      });
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      final escaped = <Object>[];
      await runZonedGuarded(() async {
        await r.engine.start();
        await waitUntil(
            () => r.statuses
                .any((s) => !s.online && (s.error ?? '').contains('Bad state')),
            reason: 'error status carrying the non-IO failure');
        poisoning = false;
        await waitUntil(() => r.store.get('d') != null,
            reason: 'loop kept running and recovered');
        await r.engine.stop();
      }, (e, st) => escaped.add(e));
      expect(escaped, isEmpty);
    });

    test('a non-IO error in the push scheduler becomes error status', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault');

      var poisoning = true;
      final r = makeReplica(emulator, replicaId: 'R', wrapExec: (inner) {
        return PoisonExec(inner)
          ..shouldPoison =
              (req) => poisoning && req.uri.path.endsWith('_revs_diff');
      });
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      final escaped = <Object>[];
      await runZonedGuarded(() async {
        await r.engine.start();
        await r.store.put('p', {'v': 1});
        await waitUntil(
            () => r.statuses
                .any((s) => !s.online && (s.error ?? '').contains('Bad state')),
            reason: 'error status from the poisoned push');
        poisoning = false;
        await r.store.put('p', {'v': 2}); // schedules a fresh push
        await waitUntil(() => r.store.pendingPushCount == 0,
            reason: 'push recovered');
        await r.engine.stop();
      }, (e, st) => escaped.add(e));
      expect(escaped, isEmpty,
          reason: 'nothing may escape the unawaited push future');
    });
  });

  group('transfer-encoded attachments fail loudly (never stored corrupted)',
      () {
    Map<String, Object?> wireDoc(Map<String, Object?> attachmentMeta) => {
          'v': 1,
          '_id': 'doc',
          '_rev': '1-${hx('a')}',
          '_revisions': {
            'start': 1,
            'ids': [hx('a')],
          },
          '_attachments': {'data': attachmentMeta},
        };

    test("an 'encoding' field on the attachment stub is rejected as protocol",
        () {
      expect(
        () => revisionedDocFromWire(wireDoc({
          'stub': true,
          'length': 8,
          'digest': 'md5-x',
          'encoding': 'gzip',
          'encoded_length': 5,
        })),
        throwsA(isA<SyncException>()
            .having((e) => e.kind, 'kind', SyncErrorKind.protocol)
            .having((e) => e.message, 'message', contains('gzip'))),
      );
    });

    test("absent or 'identity' encoding decodes normally", () {
      final plain = revisionedDocFromWire(
          wireDoc({'stub': true, 'length': 8, 'digest': 'md5-x'}));
      expect(plain.attachment!.length, 8);
      final identity = revisionedDocFromWire(wireDoc({
        'follows': true,
        'length': 8,
        'digest': 'md5-x',
        'encoding': 'identity',
      }));
      expect(identity.attachment!.length, 8);
    });
  });

  group('multipart fetches drain their connections (RV4)', () {
    test(
        'repeated attachment pulls consume every response to end-of-stream — '
        'the closing boundary is read, no stranded sockets', () async {
      final emulator = CouchEmulator(attachmentChunkSize: 8 * 1024);
      await emulator.start();
      for (var i = 0; i < 5; i++) {
        await seedAttachmentDoc(emulator, 'att-$i', 64 * 1024, seed: i);
      }

      late final DrainTrackingExec tracking;
      final r = makeReplica(emulator,
          replicaId: 'R',
          wrapExec: (inner) => tracking = DrainTrackingExec(inner));
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      await r.replicator.pullOnce();
      for (var i = 0; i < 5; i++) {
        expect(r.store.get('att-$i')!.attachment, isNotNull);
      }

      final multipartGets =
          tracking.tracks.where((t) => t.path.startsWith('/vault/att-'));
      expect(multipartGets, hasLength(5));
      for (final track in multipartGets) {
        expect(track.doneBox[0], isTrue,
            reason: '${track.path} response was not fully drained — '
                'its connection can never return to the keep-alive pool');
      }
    });
  });
}

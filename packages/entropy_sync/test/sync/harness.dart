/// Shared harness for the `vault_sync` test-spec: replicas wired to the
/// in-memory CouchDB emulator over **real HTTP**, captured engine streams,
/// crafted revision helpers, and a riggable transport.
library;

import 'dart:async';
import 'dart:io';

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

/// One test replica: an offline-first [LocalStore] with the real transport,
/// a [Replicator] for discrete passes, and a [SyncEngine] whose change /
/// conflict / status streams are captured into lists.
class TestReplica {
  TestReplica({
    required this.store,
    required this.transport,
    required this.replicator,
    required this.engine,
    required this.replicaId,
    required IoHttpExec ioExec,
  }) : _ioExec = ioExec {
    _subs.add(engine.changes.listen(changes.add));
    _subs.add(engine.conflicts.listen(conflicts.add));
    _subs.add(engine.status.listen(statuses.add));
  }

  final LocalStore store;
  final CouchTransport transport;
  final Replicator replicator;
  final SyncEngine engine;
  final String replicaId;
  final IoHttpExec _ioExec;

  final List<Change> changes = [];
  final List<ConflictReport> conflicts = [];
  final List<SyncStatus> statuses = [];
  final List<StreamSubscription<Object?>> _subs = [];

  Future<void> dispose() async {
    await engine.stop();
    for (final sub in _subs) {
      await sub.cancel();
    }
    _ioExec.close();
  }
}

/// Build a replica against [emulator] with fast timing knobs (the spec
/// defaults are asserted separately in the defaults test).
TestReplica makeReplica(
  CouchEmulator emulator, {
  required String replicaId,
  String database = 'vault',
  StorageBackend? backend,
  BlobStore? blobStore,
  HttpExec Function(IoHttpExec inner)? wrapExec,
  Duration pushDebounce = const Duration(milliseconds: 120),
  Duration backoffBase = const Duration(milliseconds: 40),
  Duration backoffCap = const Duration(milliseconds: 500),
  int heartbeatMs = 100,
  int longpollTimeoutMs = 250,
  int batchLimit = 200,
}) {
  final ioExec = IoHttpExec();
  final store = LocalStore(backend: backend, blobStore: blobStore);
  final transport = CouchTransport(
    baseUrl: emulator.baseUrl,
    database: database,
    username: emulator.username,
    password: emulator.password,
    exec: wrapExec == null ? ioExec : wrapExec(ioExec),
  );
  final replicator = Replicator(
    store: store,
    transport: transport,
    replicaId: replicaId,
  );
  final engine = SyncEngine(
    store: store,
    transport: transport,
    replicaId: replicaId,
    pushDebounce: pushDebounce,
    backoffBase: backoffBase,
    backoffCap: backoffCap,
    heartbeatMs: heartbeatMs,
    longpollTimeoutMs: longpollTimeoutMs,
    batchLimit: batchLimit,
  );
  return TestReplica(
    store: store,
    transport: transport,
    replicator: replicator,
    engine: engine,
    replicaId: replicaId,
    ioExec: ioExec,
  );
}

/// A transport executor rigged to fail on demand — outages, flaky servers.
class FlakyExec implements HttpExec {
  FlakyExec(this.inner);

  final HttpExec inner;

  /// When set and returning true for a request, the send fails with a
  /// [SocketException] before reaching the server.
  bool Function(HttpExecRequest request)? shouldFail;

  final List<DateTime> failureTimes = [];

  @override
  Future<HttpExecResponse> send(HttpExecRequest request) {
    if (shouldFail?.call(request) ?? false) {
      failureTimes.add(DateTime.now());
      throw const SocketException('rigged transport failure');
    }
    return inner.send(request);
  }
}

/// A [BlobStore] wrapper that reports every chunk streamed into `put` — the
/// instrument of the attachment-streaming case.
class RecordingBlobStore implements BlobStore {
  RecordingBlobStore(this.inner, this.onChunk);

  final BlobStore inner;
  final void Function(List<int> chunk) onChunk;

  @override
  Future<BlobHandle> put(Stream<List<int>> bytes) => inner.put(bytes.map((c) {
        onChunk(c);
        return c;
      }));

  @override
  Stream<List<int>> openRead(String digest) => inner.openRead(digest);

  @override
  Future<bool> contains(String digest) => inner.contains(digest);

  @override
  Future<int> length(String digest) => inner.length(digest);
}

/// A 32-lowercase-hex revision hash built from a repeating seed.
String hx(String seed) {
  final buf = StringBuffer();
  while (buf.length < 32) {
    buf.write(seed);
  }
  return buf.toString().substring(0, 32);
}

/// Craft a [RevisionedDoc] from a full revision path (newest first), for
/// grafting with `new_edits=false` semantics.
RevisionedDoc rdoc(
  String id,
  List<String> path, {
  Map<String, Object?>? body,
  AttachmentRef? attachment,
  bool deleted = false,
}) =>
    RevisionedDoc(
      id: id,
      rev: path.first,
      revisionsStart: revGeneration(path.first),
      revisionIds: [for (final rev in path) revHash(rev)],
      body: deleted ? null : (body ?? {'x': 1}),
      attachment: deleted ? null : attachment,
      deleted: deleted,
    );

/// Stream bytes in fixed-size chunks (attachments are opaque byte streams).
Stream<List<int>> byteStream(List<int> bytes, {int chunkSize = 1024}) async* {
  for (var i = 0; i < bytes.length; i += chunkSize) {
    yield bytes.sublist(
        i, i + chunkSize > bytes.length ? bytes.length : i + chunkSize);
  }
}

Future<List<int>> collectBytes(Stream<List<int>> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
  }
  return out;
}

/// Poll until [condition] holds (event loops and real sockets are involved —
/// timing-based waits are replaced by condition waits).
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for: ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Log entries for a path suffix (e.g. `_bulk_get`).
List<EmulatedRequest> logFor(CouchEmulator emulator, String suffix) => [
      for (final r in emulator.requestLog)
        if (r.path.endsWith(suffix)) r,
    ];

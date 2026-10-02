/// Discrete replication passes (`vault_sync` RV4): pull (changes →
/// tree-diff → bulk_get / multipart fetch → graft → local checkpoint) and
/// push (pending_push → revs_diff → bulk_docs / multipart put → confirm).
/// Checkpoints are **local-only**, keyed per replica id, so two devices
/// syncing one database never share checkpoints or collide.
library;

import 'dart:async';
import 'dart:convert';

import '../model/revisions.dart';
import '../model/sync_doc.dart';
import '../store/local_store.dart';
import '../transport/couch_transport.dart';
import '../transport/http_exec.dart';
import '../transport/sync_exception.dart';
import '../transport/wire_codec.dart';

/// The result of one discrete replication pass: documents transferred and
/// the new checkpoint (`vault_sync` Outputs).
class ReplicationResult {
  const ReplicationResult({
    required this.docsTransferred,
    required this.checkpoint,
  });

  final int docsTransferred;

  /// The checkpoint after the pass — the server's opaque `last_seq` for pull,
  /// the local sequence for push.
  final String checkpoint;

  @override
  String toString() =>
      'ReplicationResult($docsTransferred docs, checkpoint $checkpoint)';
}

/// One direction-pair of the replication protocol over a [LocalStore] and a
/// [CouchTransport]. Owned by the engine; also usable directly for explicit
/// scheduling and tests.
class Replicator {
  Replicator({
    required this.store,
    required this.transport,
    required this.replicaId,
    this.bulkDocsMaxCount = 100,
    this.bulkDocsMaxBytes = 10 * 1024 * 1024,
  });

  final LocalStore store;
  final CouchTransport transport;

  /// Unique per (vault, device) — checkpoints are keyed by it (RV4).
  final String replicaId;

  /// Maximum documents per `_bulk_docs` POST. The whole backlog never ships
  /// as one request — real deployments cap request bodies (CouchDB
  /// `max_http_request_size`, nginx `client_max_body_size`), and a batch that
  /// only ever grows would 413 forever.
  final int bulkDocsMaxCount;

  /// Approximate byte budget per `_bulk_docs` POST (encoded document JSON).
  final int bulkDocsMaxBytes;

  String get _pullKey => 'pull:$replicaId';
  String get _pushKey => 'push:$replicaId';

  // ---------------------------------------------------------------------------
  // Pull (RV4)
  // ---------------------------------------------------------------------------

  /// One pull pass. In normal mode, batches are drained until the feed is
  /// caught up; in [longpoll] mode a single parked request is issued (the
  /// engine's loop re-issues immediately — the cycle is the realtime
  /// subscription, N10). The pull checkpoint advances **per processed row**,
  /// so an interrupted pull resumes rather than restarting (R8).
  ///
  /// [cancelToken] aborts the in-flight `_changes` request (a longpoll with a
  /// heartbeat parks indefinitely on real CouchDB). When [abandoned] returns
  /// true after an await, the pass discards its results **without grafting or
  /// writing checkpoints** — a stopped engine's stale pass must never write
  /// through an abandoned store over live state (RV4).
  Future<ReplicationResult> pullOnce({
    bool longpoll = false,
    int limit = 200,
    int heartbeatMs = 30000,
    int? timeoutMs,
    HttpCancelToken? cancelToken,
    bool Function()? abandoned,
  }) async {
    bool isAbandoned() => abandoned?.call() ?? false;
    var transferred = 0;
    var since = store.getCheckpoint(_pullKey) ?? '0';
    while (true) {
      final batch = await transport.changes(
        since: since,
        limit: limit,
        longpoll: longpoll,
        heartbeatMs: heartbeatMs,
        timeoutMs: timeoutMs,
        cancelToken: cancelToken,
      );
      if (isAbandoned()) break;
      transferred += await _processBatch(batch, isAbandoned);
      if (isAbandoned()) break;
      since = batch.lastSeq;
      store.setCheckpoint(_pullKey, since);
      if (longpoll || batch.rows.length < limit) break;
    }
    return ReplicationResult(docsTransferred: transferred, checkpoint: since);
  }

  Future<int> _processBatch(
    ChangesBatch batch,
    bool Function() abandoned,
  ) async {
    // Compare **all** listed leaf revisions against the local tree — the
    // style=all_docs rows are what make conflicting leaves visible (RV4).
    final missingByRow = <int, List<String>>{};
    final wanted = <(String, String)>[];
    for (var i = 0; i < batch.rows.length; i++) {
      final row = batch.rows[i];
      final missing = [
        for (final rev in row.leafRevs)
          if (!store.hasRevision(row.id, rev)) rev,
      ];
      if (missing.isNotEmpty) {
        missingByRow[i] = missing;
        wanted.addAll([for (final rev in missing) (row.id, rev)]);
      }
    }
    if (wanted.isEmpty) {
      if (batch.rows.isNotEmpty && !abandoned()) {
        store.setCheckpoint(_pullKey, batch.rows.last.seq);
      }
      return 0;
    }

    // Attachment-less documents batch through _bulk_get with revs=true.
    final fetched = <(String, String), RevisionedDoc>{};
    for (final doc in await transport.bulkGet(wanted)) {
      fetched[(doc.id, doc.rev)] = doc;
    }
    if (abandoned()) return 0;

    var transferred = 0;
    for (var i = 0; i < batch.rows.length; i++) {
      final row = batch.rows[i];
      final missing = missingByRow[i];
      if (abandoned()) return transferred;
      if (missing == null) {
        store.setCheckpoint(_pullKey, row.seq);
        continue;
      }
      final docs = <RevisionedDoc>[];
      for (final rev in missing) {
        var doc = fetched[(row.id, rev)];
        if (doc == null) continue; // vanished between changes and fetch
        final stub = doc.attachment;
        if (stub != null && !await store.blobStore.contains(stub.digest)) {
          // Attachment documents re-fetch one at a time as multipart/related,
          // the bytes streamed straight into the blob store (RV4).
          final (full, bytes) =
              await transport.getRevisionWithAttachment(row.id, rev);
          if (bytes != null) {
            final handle = await store.blobStore.put(bytes);
            doc = full.withAttachment(
                AttachmentRef(digest: handle.digest, length: handle.length));
          } else {
            doc = full;
          }
          if (abandoned()) return transferred;
        }
        docs.add(doc);
        transferred += 1;
      }
      if (abandoned()) return transferred;
      // Insert with new_edits=false semantics; one change event per document
      // whose winner moved, conflict events for multi-live-leaf documents.
      store.graftBatch(docs);
      // Persist the row's last_seq locally — opaque, verbatim (RV4).
      store.setCheckpoint(_pullKey, row.seq);
    }
    return transferred;
  }

  // ---------------------------------------------------------------------------
  // Push (RV4)
  // ---------------------------------------------------------------------------

  /// One push pass: the durable `pending_push` set → `_revs_diff` → transfer
  /// only what the server lacks (`_bulk_docs` for attachment-less revisions,
  /// chunked by [bulkDocsMaxCount] and [bulkDocsMaxBytes]; one multipart PUT
  /// per attachment document) → confirm and advance the push checkpoint
  /// **per successful chunk**, so an interrupted push resumes rather than
  /// retrying an ever-growing batch (R8). A 413 (payload too large — a
  /// size-capped hub or proxy) splits the chunk and retries smaller.
  Future<ReplicationResult> pushOnce() async {
    final pending = store.pendingPushEntries;
    if (pending.isEmpty) {
      return ReplicationResult(
        docsTransferred: 0,
        checkpoint: store.getCheckpoint(_pushKey) ?? '0',
      );
    }

    final byId = <String, List<String>>{};
    for (final e in pending) {
      byId.putIfAbsent(e.id, () => []).add(e.rev);
    }
    final missing = await transport.revsDiff(byId);

    final plain = <RevisionedDoc>[];
    final withAttachment = <RevisionedDoc>[];
    final sendable = <(String, String)>{};
    missing.forEach((id, revs) {
      for (final rev in revs) {
        final doc = store.revisionedDoc(id, rev);
        if (doc == null) continue; // superseded locally since queueing
        sendable.add((id, rev));
        (doc.attachment == null ? plain : withAttachment).add(doc);
      }
    });

    // Revisions the diff confirmed (the server already has them) and
    // revisions superseded locally clear immediately — no transfer needed.
    _confirm([
      for (final e in pending)
        if (!sendable.contains((e.id, e.rev))) e,
    ]);

    for (final chunk in _chunked(plain)) {
      await _pushChunk(chunk);
    }
    for (final doc in withAttachment) {
      final att = doc.attachment!;
      try {
        await transport.putMultipart(
          doc,
          store.blobStore.openRead(att.digest),
          att.length,
        );
      } on SyncException catch (e) {
        if (e.statusCode == 413) {
          throw SyncException(
              SyncErrorKind.protocol,
              'document ${doc.id} (rev ${doc.rev}, attachment '
              '${att.length} bytes) exceeds the server\'s maximum request '
              'size (HTTP 413) — raise the server/proxy body-size limit',
              statusCode: 413);
        }
        rethrow;
      }
      _confirm([(id: doc.id, rev: doc.rev)]);
    }

    return ReplicationResult(
      docsTransferred: plain.length + withAttachment.length,
      checkpoint: store.getCheckpoint(_pushKey) ?? store.updateSeq,
    );
  }

  /// Mark [entries] server-confirmed and advance the push checkpoint —
  /// called per successful chunk so progress survives a mid-push failure.
  void _confirm(List<PendingRevision> entries) {
    if (entries.isEmpty) return;
    store.markPushed(entries);
    store.setCheckpoint(_pushKey, store.updateSeq);
  }

  /// Split [docs] into `_bulk_docs` chunks by document count and an
  /// approximate encoded-byte budget.
  List<List<RevisionedDoc>> _chunked(List<RevisionedDoc> docs) {
    final chunks = <List<RevisionedDoc>>[];
    var current = <RevisionedDoc>[];
    var currentBytes = 0;
    for (final doc in docs) {
      final size = _approxWireSize(doc);
      if (current.isNotEmpty &&
          (current.length >= bulkDocsMaxCount ||
              currentBytes + size > bulkDocsMaxBytes)) {
        chunks.add(current);
        current = [];
        currentBytes = 0;
      }
      current.add(doc);
      currentBytes += size;
    }
    if (current.isNotEmpty) chunks.add(current);
    return chunks;
  }

  int _approxWireSize(RevisionedDoc doc) =>
      utf8.encode(jsonEncode(wireDocJson(doc))).length;

  /// POST one `_bulk_docs` chunk and confirm it. On 413 split in half and
  /// retry smaller; a single document that still 413s surfaces as a
  /// [SyncException] with a clear message (the batch can shrink no further).
  Future<void> _pushChunk(List<RevisionedDoc> chunk) async {
    try {
      await transport.bulkDocs(chunk);
    } on SyncException catch (e) {
      if (e.statusCode != 413) rethrow;
      if (chunk.length == 1) {
        final doc = chunk.single;
        throw SyncException(
            SyncErrorKind.protocol,
            'document ${doc.id} (rev ${doc.rev}) alone exceeds the '
            'server\'s maximum request size (HTTP 413) — raise the '
            'server/proxy body-size limit',
            statusCode: 413);
      }
      final mid = chunk.length ~/ 2;
      await _pushChunk(chunk.sublist(0, mid));
      await _pushChunk(chunk.sublist(mid));
      return;
    }
    _confirm([for (final doc in chunk) (id: doc.id, rev: doc.rev)]);
  }
}

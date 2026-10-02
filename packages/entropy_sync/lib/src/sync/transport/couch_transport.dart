/// The CouchDB REST transport of `vault_sync` (RV4): longpoll `_changes` with
/// `style=all_docs`, `_revs_diff`, `_bulk_get` / `_bulk_docs`
/// (`new_edits=false`), and `multipart/related` streamed attachments — over
/// an injected [HttpExec] socket layer with basic auth.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model/events.dart';
import '../model/revisions.dart';
import 'http_exec.dart';
import 'multipart.dart';
import 'sync_exception.dart';
import 'wire_codec.dart';

/// One `_changes` response: the rows and the server's opaque `last_seq`.
class ChangesBatch {
  const ChangesBatch({required this.rows, required this.lastSeq});

  final List<ChangeRow> rows;

  /// Opaque sequence string — persisted verbatim as the pull checkpoint,
  /// never parsed (RV4).
  final String lastSeq;
}

/// The protocol client for one CouchDB database. Speaks exactly the endpoints
/// pull and push replication need (RV4); never writes server-side `_local/`
/// checkpoint documents and never issues a bare `PUT /{db}/{id}/data`.
class CouchTransport {
  CouchTransport({
    required this.baseUrl,
    required this.database,
    this.username,
    this.password,
    HttpExec? exec,
    this.requestDeadline = const Duration(seconds: 60),
  }) : _exec = exec ?? IoHttpExec();

  final Uri baseUrl;
  final String database;
  final String? username;
  final String? password;
  final HttpExec _exec;

  /// How long an ordinary request may take to produce response headers before
  /// it is abandoned as unreachable. A silently severed connection never
  /// fails and never returns on its own, and a parked pass takes every pass
  /// behind it with it (`vault_sync` R4).
  ///
  /// Longpolls are exempt: they are *supposed* to park, and are bounded by
  /// silence between heartbeats instead (see [changes]).
  final Duration requestDeadline;

  // ---------------------------------------------------------------------------
  // Request plumbing
  // ---------------------------------------------------------------------------

  Uri _uri(List<String> pathSegments, [Map<String, String>? query]) =>
      baseUrl.replace(
        pathSegments: [
          ...baseUrl.pathSegments.where((s) => s.isNotEmpty),
          database,
          ...pathSegments,
        ],
        queryParameters: query == null || query.isEmpty ? null : query,
      );

  Map<String, String> _headers({
    String accept = 'application/json',
    String? contentType,
  }) =>
      {
        if (username != null)
          'authorization':
              'Basic ${base64.encode(utf8.encode('$username:$password'))}',
        'accept': accept,
        if (contentType != null) 'content-type': contentType,
      };

  Future<HttpExecResponse> _send(HttpExecRequest request) async {
    try {
      final response = await _exec.send(
        request.deadline == null && request.idleDeadline == null
            ? HttpExecRequest(
                method: request.method,
                uri: request.uri,
                headers: request.headers,
                body: request.body,
                contentLength: request.contentLength,
                deadline: requestDeadline,
                cancelToken: request.cancelToken,
              )
            : request,
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        await _drain(response);
        throw SyncException(SyncErrorKind.auth,
            'HTTP ${response.statusCode} from ${request.uri.path}');
      }
      return response;
    } on IOException catch (e) {
      throw SyncException(SyncErrorKind.unreachable, '$e');
    }
  }

  Future<void> _drain(HttpExecResponse response) async {
    try {
      await response.body.drain<void>();
    } catch (_) {
      // The socket may already be gone; the status code said enough.
    }
  }

  Future<String> _readBody(HttpExecResponse response) async {
    try {
      return await utf8.decodeStream(response.body);
    } on IOException catch (e) {
      throw SyncException(SyncErrorKind.unreachable, '$e');
    }
  }

  Future<String> _expect(
    HttpExecRequest request,
    Set<int> okStatuses,
  ) async {
    final response = await _send(request);
    final body = await _readBody(response);
    if (!okStatuses.contains(response.statusCode)) {
      throw SyncException(SyncErrorKind.protocol,
          'HTTP ${response.statusCode} from ${request.uri.path}: $body',
          statusCode: response.statusCode);
    }
    return body;
  }

  Map<String, Object?> _json(String body) {
    try {
      return (jsonDecode(body) as Map).cast<String, Object?>();
    } on FormatException catch (e) {
      throw SyncException(SyncErrorKind.protocol, 'malformed JSON: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Database-level calls
  // ---------------------------------------------------------------------------

  /// Create the database if it does not exist (idempotent; 412 = exists).
  Future<void> ensureDatabase() async {
    final response = await _send(HttpExecRequest(
      method: 'PUT',
      uri: baseUrl.replace(pathSegments: [
        ...baseUrl.pathSegments.where((s) => s.isNotEmpty),
        database,
      ]),
      headers: _headers(),
    ));
    final body = await _readBody(response);
    if (response.statusCode != 201 &&
        response.statusCode != 202 &&
        response.statusCode != 412) {
      throw SyncException(SyncErrorKind.protocol,
          'HTTP ${response.statusCode} creating $database: $body');
    }
  }

  /// The server's `_revs_limit`, mirrored by the replica at engine start; the
  /// client never writes this setting (C7, RV4). Falls back to 1000 when the
  /// endpoint is missing or malformed.
  Future<int> getRevsLimit() async {
    final response = await _send(HttpExecRequest(
      method: 'GET',
      uri: _uri(['_revs_limit']),
      headers: _headers(),
    ));
    final body = await _readBody(response);
    if (response.statusCode < 200 || response.statusCode >= 300) return 1000;
    return int.tryParse(body.trim()) ?? 1000;
  }

  /// Plain document GET — `null` on 404. Used by the shells for the plaintext
  /// `meta` document; replication itself never fetches winners this way.
  Future<Map<String, Object?>?> getDoc(String id) async {
    final response = await _send(HttpExecRequest(
      method: 'GET',
      uri: _uri([id]),
      headers: _headers(),
    ));
    final body = await _readBody(response);
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SyncException(
          SyncErrorKind.protocol, 'HTTP ${response.statusCode} getting $id');
    }
    return _json(body);
  }

  /// Plain MVCC PUT — used for the `meta` document only. A 409 surfaces as
  /// `SyncException(protocol)` so the caller can re-read and reconcile.
  Future<void> putDoc(String id, Map<String, Object?> json) async {
    final payload = utf8.encode(jsonEncode(json));
    final response = await _send(HttpExecRequest(
      method: 'PUT',
      uri: _uri([id]),
      headers: _headers(contentType: 'application/json'),
      body: Stream.value(payload),
      contentLength: payload.length,
    ));
    final body = await _readBody(response);
    if (response.statusCode == 409) {
      throw SyncException(SyncErrorKind.protocol, 'conflict putting $id');
    }
    if (response.statusCode != 201 && response.statusCode != 202) {
      throw SyncException(SyncErrorKind.protocol,
          'HTTP ${response.statusCode} putting $id: $body');
    }
  }

  // ---------------------------------------------------------------------------
  // Pull protocol (RV4)
  // ---------------------------------------------------------------------------

  /// `GET /{db}/_changes` — **always** `style=all_docs` (mandatory: without
  /// it conflicting leaves are invisible and conflicts silently never
  /// surface). Longpoll mode parks on the server with a heartbeat; the cycle
  /// *is* the realtime subscription (N10).
  Future<ChangesBatch> changes({
    required String since,
    int limit = 200,
    bool longpoll = false,
    int heartbeatMs = 30000,
    int? timeoutMs,
    HttpCancelToken? cancelToken,
  }) async {
    final body = await _expect(
      HttpExecRequest(
        method: 'GET',
        uri: _uri([
          '_changes'
        ], {
          'feed': longpoll ? 'longpoll' : 'normal',
          'since': since,
          'style': 'all_docs',
          'limit': '$limit',
          if (longpoll) 'heartbeat': '$heartbeatMs',
          if (longpoll && timeoutMs != null) 'timeout': '$timeoutMs',
        }),
        headers: _headers(),
        // On real CouchDB the heartbeat overrides any timeout — a parked
        // longpoll is held open until a change arrives, so `stop()` must be
        // able to abort it (RV4).
        cancelToken: cancelToken,
        // …and for the same reason elapsed time says nothing about its
        // health, so it is bounded by **silence** instead: a quiet vault
        // still heartbeats, a severed connection does not. Generous multiple
        // so a late heartbeat never looks like a dead socket (R4).
        idleDeadline: longpoll
            ? Duration(milliseconds: heartbeatMs * 3)
            : requestDeadline,
        // Headers still arrive immediately even on a parked longpoll — the
        // heartbeat is what keeps the body open, and it cannot tick before
        // the response has started. So this bound is generous but real: with
        // no headers at all, silence on the body would never be measured.
        deadline: longpoll
            ? Duration(milliseconds: heartbeatMs * 3)
            : requestDeadline,
      ),
      const {200},
    );
    // Longpoll heartbeats prefix the JSON with newlines; the decoder skips
    // leading whitespace.
    final json = _json(body);
    final results =
        (json['results'] as List? ?? const []).cast<Map<dynamic, dynamic>>();
    return ChangesBatch(
      rows: [
        for (final raw in results) _rowFromJson(raw.cast<String, Object?>()),
      ],
      lastSeq: (json['last_seq'] ?? since).toString(),
    );
  }

  ChangeRow _rowFromJson(Map<String, Object?> raw) {
    final revs = [
      for (final c in (raw['changes'] as List)) ((c as Map)['rev'] as String),
    ];
    return ChangeRow(
      seq: raw['seq'].toString(),
      id: raw['id'] as String,
      leafRevs: revs,
      winnerRev: revs.first,
      deleted: raw['deleted'] == true,
    );
  }

  /// `POST /{db}/_revs_diff` — which of these revisions the server lacks.
  Future<Map<String, List<String>>> revsDiff(
    Map<String, List<String>> revs,
  ) async {
    final payload = utf8.encode(jsonEncode(revs));
    final body = await _expect(
      HttpExecRequest(
        method: 'POST',
        uri: _uri(['_revs_diff']),
        headers: _headers(contentType: 'application/json'),
        body: Stream.value(payload),
        contentLength: payload.length,
      ),
      const {200},
    );
    final json = _json(body);
    final out = <String, List<String>>{};
    json.forEach((id, value) {
      final missing =
          ((value as Map)['missing'] as List?)?.cast<String>() ?? const [];
      if (missing.isNotEmpty) out[id] = missing;
    });
    return out;
  }

  /// `POST /{db}/_bulk_get?revs=true` — fetch missing revisions in one batch,
  /// each with its ancestor path so it grafts rather than appearing
  /// unrelated. Attachment-bearing documents come back with stubs and are
  /// re-fetched via [getRevisionWithAttachment] (RV4).
  Future<List<RevisionedDoc>> bulkGet(List<(String, String)> wanted) async {
    final payload = utf8.encode(jsonEncode({
      'docs': [
        for (final (id, rev) in wanted) {'id': id, 'rev': rev},
      ],
    }));
    final body = await _expect(
      HttpExecRequest(
        method: 'POST',
        uri: _uri(['_bulk_get'], {'revs': 'true'}),
        headers: _headers(contentType: 'application/json'),
        body: Stream.value(payload),
        contentLength: payload.length,
      ),
      const {200},
    );
    final json = _json(body);
    final out = <RevisionedDoc>[];
    for (final result in (json['results'] as List? ?? const [])) {
      for (final doc in ((result as Map)['docs'] as List? ?? const [])) {
        final ok = (doc as Map)['ok'];
        if (ok is Map) {
          out.add(revisionedDocFromWire(ok.cast<String, Object?>()));
        }
      }
    }
    return out;
  }

  /// `GET /{db}/{id}?rev=…&revs=true&attachments=true` with
  /// `Accept: multipart/related` — one attachment-bearing revision, the
  /// attachment part **streamed** (never buffered whole, RV4). The returned
  /// stream must be fully drained by the caller (into the blob store).
  Future<(RevisionedDoc, Stream<List<int>>?)> getRevisionWithAttachment(
    String id,
    String rev,
  ) async {
    final response = await _send(HttpExecRequest(
      method: 'GET',
      uri: _uri([id], {'rev': rev, 'revs': 'true', 'attachments': 'true'}),
      headers: _headers(accept: 'multipart/related, application/json'),
    ));
    if (response.statusCode != 200) {
      final body = await _readBody(response);
      throw SyncException(SyncErrorKind.protocol,
          'HTTP ${response.statusCode} getting $id?rev=$rev: $body',
          statusCode: response.statusCode);
    }
    final contentType = response.headers['content-type'];
    final boundary = boundaryOf(contentType);
    if (boundary == null) {
      // No attachment part — plain JSON document.
      return (revisionedDocFromWire(_json(await _readBody(response))), null);
    }
    final reader = MultipartReader(response.body, boundary);
    try {
      final docPart = await reader.nextPart();
      if (docPart == null) {
        throw SyncException(
            SyncErrorKind.protocol, 'empty multipart response for $id');
      }
      final docJson = _json(await utf8.decodeStream(docPart.body));
      final doc = revisionedDocFromWire(docJson);
      final attachmentPart = await reader.nextPart();
      if (attachmentPart == null) {
        // No attachment part after all — release the connection.
        await reader.drainEpilogue();
        return (doc, null);
      }
      return (doc, _attachmentBody(reader, attachmentPart.body, id));
    } on SyncException {
      await reader.cancel();
      rethrow;
    } on FormatException catch (e) {
      await reader.cancel();
      throw SyncException(SyncErrorKind.protocol, 'malformed multipart: $e');
    } on IOException catch (e) {
      await reader.cancel();
      throw SyncException(SyncErrorKind.unreachable, '$e');
    }
  }

  /// The attachment part's body, hardened for lazy consumption: the stream is
  /// drained later (into the blob store), so network/framing failures surface
  /// **there** — map them into the [SyncException] model instead of letting a
  /// raw [IOException]/[FormatException] escape the pull pass, and read the
  /// closing boundary to end-of-stream on completion so the connection
  /// returns to the keep-alive pool (RV4).
  Stream<List<int>> _attachmentBody(
    MultipartReader reader,
    Stream<List<int>> body,
    String id,
  ) async* {
    try {
      // `await for` (not `yield*`): a `yield*` forwards the inner stream's
      // error events straight to the consumer, bypassing this try/catch.
      await for (final chunk in body) {
        yield chunk;
      }
    } on SyncException {
      await reader.cancel();
      rethrow;
    } on FormatException catch (e) {
      await reader.cancel();
      throw SyncException(SyncErrorKind.protocol,
          'malformed multipart while streaming attachment of $id: $e');
    } on IOException catch (e) {
      await reader.cancel();
      throw SyncException(SyncErrorKind.unreachable,
          'connection failed while streaming attachment of $id: $e');
    } catch (e) {
      await reader.cancel();
      throw SyncException(SyncErrorKind.protocol,
          'failed while streaming attachment of $id: $e');
    }
    await reader.drainEpilogue();
  }

  // ---------------------------------------------------------------------------
  // Push protocol (RV4)
  // ---------------------------------------------------------------------------

  /// `POST /{db}/_bulk_docs` with `new_edits: false` — attachment-less
  /// revisions transfer in one batch, each carrying `_revisions` (the full
  /// known ancestor path) so the server grafts the exact local revision ids.
  Future<void> bulkDocs(List<RevisionedDoc> docs) async {
    final payload = utf8.encode(jsonEncode({
      'new_edits': false,
      'docs': [for (final d in docs) wireDocJson(d)],
    }));
    await _expect(
      HttpExecRequest(
        method: 'POST',
        uri: _uri(['_bulk_docs']),
        headers: _headers(contentType: 'application/json'),
        body: Stream.value(payload),
        contentLength: payload.length,
      ),
      const {201, 202},
    );
  }

  /// `PUT /{db}/{id}?new_edits=false` with a `multipart/related` body — the
  /// document JSON (`_attachments: {data: {follows: true, …}}`) plus the
  /// attachment bytes streamed from the blob store, exactly as CouchDB's own
  /// replicator does. **A separate `PUT /{db}/{id}/data` is never used** — it
  /// would mint a server-side revision absent from the local tree (RV4).
  Future<void> putMultipart(
    RevisionedDoc doc,
    Stream<List<int>> attachment,
    int attachmentLength,
  ) async {
    final boundary = mintBoundary();
    final docJson = utf8.encode(jsonEncode(
        wireDocJson(doc, attachmentEncoding: AttachmentEncoding.follows)));
    await _expect(
      HttpExecRequest(
        method: 'PUT',
        uri: _uri([doc.id], {'new_edits': 'false'}),
        headers:
            _headers(contentType: 'multipart/related; boundary="$boundary"'),
        body: multipartRelatedBody(
          docJson: docJson,
          attachment: attachment,
          boundary: boundary,
        ),
        contentLength: multipartRelatedLength(
          docJsonLength: docJson.length,
          attachmentLength: attachmentLength,
          boundary: boundary,
        ),
      ),
      const {201, 202},
    );
  }
}

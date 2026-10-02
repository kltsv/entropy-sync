/// An in-memory multi-database CouchDB emulator serving **real HTTP** on a
/// loopback ephemeral port — the server double of the `vault_sync` test-spec.
/// It implements exactly the endpoints the replication client speaks
/// (`_changes` longpoll with `style=all_docs` and heartbeat, `_revs_diff`,
/// `_bulk_get`, `_bulk_docs` `new_edits:false`, `multipart/related` GET and
/// PUT, `_revs_limit`, plain MVCC document PUT/GET), enforces basic auth, and
/// records every request it receives so tests can assert protocol shape
/// (zero `_local` traffic, no `PUT /{db}/{id}/data`, `style=all_docs`
/// present — RV4).
///
/// Each database is internally an ordinary [LocalStore] + [MemoryBlobStore]
/// pair — the same tree and winner algorithm as the client, which is exactly
/// the spec's point: the winner is a pure function of the tree, identical on
/// every replica and on the server (R9).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../sync/sync.dart';
import '../sync/transport/multipart.dart';
import '../sync/transport/wire_codec.dart';

/// One logged request: method, path, query, and (for JSON bodies) the parsed
/// payload — the raw material of protocol-shape assertions.
class EmulatedRequest {
  EmulatedRequest({
    required this.method,
    required this.path,
    required this.query,
    this.accept,
    this.contentType,
    this.jsonBody,
  });

  final String method;
  final String path;
  final Map<String, String> query;
  final String? accept;
  final String? contentType;
  final Object? jsonBody;

  @override
  String toString() => '$method $path'
      '${query.isEmpty ? '' : '?${Uri(queryParameters: query).query}'}';
}

/// Progress of one multipart attachment download being served — lets the
/// streaming test observe that the client wrote its first chunks into the
/// blob store **before** the server finished serving the last (RV4).
class AttachmentServe {
  int bytesServed = 0;
  bool done = false;
}

/// One emulated database: a [LocalStore] server double plus the emulator's
/// per-db knobs (revs limit, longpoll waiters, opaque sequence tag).
class EmulatedDb {
  EmulatedDb(this.name) : _seqTag = name.hashCode.toRadixString(16);

  final String name;
  final LocalStore store = LocalStore();

  /// The server's `_revs_limit` — mirrored (never written) by clients (C7).
  int revsLimit = 1000;

  final String _seqTag;
  final List<Completer<void>> _waiters = [];

  /// Server sequences are opaque strings (CouchDB 3 style) — clients must
  /// store and replay them verbatim, never parse them (RV4).
  String formatSeq(String localSeq) =>
      localSeq == '0' ? '0' : '$localSeq-emu$_seqTag';

  String parseSeq(String opaque) {
    final dash = opaque.indexOf('-');
    final head = dash < 0 ? opaque : opaque.substring(0, dash);
    return '${int.tryParse(head) ?? 0}';
  }

  /// Wake parked longpoll requests (call after mutating [store] directly).
  void touch() {
    for (final waiter in _waiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
  }
}

/// The emulator server. `start()` binds a loopback ephemeral port (or the
/// previous port again after a `stop()` — databases survive restarts, so
/// outage tests can cut and restore connectivity).
class CouchEmulator {
  CouchEmulator({
    this.username,
    this.password,
    this.attachmentChunkSize = 16 * 1024,
    this.attachmentChunkDelay,
    this.maxRequestBodyBytes,
  });

  /// Basic-auth credentials; `null` disables the auth check.
  final String? username;
  final String? password;

  /// Attachment downloads are served in chunks of this size, flushed
  /// individually, so client-side streaming is observable.
  final int attachmentChunkSize;

  /// Optional pause between served attachment chunks.
  final Duration? attachmentChunkDelay;

  /// When set, any request whose body exceeds this many bytes is answered
  /// `413 Payload Too Large` — the behavior of a size-capped CouchDB
  /// (`max_http_request_size`) or reverse proxy (nginx defaults to a 1 MB
  /// `client_max_body_size`). Push replication must chunk and split around
  /// this, never retry an oversized batch forever.
  final int? maxRequestBodyBytes;

  /// When set, every request is answered `401 Unauthorized` — rigs auth
  /// failures without touching credentials.
  bool forceUnauthorized = false;

  /// Every request received, in order.
  final List<EmulatedRequest> requestLog = [];

  /// One entry per multipart attachment download served.
  final List<AttachmentServe> attachmentServes = [];

  final Map<String, EmulatedDb> _dbs = {};
  HttpServer? _server;
  int? _port;

  int get port => _port!;
  Uri get baseUrl => Uri.parse('http://127.0.0.1:$port');

  /// The named database, created on first access (tests seed through this;
  /// clients create through `PUT /{db}`).
  EmulatedDb db(String name) => _dbs.putIfAbsent(name, () => EmulatedDb(name));

  Future<void> start({int? port}) async {
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, port ?? _port ?? 0);
    _server = server;
    _port = server.port;
    server.listen(_dispatch);
  }

  /// Stop serving (open sockets are torn down); database state survives, so
  /// `start()` again on the same port restores connectivity.
  Future<void> stop() async {
    // Wake parked longpolls so their handlers finish promptly.
    for (final database in _dbs.values) {
      database.touch();
    }
    await _server?.close(force: true);
    _server = null;
  }

  void clearLog() => requestLog.clear();

  // ---------------------------------------------------------------------------
  // Dispatch
  // ---------------------------------------------------------------------------

  Future<void> _dispatch(HttpRequest request) async {
    try {
      await _handle(request);
    } catch (e) {
      try {
        request.response.statusCode = 500;
        request.response.write(jsonEncode({'error': '$e'}));
      } catch (_) {
        // Socket already gone.
      }
    }
    try {
      await request.response.close();
    } catch (_) {
      // Client hung up (engine stopped mid-longpoll) — fine.
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final method = request.method;
    final path = request.uri.path;
    final query = request.uri.queryParameters;
    final contentType = request.headers.contentType?.toString();
    final accept = request.headers.value(HttpHeaders.acceptHeader);

    // Multipart bodies stream through untouched; JSON bodies are collected
    // (and logged) here.
    Object? jsonBody;
    var bodyBytes = 0;
    final isMultipart =
        contentType != null && contentType.contains('multipart/related');
    if (!isMultipart && (method == 'POST' || method == 'PUT')) {
      final bytes = await _collect(request);
      bodyBytes = bytes.length;
      if (bytes.isNotEmpty) {
        try {
          jsonBody = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          jsonBody = null;
        }
      }
    }
    requestLog.add(EmulatedRequest(
      method: method,
      path: path,
      query: query,
      accept: accept,
      contentType: contentType,
      jsonBody: jsonBody,
    ));

    final response = request.response;
    // A size-capped hub/proxy rejects oversized bodies wholesale — before
    // any protocol handling (nginx answers 413 without consulting CouchDB).
    final cap = maxRequestBodyBytes;
    if (cap != null &&
        (bodyBytes > cap || (isMultipart && request.contentLength > cap))) {
      if (isMultipart) await _collect(request); // drain the streamed body
      _json(response, 413, {'error': 'too_large'});
      return;
    }
    if (!_authorized(request)) {
      _json(response, 401, {'error': 'unauthorized'});
      return;
    }

    final segments =
        request.uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      _json(response, 200, {'couchdb': 'emulated'});
      return;
    }

    final dbName = segments.first;
    final tail = segments.sublist(1);

    // PUT /{db} — create (201) or already-exists (412).
    if (tail.isEmpty && method == 'PUT') {
      if (_dbs.containsKey(dbName)) {
        _json(response, 412, {'error': 'file_exists'});
      } else {
        db(dbName);
        _json(response, 201, {'ok': true});
      }
      return;
    }
    final database = _dbs[dbName];
    if (database == null) {
      _json(response, 404, {'error': 'not_found', 'reason': 'no_db_file'});
      return;
    }

    if (tail.isEmpty && method == 'GET') {
      _json(response, 200, {
        'db_name': dbName,
        'update_seq': database.formatSeq(database.store.updateSeq),
      });
      return;
    }

    switch (tail.first) {
      case '_revs_limit':
        if (method == 'GET') {
          response.statusCode = 200;
          response.write('${database.revsLimit}');
        } else if (method == 'PUT') {
          database.revsLimit = int.parse('$jsonBody');
          _json(response, 200, {'ok': true});
        }
        return;
      case '_changes':
        await _changes(database, query, response);
        return;
      case '_revs_diff':
        final input = (jsonBody as Map)
            .map((k, v) => MapEntry(k as String, (v as List).cast<String>()));
        _json(response, 200, {
          for (final e in database.store.missingRevs(input).entries)
            e.key: {'missing': e.value},
        });
        return;
      case '_bulk_get':
        _bulkGet(database, jsonBody as Map, response);
        return;
      case '_bulk_docs':
        final body = (jsonBody as Map).cast<String, Object?>();
        if (body['new_edits'] != false) {
          _json(response, 400, {'error': 'new_edits must be false'});
          return;
        }
        for (final doc in (body['docs'] as List)) {
          database.store.graft(
              revisionedDocFromWire((doc as Map).cast<String, Object?>()));
        }
        database.touch();
        _json(response, 201, const <Object?>[]);
        return;
    }

    // Document-level routes. Anything deeper than /{db}/{id} (for example a
    // bare attachment PUT /{db}/{id}/data) is outside the protocol (RV4).
    if (tail.length != 1) {
      _json(response, 404, {'error': 'not_found', 'reason': 'missing'});
      return;
    }
    final docId = tail.first;

    if (method == 'GET') {
      await _getDoc(database, docId, query, accept, response);
      return;
    }
    if (method == 'PUT' && query['new_edits'] == 'false' && isMultipart) {
      await _putMultipart(database, docId, request, contentType, response);
      return;
    }
    if (method == 'PUT') {
      await _putPlain(database, docId, jsonBody, response);
      return;
    }
    _json(response, 405, {'error': 'method_not_allowed'});
  }

  // ---------------------------------------------------------------------------
  // Endpoints
  // ---------------------------------------------------------------------------

  Future<void> _changes(
    EmulatedDb database,
    Map<String, String> query,
    HttpResponse response,
  ) async {
    final since = database.parseSeq(query['since'] ?? '0');
    final style = query['style'];
    final limit = query['limit'] == null ? null : int.tryParse(query['limit']!);
    final longpoll = query['feed'] == 'longpoll';

    List<ChangeRow> rows() =>
        database.store.changes(since: since, limit: limit);

    var result = rows();
    var parked = false;
    if (longpoll && result.isEmpty) {
      // Park until a change after `since` arrives — or, only when no
      // heartbeat was requested, until the timeout elapses. Real CouchDB's
      // documented behavior: the heartbeat *overrides* any timeout and keeps
      // the feed alive indefinitely, emitting newline keep-alives (RV4) —
      // a parked heartbeat longpoll completes only on a change (or when the
      // client aborts it).
      parked = true;
      response.statusCode = 200;
      response.headers.contentType = ContentType.json;
      response.bufferOutput = false;
      final heartbeatRaw = query['heartbeat'];
      final heartbeatMs = int.tryParse(heartbeatRaw ?? '') ?? 60000;
      final timeoutMs = int.tryParse(query['timeout'] ?? '') ?? 60000;
      final waiter = Completer<void>();
      database._waiters.add(waiter);
      Timer? heartbeat;
      Timer? timeout;
      if (heartbeatRaw != null) {
        heartbeat = Timer.periodic(Duration(milliseconds: heartbeatMs), (_) {
          try {
            response.write('\n');
          } catch (_) {}
        });
      } else {
        timeout = Timer(Duration(milliseconds: timeoutMs), () {
          if (!waiter.isCompleted) waiter.complete();
        });
      }
      await waiter.future;
      heartbeat?.cancel();
      timeout?.cancel();
      database._waiters.remove(waiter);
      result = rows();
    }

    final lastSeq = result.isEmpty
        ? database.formatSeq(database.store.updateSeq)
        : database.formatSeq(result.last.seq);
    final payload = {
      'results': [
        for (final row in result)
          {
            'seq': database.formatSeq(row.seq),
            'id': row.id,
            // style=all_docs lists every leaf (winner first); without it
            // only the winner — which is exactly why the client must always
            // ask for all_docs (RV4).
            'changes': [
              for (final rev
                  in style == 'all_docs' ? row.leafRevs : [row.winnerRev])
                {'rev': rev},
            ],
            if (row.deleted) 'deleted': true,
          },
      ],
      'last_seq': lastSeq,
    };
    if (parked) {
      // Headers may already be on the wire (heartbeats) — write directly.
      response.write(jsonEncode(payload));
    } else {
      _json(response, 200, payload);
    }
  }

  void _bulkGet(
      EmulatedDb database, Map<dynamic, dynamic> body, HttpResponse response) {
    final results = <Map<String, Object?>>[];
    for (final wanted in (body['docs'] as List)) {
      final id = (wanted as Map)['id'] as String;
      final rev = wanted['rev'] as String?;
      final doc = rev == null ? null : database.store.revisionedDoc(id, rev);
      results.add({
        'id': id,
        'docs': [
          if (doc == null)
            {
              'error': {'id': id, 'rev': rev, 'error': 'not_found'},
            }
          else
            {'ok': wireDocJson(doc)},
        ],
      });
    }
    _json(response, 200, {'results': results});
  }

  Future<void> _getDoc(
    EmulatedDb database,
    String docId,
    Map<String, String> query,
    String? accept,
    HttpResponse response,
  ) async {
    final rev = query['rev'];
    if (rev != null) {
      final doc = database.store.revisionedDoc(docId, rev);
      if (doc == null) {
        _json(response, 404, {'error': 'not_found', 'reason': 'missing'});
        return;
      }
      final wantsMultipart =
          accept != null && accept.contains('multipart/related');
      final att = doc.attachment;
      if (query['attachments'] == 'true' && wantsMultipart && att != null) {
        await _serveMultipart(database, doc, att, response);
        return;
      }
      _json(response, 200, wireDocJson(doc));
      return;
    }
    final winner = database.store.get(docId);
    if (winner == null || winner.deleted) {
      _json(response, 404, {'error': 'not_found', 'reason': 'missing'});
      return;
    }
    _json(response, 200, {
      ...?winner.body,
      '_id': docId,
      '_rev': winner.rev,
    });
  }

  Future<void> _serveMultipart(
    EmulatedDb database,
    RevisionedDoc doc,
    AttachmentRef att,
    HttpResponse response,
  ) async {
    final boundary = mintBoundary();
    final docJson = utf8.encode(jsonEncode(
        wireDocJson(doc, attachmentEncoding: AttachmentEncoding.follows)));
    response.statusCode = 200;
    response.headers
        .set('content-type', 'multipart/related; boundary="$boundary"');
    response.bufferOutput = false;
    response.contentLength = multipartRelatedLength(
      docJsonLength: docJson.length,
      attachmentLength: att.length,
      boundary: boundary,
    );
    final serve = AttachmentServe();
    attachmentServes.add(serve);
    // Re-chunk the blob so the client's streaming is observable: each chunk
    // is flushed before the next is produced.
    Stream<List<int>> chunked() async* {
      await for (final blobChunk
          in database.store.blobStore.openRead(att.digest)) {
        for (var i = 0; i < blobChunk.length; i += attachmentChunkSize) {
          final end = i + attachmentChunkSize > blobChunk.length
              ? blobChunk.length
              : i + attachmentChunkSize;
          final piece = blobChunk.sublist(i, end);
          yield piece;
          serve.bytesServed += piece.length;
          if (attachmentChunkDelay != null) {
            await Future<void>.delayed(attachmentChunkDelay!);
          } else {
            await Future<void>.delayed(Duration.zero);
          }
        }
      }
      serve.done = true;
    }

    await for (final piece in multipartRelatedBody(
      docJson: docJson,
      attachment: chunked(),
      boundary: boundary,
    )) {
      response.add(piece);
      await response.flush();
    }
  }

  Future<void> _putMultipart(
    EmulatedDb database,
    String docId,
    HttpRequest request,
    String? contentType,
    HttpResponse response,
  ) async {
    final boundary = boundaryOf(contentType);
    if (boundary == null) {
      _json(response, 400, {'error': 'missing multipart boundary'});
      return;
    }
    final reader = MultipartReader(request, boundary);
    final docPart = await reader.nextPart();
    if (docPart == null) {
      _json(response, 400, {'error': 'empty multipart body'});
      return;
    }
    final wire = (jsonDecode(await utf8.decodeStream(docPart.body)) as Map)
        .cast<String, Object?>();
    final attachmentPart = await reader.nextPart();
    var doc = revisionedDocFromWire(wire);
    if (attachmentPart != null) {
      final handle = await database.store.blobStore.put(attachmentPart.body);
      doc = doc.withAttachment(
          AttachmentRef(digest: handle.digest, length: handle.length));
    }
    database.store.graft(doc);
    database.touch();
    _json(response, 201, {'ok': true, 'id': doc.id, 'rev': doc.rev});
  }

  Future<void> _putPlain(EmulatedDb database, String docId, Object? jsonBody,
      HttpResponse response) async {
    final body = (jsonBody as Map?)?.cast<String, Object?>() ?? {};
    final existing = database.store.get(docId);
    if (existing != null && !existing.deleted && existing.rev != body['_rev']) {
      _json(response, 409, {'error': 'conflict'});
      return;
    }
    final stripped = <String, Object?>{
      for (final e in body.entries)
        if (!e.key.startsWith('_')) e.key: e.value,
    };
    final rev = await database.store.put(docId, stripped);
    database.touch();
    _json(response, 201, {'ok': true, 'id': docId, 'rev': rev});
  }

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  bool _authorized(HttpRequest request) {
    if (forceUnauthorized) return false;
    if (username == null) return true;
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    final expected =
        'Basic ${base64.encode(utf8.encode('$username:$password'))}';
    return header == expected;
  }

  Future<List<int>> _collect(Stream<List<int>> stream) async {
    final out = <int>[];
    await for (final chunk in stream) {
      out.addAll(chunk);
    }
    return out;
  }

  void _json(HttpResponse response, int status, Object? payload) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(payload));
  }
}

/// The injected HTTP socket layer of `vault_sync`: the module speaks the
/// CouchDB REST protocol, but the host supplies the executor, so the same
/// protocol code drives a real server or an in-process emulator in tests.
library;

import 'dart:async';
import 'dart:io';

/// A cancellation handle for one in-flight request. `SyncEngine.stop()` holds
/// one per pull pass so a longpoll parked on a real CouchDB (whose heartbeat
/// overrides any timeout — the request would otherwise be held open
/// indefinitely) can be aborted promptly instead of outliving the engine.
///
/// Executors honor it by failing the request — and erroring any response body
/// still streaming — with a [SocketException], which the transport maps to
/// `SyncException(unreachable)` like any other broken connection.
class HttpCancelToken {
  bool _cancelled = false;
  final List<void Function()> _actions = [];

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// Abort the request this token was attached to. Idempotent.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final action in List.of(_actions)) {
      action();
    }
    _actions.clear();
  }

  /// Register [action] to run on cancellation (immediately when already
  /// cancelled). Executors use this to hook their abort mechanics.
  void onCancel(void Function() action) {
    if (_cancelled) {
      action();
    } else {
      _actions.add(action);
    }
  }
}

/// One HTTP request as the transport hands it to the executor. The body is a
/// byte stream so multipart attachment uploads stream from the blob store
/// without buffering (RV4).
class HttpExecRequest {
  const HttpExecRequest({
    required this.method,
    required this.uri,
    this.headers = const {},
    this.body,
    this.contentLength,
    this.deadline,
    this.idleDeadline,
    this.cancelToken,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Stream<List<int>>? body;

  /// Total body length when known (multipart uploads compute it); `null`
  /// means chunked transfer encoding.
  final int? contentLength;

  /// How long this request may take to produce response headers before it is
  /// abandoned as unreachable.
  ///
  /// A network that goes away silently leaves connections established here
  /// and dead on the peer — reads on them never fail and never return, so
  /// without a deadline a pass parks forever and takes every pass behind it
  /// with it (`vault_sync` R4). `null` means unbounded.
  final Duration? deadline;

  /// The longest silence tolerated once the response is streaming.
  ///
  /// A parked longpoll is *supposed* to stay open — on a real CouchDB the
  /// heartbeat overrides any timeout — so elapsed time says nothing about its
  /// health. What separates a quiet vault from an unplugged one is that the
  /// quiet one still ticks: this bounds the **gap between bytes**, not the
  /// total (`vault_sync` R4). `null` means unbounded.
  final Duration? idleDeadline;

  /// Optional cancellation handle — when cancelled, the executor aborts the
  /// request (or errors its streaming response body) with an [IOException].
  final HttpCancelToken? cancelToken;
}

/// One HTTP response: status, lowercased headers, and the body as a byte
/// stream — multipart attachment downloads are parsed incrementally off this
/// stream (RV4).
class HttpExecResponse {
  const HttpExecResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;

  /// Header names lowercased; multi-values joined with `, `.
  final Map<String, String> headers;

  final Stream<List<int>> body;
}

/// The executor interface the host injects. Implementations surface network
/// failures as [SocketException] / [HttpException] (or any [IOException]) —
/// the transport maps them to `SyncException(unreachable)`.
abstract interface class HttpExec {
  Future<HttpExecResponse> send(HttpExecRequest request);
}

/// The default executor over `dart:io`'s [HttpClient] — the production
/// socket layer of both shells.
class IoHttpExec implements HttpExec {
  IoHttpExec({Duration connectTimeout = const Duration(seconds: 20)})
      : _client = HttpClient()..connectionTimeout = connectTimeout;

  final HttpClient _client;

  @override
  Future<HttpExecResponse> send(HttpExecRequest request) async {
    final token = request.cancelToken;
    if (token != null && token.isCancelled) {
      throw const SocketException('request aborted');
    }
    final io = await _client.openUrl(request.method, request.uri);
    // Abort covers the phase before the response arrives (connection setup,
    // request body, awaiting headers).
    token?.onCancel(() => io.abort(const SocketException('request aborted')));

    // The deadline is enforced by the same abort path as cancellation, so a
    // silently dead connection surfaces as an ordinary broken one — which the
    // transport already maps to `unreachable` and the engine already retries
    // (`vault_sync` R4).
    Timer? deadline;
    if (request.deadline != null) {
      deadline = Timer(request.deadline!, () {
        io.abort(SocketException(
          'request exceeded its deadline of ${request.deadline!.inSeconds}s '
          '— the connection is established here but silent on the other side',
        ));
      });
    }

    request.headers.forEach(io.headers.set);
    if (request.contentLength != null) {
      io.contentLength = request.contentLength!;
    }
    try {
      if (request.body != null) {
        await io.addStream(request.body!);
      }
      final response = await io.close();
      deadline?.cancel();
      return _respond(response, token, request.idleDeadline);
    } catch (_) {
      deadline?.cancel();
      rethrow;
    }
  }

  HttpExecResponse _respond(
    HttpClientResponse response,
    HttpCancelToken? token,
    Duration? idleDeadline,
  ) {
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    return HttpExecResponse(
      statusCode: response.statusCode,
      headers: headers,
      body: token == null && idleDeadline == null
          ? response
          : _guarded(response, token, idleDeadline),
    );
  }

  /// Pipe [source] through a controller so two things can interrupt a body
  /// that is still streaming.
  ///
  /// A cancellation (a longpoll parked with heartbeats keeps the body open
  /// indefinitely on real CouchDB) errors the stream promptly and tears the
  /// connection down — an undrained response never returns to the keep-alive
  /// pool, so dart:io closes its socket.
  ///
  /// [idleDeadline] does the same when the stream falls **silent** for too
  /// long. That is the only signal that separates a quiet vault from a dead
  /// connection, because a healthy parked longpoll keeps heartbeating while a
  /// severed one simply stops (`vault_sync` R4).
  Stream<List<int>> _guarded(
    Stream<List<int>> source,
    HttpCancelToken? token,
    Duration? idleDeadline,
  ) {
    final controller = StreamController<List<int>>();
    late final StreamSubscription<List<int>> sub;
    Timer? idle;

    controller.onListen = () {
      void fail(String message) {
        idle?.cancel();
        unawaited(sub.cancel());
        if (!controller.isClosed) {
          controller.addError(SocketException(message));
          unawaited(controller.close());
        }
      }

      void touch() {
        if (idleDeadline == null) return;
        idle?.cancel();
        idle = Timer(
          idleDeadline,
          () => fail('no data for ${idleDeadline.inSeconds}s — the connection '
              'is established here but silent on the other side'),
        );
      }

      sub = source.listen(
        (chunk) {
          touch();
          controller.add(chunk);
        },
        onError: (Object e, StackTrace s) {
          idle?.cancel();
          controller.addError(e, s);
        },
        onDone: () {
          idle?.cancel();
          controller.close();
        },
      );
      touch();
      controller
        ..onPause = sub.pause
        ..onResume = sub.resume
        ..onCancel = () {
          idle?.cancel();
          return sub.cancel();
        };
      token?.onCancel(() => fail('request aborted'));
    };
    return controller.stream;
  }

  void close() => _client.close(force: true);
}

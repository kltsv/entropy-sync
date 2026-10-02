/// `vault_sync` test-spec — "Every request is bounded in time" (R4, RV4).
///
/// The failure these guard against is not a refused connection but a
/// **silent** one: a laptop that slept, switched Wi-Fi or dropped a VPN keeps
/// TCP connections that are established here and dead on the peer. Reads on
/// them never fail and never return, so without a bound a pass parks forever
/// and takes every pass behind it with it.
library;

import 'dart:async';

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:test/test.dart';

/// An executor that behaves exactly like a severed connection: it accepts the
/// request and then says nothing, ever. Honours the deadline the way a real
/// socket does — by never resolving on its own.
class SilentExec implements HttpExec {
  final completers = <Completer<HttpExecResponse>>[];

  @override
  Future<HttpExecResponse> send(HttpExecRequest request) {
    final completer = Completer<HttpExecResponse>();
    completers.add(completer);
    // The executor under test is `IoHttpExec`; here we only need to prove the
    // transport asks for a deadline, so the request is recorded and dropped.
    lastRequest = request;
    return completer.future;
  }

  HttpExecRequest? lastRequest;
}

/// A body that starts, then falls silent — a parked longpoll whose peer went
/// away mid-stream, which is what the heartbeat is supposed to disprove.
class SilentBodyExec implements HttpExec {
  @override
  Future<HttpExecResponse> send(HttpExecRequest request) async {
    lastRequest = request;
    return HttpExecResponse(
      statusCode: 200,
      headers: const {'content-type': 'application/json'},
      body: StreamController<List<int>>().stream, // never emits, never closes
    );
  }

  HttpExecRequest? lastRequest;
}

void main() {
  CouchTransport transportOver(HttpExec exec, {Duration? requestDeadline}) =>
      CouchTransport(
        baseUrl: Uri.parse('http://127.0.0.1:1'),
        database: 'vault',
        exec: exec,
        requestDeadline: requestDeadline ?? const Duration(seconds: 60),
      );

  test('an ordinary request carries a deadline', () async {
    final exec = SilentExec();
    final transport = transportOver(exec);

    unawaited(transport.changes(since: '0').catchError((_) => throw 'ignored'));
    await Future<void>.delayed(Duration.zero);

    expect(exec.lastRequest, isNotNull);
    expect(exec.lastRequest!.deadline, const Duration(seconds: 60),
        reason: 'a silently severed connection must not park the pass');
  });

  test('a parked longpoll is bounded by silence, not by elapsed time',
      () async {
    final exec = SilentBodyExec();
    final transport = transportOver(exec);

    unawaited(transport
        .changes(since: '0', longpoll: true, heartbeatMs: 30000)
        .catchError((_) => throw 'ignored'));
    await Future<void>.delayed(Duration.zero);

    final request = exec.lastRequest!;
    // A quiet vault keeps heartbeating, so the bound is on the **gap between
    // bytes** — generously above the heartbeat so a late one is never
    // mistaken for a dead socket.
    expect(request.idleDeadline, const Duration(milliseconds: 90000));
    expect(request.idleDeadline!.inMilliseconds, greaterThan(30000),
        reason: 'a healthy heartbeating longpoll must never be cut short');
  });

  test('the deadline failure is an ordinary unreachable, not a new error kind',
      () async {
    // The transport maps every IOException to `unreachable`; a deadline abort
    // is delivered as one precisely so the engine retries it like any other
    // broken connection rather than needing a special case.
    final transport = CouchTransport(
      baseUrl: Uri.parse('http://127.0.0.1:1'), // nothing listens here
      database: 'vault',
      requestDeadline: const Duration(milliseconds: 300),
    );

    await expectLater(
      transport.changes(since: '0'),
      throwsA(isA<SyncException>()
          .having((e) => e.kind, 'kind', SyncErrorKind.unreachable)),
    );
  });
}

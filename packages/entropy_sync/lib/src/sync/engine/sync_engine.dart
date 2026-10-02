/// The continuous engine of `vault_sync` (RV4): the longpoll pull loop with
/// exponential-backoff reconnect, the ~2 s debounced push scheduler, the
/// change / conflict / status streams, an on-demand `syncNow()` pass, and
/// host-driven conflict resolution.
library;

import 'dart:async';

import '../model/events.dart';
import '../replication/replicator.dart';
import '../store/local_store.dart';
import '../transport/couch_transport.dart';
import '../transport/http_exec.dart';
import '../transport/sync_exception.dart';

/// The continuous replication engine: `start()` brings up the longpoll pull
/// loop and the debounced push scheduler; `stop()` quiesces them; `syncNow()`
/// runs one discrete pull-then-push pass — the building block for tests,
/// `sync-now` controls, and hosts that prefer explicit scheduling (RV4).
///
/// Timing knobs are constructor parameters so tests run fast; the defaults
/// are the spec's: ~2 s push debounce, 1 s → 60 s exponential backoff,
/// 30 000 ms longpoll heartbeat.
class SyncEngine {
  SyncEngine({
    required this.store,
    required this.transport,
    required this.replicaId,
    this.pushDebounce = const Duration(seconds: 2),
    this.backoffBase = const Duration(seconds: 1),
    this.backoffCap = const Duration(seconds: 60),
    this.heartbeatMs = 30000,
    this.longpollTimeoutMs,
    this.batchLimit = 200,
    int bulkDocsMaxCount = 100,
    int bulkDocsMaxBytes = 10 * 1024 * 1024,
  }) : _replicator = Replicator(
          store: store,
          transport: transport,
          replicaId: replicaId,
          bulkDocsMaxCount: bulkDocsMaxCount,
          bulkDocsMaxBytes: bulkDocsMaxBytes,
        ) {
    store.onChange(_onStoreChange);
    store.onConflict(_onStoreConflict);
  }

  final LocalStore store;
  final CouchTransport transport;

  /// Unique per (vault, device) — keys the local-only checkpoints (RV4).
  final String replicaId;

  /// Local writes debounce push by this long, so a burst of rapid saves
  /// ships as one batch (~2 s by default, RV4).
  final Duration pushDebounce;

  /// First reconnect delay after a broken pull loop; doubles per failure.
  final Duration backoffBase;

  /// Reconnect delay ceiling.
  final Duration backoffCap;

  /// Longpoll heartbeat interval — keeps the connection alive through
  /// proxies (RV4).
  final int heartbeatMs;

  /// Optional longpoll `timeout` (server-side); `null` uses the server
  /// default. Tests shrink it so parked requests return fast.
  final int? longpollTimeoutMs;

  /// `_changes` page size.
  final int batchLimit;

  final Replicator _replicator;

  final _changes = StreamController<Change>.broadcast();
  final _conflicts = StreamController<ConflictReport>.broadcast();
  final _status = StreamController<SyncStatus>.broadcast();

  bool _running = false;
  bool _online = false;
  String? _error;
  bool _revsLimitAdopted = false;
  SyncStatus? _lastStatus;
  Timer? _debounce;
  bool _pushing = false;
  bool _pushQueued = false;
  Completer<void> _stopSignal = Completer<void>();

  /// Bumped on every [start] — an epoch. A pull pass captures the value at
  /// loop entry and discards its results when it no longer matches (the
  /// engine was stopped, or stopped-and-restarted): an abandoned pass must
  /// never graft or write checkpoints through a stale store.
  int _generation = 0;

  /// Cancellation handle of the in-flight pull request. On real CouchDB the
  /// longpoll heartbeat overrides any timeout, so a parked request is held
  /// open indefinitely — [stop] aborts it through this token.
  HttpCancelToken? _pullCancel;

  /// One event per document reaching a new winning revision, tagged `local`
  /// or `remote` — the shells materialize files and drive history from
  /// exactly this stream; nothing polls (R6).
  Stream<Change> get changes => _changes.stream;

  /// One event per document left with more than one live leaf after a graft,
  /// each loser carried with its content (R9).
  Stream<ConflictReport> get conflicts => _conflicts.stream;

  /// Live health for the control surfaces (R17); distinct values only.
  Stream<SyncStatus> get status => _status.stream;

  // ---------------------------------------------------------------------------
  // Lifecycle (RV4)
  // ---------------------------------------------------------------------------

  /// Bring up the continuous loops: mirror the server's `_revs_limit` (read
  /// once; never written back, C7), start the longpoll pull loop, and
  /// schedule a push if local revisions already await one.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _generation += 1;
    _stopSignal = Completer<void>();
    await _adoptRevsLimit();
    unawaited(_pullLoop());
    if (store.pendingPushCount > 0) _schedulePush();
  }

  /// Quiesce the loops. The in-flight pull request (a longpoll parked on the
  /// server — held open indefinitely by the heartbeat on real CouchDB) is
  /// aborted, and the generation check discards any results a still-running
  /// pass produces after this point.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _generation += 1;
    _debounce?.cancel();
    _debounce = null;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    _pullCancel?.cancel();
    _pullCancel = null;
  }

  /// One discrete pull-then-push pass. Throws [SyncException] on failure —
  /// the shells surface the error and stay offline-first (R3).
  Future<void> syncNow() async {
    try {
      await _adoptRevsLimit();
      await _replicator.pullOnce(limit: batchLimit);
      await _replicator.pushOnce();
      _online = true;
      _error = null;
      _publishStatus();
    } on SyncException catch (e) {
      _online = false;
      _error = '${e.kind.name}: ${e.message}';
      _publishStatus();
      rethrow;
    }
  }

  /// Host-driven conflict resolution (R9): tombstone the named losing leaves
  /// (idempotently) and schedule a push so the resolution replicates.
  Future<void> resolve(String id, List<String> loserRevs) async {
    await store.resolveConflict(id, loserRevs);
    if (_running) _schedulePush();
  }

  // ---------------------------------------------------------------------------
  // The pull loop (RV4)
  // ---------------------------------------------------------------------------

  Future<void> _adoptRevsLimit() async {
    if (_revsLimitAdopted) return;
    try {
      store.setRevsLimit(await transport.getRevsLimit());
      _revsLimitAdopted = true;
    } on SyncException {
      // Unreachable — the loop retries before the next pull.
    }
  }

  Future<void> _pullLoop() async {
    final generation = _generation;
    bool abandoned() => !_running || generation != _generation;
    var backoff = backoffBase;
    while (!abandoned()) {
      final cancel = _pullCancel = HttpCancelToken();
      try {
        await _adoptRevsLimit();
        // Catch-up first: a discrete (non-longpoll) pull that returns as
        // soon as the feed is drained, so reconnection is observed — and
        // queued writes ship (R3, R4) — even though the longpoll that
        // follows may park for a long time on an idle database.
        await _replicator.pullOnce(
          limit: batchLimit,
          cancelToken: cancel,
          abandoned: abandoned,
        );
        if (abandoned()) break;
        backoff = backoffBase;
        _markPullHealthy();
        // Park: the longpoll cycle is the realtime subscription (N10). On
        // real CouchDB the heartbeat keeps it open until a change arrives;
        // stop() aborts it through the cancel token.
        await _replicator.pullOnce(
          longpoll: true,
          limit: batchLimit,
          heartbeatMs: heartbeatMs,
          timeoutMs: longpollTimeoutMs,
          cancelToken: cancel,
          abandoned: abandoned,
        );
        if (abandoned()) break;
        backoff = backoffBase;
        _markPullHealthy();
      } catch (e) {
        if (abandoned()) break;
        // Disconnections reconnect with exponential backoff; the online
        // status flag reflects this loop's health (RV4, R17). Catches
        // **everything** — nothing may escape this unawaited future and
        // kill the host process (a raw IOException mid-attachment-download
        // used to).
        _online = false;
        _error =
            e is SyncException ? '${e.kind.name}: ${e.message}' : 'error: $e';
        _publishStatus();
        await _interruptibleSleep(backoff);
        backoff = backoff * 2 > backoffCap ? backoffCap : backoff * 2;
      } finally {
        if (identical(_pullCancel, cancel)) _pullCancel = null;
      }
    }
  }

  void _markPullHealthy() {
    _online = true;
    _error = null;
    _publishStatus();
    // Writes queued while offline ship once the hub is reachable again
    // (R3, R4): reconnecting reconciles both directions.
    if (store.pendingPushCount > 0) _schedulePush();
  }

  Future<void> _interruptibleSleep(Duration duration) => Future.any(
      <Future<void>>[Future<void>.delayed(duration), _stopSignal.future]);

  // ---------------------------------------------------------------------------
  // The push scheduler (RV4)
  // ---------------------------------------------------------------------------

  void _onStoreChange(Change change) {
    _changes.add(change);
    if (change.origin == ChangeOrigin.local && _running) _schedulePush();
    _publishStatus();
  }

  void _onStoreConflict(ConflictReport report) => _conflicts.add(report);

  void _schedulePush() {
    _debounce?.cancel();
    _debounce = Timer(pushDebounce, () {
      _debounce = null;
      unawaited(_pushGuarded());
    });
  }

  Future<void> _pushGuarded() async {
    if (_pushing) {
      _pushQueued = true;
      return;
    }
    _pushing = true;
    try {
      do {
        _pushQueued = false;
        try {
          await _replicator.pushOnce();
          _online = true;
          _error = null;
        } catch (e) {
          // Catches everything — nothing may escape this unawaited future
          // and kill the host process.
          _online = false;
          _error =
              e is SyncException ? '${e.kind.name}: ${e.message}' : 'error: $e';
        }
        _publishStatus();
      } while (_pushQueued && _running);
    } finally {
      _pushing = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Status (R17)
  // ---------------------------------------------------------------------------

  void _publishStatus() {
    final next = SyncStatus(
      online: _online,
      pendingPush: store.pendingPushCount,
      lastSeq: store.getCheckpoint('pull:$replicaId') ?? '0',
      error: _error,
    );
    if (next == _lastStatus) return;
    _lastStatus = next;
    _status.add(next);
  }
}

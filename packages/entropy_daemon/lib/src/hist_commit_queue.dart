import 'dart:typed_data';

import 'package:entropy_hist/entropy_hist.dart';

/// Decides **when** an edit becomes a version (`vault_daemon`, D7).
///
/// `vault_hist` has no timers of its own: it records exactly what it is
/// committed. The two duties that follow are the daemon's, and they live
/// here:
///
/// - **Coalescing.** Editors save by writing a temporary file and renaming
///   it, or by deleting and recreating. Committing those raw states verbatim
///   would record a deletion and a brand-new life for every ordinary save, and
///   one version per reconcile pass for a burst of autosaves. States offered
///   for a path accumulate; only the last one, once the path has been quiet
///   for [idleMillis], is committed.
/// - **Ordering.** A local edit that raced an incoming change is committed
///   **before** the arrival is applied, so it records from the base it was
///   actually made on. Only the caller can guarantee that, which is why the
///   timing lives on this side.
///
/// The last known content per path is kept in memory purely so a commit can
/// be handed the base's bytes when the history folder cannot supply them
/// (a file that predates history). It is a cache, never a source of truth:
/// losing it costs nothing, because `commit` recovers the base from the graph
/// whenever the lineage is unambiguous.
class HistCommitQueue {
  HistCommitQueue({
    required this.hist,
    required this.now,
    required this.idleMillis,
  });

  final HistWriter hist;

  /// Injected clock (UTC epoch ms).
  final int Function() now;

  /// How long a path must be quiet before its final state becomes a version.
  final int idleMillis;

  final Map<String, _Pending> _pending = {};
  final Map<String, Uint8List?> _lastKnown = {};

  /// A local edit was observed. Nothing is written yet.
  void offer(String path, List<int>? content) {
    _pending[path] = _Pending(
      content == null ? null : Uint8List.fromList(content),
      now(),
    );
  }

  /// A change that arrived through sync was applied locally.
  ///
  /// Any pending local edit for the path is committed **first** — from the
  /// base it was made on — and the arrival itself is **never** committed: it
  /// was recorded by the writer that made it, and recording it again would
  /// mint a second edge for one edit and attribute it to this device
  /// (`vault_hist` RV6).
  Future<void> adopt(String path, List<int>? content) async {
    await flushPath(path);
    _lastKnown[path] = content == null ? null : Uint8List.fromList(content);
  }

  /// Commit the pending state of one path immediately, if any.
  Future<void> flushPath(String path) async {
    final pending = _pending[path];
    if (pending != null) await _commit(path, pending);
  }

  /// Commit every path that has been quiet for [idleMillis]; returns the
  /// paths for which something was written. A commit that fails (history
  /// cannot write — a full disk) stays pending and is retried on the next
  /// flush; the first failure is rethrown after every path was tried, so the
  /// host can report the module degraded (`daemon-modules` R3) without one
  /// path's failure holding back the others.
  Future<List<String>> flushIdle() async {
    final nowMillis = now();
    final written = <String>[];
    Object? firstError;
    for (final path in _pending.keys.toList()) {
      final pending = _pending[path]!;
      if (nowMillis - pending.atMillis < idleMillis) continue;
      try {
        if (await _commit(path, pending)) written.add(path);
      } catch (e) {
        firstError ??= e;
      }
    }
    if (firstError != null) throw firstError;
    return written;
  }

  /// Commit everything pending regardless of idle (shutdown helper).
  Future<void> flushAll() async {
    Object? firstError;
    for (final path in _pending.keys.toList()) {
      try {
        await _commit(path, _pending[path]!);
      } catch (e) {
        firstError ??= e;
      }
    }
    if (firstError != null) throw firstError;
  }

  /// Drop a path's pending state and cached base without recording — used
  /// when a rename marker supersedes the raw delete/create pair.
  void forget(String path) {
    _pending.remove(path);
    _lastKnown.remove(path);
  }

  /// Commit one pending state. On success it leaves the queue; on failure
  /// it stays, so the next flush retries it from the same base.
  Future<bool> _commit(String path, _Pending pending) async {
    final wrote = await hist.commit(
      path,
      pending.content,
      previous: _lastKnown[path],
      at: pending.atMillis, // when the edit happened, not when it settled
    );
    // A newer offer may have replaced this one while the commit ran; only
    // retire the state that was committed.
    if (identical(_pending[path], pending)) _pending.remove(path);
    _lastKnown[path] = pending.content;
    return wrote;
  }
}

class _Pending {
  _Pending(this.content, this.atMillis);

  /// The latest state offered for the path (`null` = absent).
  final Uint8List? content;
  final int atMillis;
}

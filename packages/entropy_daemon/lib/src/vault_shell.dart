import 'dart:async';
import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:entropy_sync/entropy_sync.dart';

import 'config.dart';
import 'folder/vault_folder.dart';
import 'hist_commit_queue.dart';
import 'last_synced.dart';
import 'modules/history_module.dart';
import 'modules/sync_module.dart';
import 'os_integration.dart';

/// One vault's **host** (`vault_daemon` RV1, `daemon-modules` R1–R3):
/// the process-side glue that owns the folder service and drives the
/// vault's enabled modules over it — **sync** ([SyncModule]) and **history**
/// ([HistoryModule]), any subset. All logic lives in the modules; this class
/// only routes between them, and no module ever names another.
///
/// The vault folder itself belongs to [VaultFolder] (`vault_folder` R4): it
/// walks, coalesces raw editor events into **settled states**, hashes them
/// once, and performs **every** write, so neither the host nor a module
/// watches or writes into the vault directly. Each state it hands back is
/// attributed — a local edit, or a materialization a module asked for — and
/// that attribution is what [_apply] routes on: sync pushes local states
/// and history is offered them; history adopts materializations, which is
/// also the echo-loop guard (a write is never re-ingested as an edit, matched
/// by content, not by timing).
///
/// Every arrow between modules goes through here: sync tells the host when a
/// local state turned out to be agreement with the replica (history then
/// adopts instead of offering), hands it a losing binary (history rescues
/// it), and asks it to route a racing local edit — and the host tells
/// whichever module is there. A module that fails is isolated (R3): its
/// error is recorded against it, the others keep running.
///
/// Reconciliation is **poll-based** (`reconcile`) for determinism and tests;
/// continuous operation (`start`) adds the core engine's longpoll pull and
/// materializes remote changes as they arrive. Reconcile, ingest and
/// materialize passes serialize through a per-vault async mutex: overlapping
/// requests never interleave, and a reconcile requested while one runs
/// coalesces into a single follow-up pass.
class VaultShell implements SyncHost {
  VaultShell({
    required this.profile,
    required this.folder,
    required this.stateDir,
    this.sync,
    this.history,
    this.historyFactory,
    DaemonLog? log,
  }) : _log = log {
    sync?.bind(this);
    history?.syncRules();
  }

  /// The vault's profile — replaced in place by [reconfigureHistory] when a
  /// history setting changes (`daemon-modules` R9).
  VaultProfile profile;

  /// The single owner of the vault folder (`vault_folder` R4): every state
  /// the host acts on comes from here, and every write goes through here.
  final VaultFolder folder;

  /// This vault's state directory (cursor, blob store, logs, trash fallback).
  final String stateDir;

  /// The replication module, when the vault enables it.
  final SyncModule? sync;

  /// The history module, when the vault enables it — rebuilt in place by
  /// [reconfigureHistory].
  HistoryModule? history;

  /// Builds a history module over this vault's folder for a profile — how a
  /// history setting takes effect without touching sync (R9).
  final HistoryModule Function(VaultProfile profile, VaultFolder folder)?
      historyFactory;

  final DaemonLog? _log;

  /// Apply [next]'s history block in place: pending edits of the old module
  /// are committed first, then the module is rebuilt over the same folder
  /// (or dropped when [next] disables history). The sync module is never
  /// touched.
  Future<void> reconfigureHistory(VaultProfile next) async {
    final factory = historyFactory;
    if (next.historyEnabled && factory == null) {
      throw StateError('this host cannot build a history module');
    }
    final old = history;
    if (old != null) await _module(HistoryModule.name, old.flushAll);
    history = next.historyEnabled ? factory!(next, folder) : null;
    moduleErrors.remove(HistoryModule.name);
    history?.syncRules();
    profile = next;
  }

  /// The modules this vault enables, by name (`daemon-modules` R1).
  List<String> get modules => [
        if (sync != null) SyncModule.name,
        if (history != null) HistoryModule.name,
      ];

  /// Per-module failures (`daemon-modules` R3): a module whose last
  /// operation failed is **degraded** — named here with its error — while the
  /// others keep running. Cleared when the module's next operation succeeds.
  final Map<String, String> moduleErrors = {};

  bool _paused = false;

  @override
  bool get paused => _paused;
  set paused(bool value) => _paused = value;

  String? _hostError;

  /// The vault's error as status shows it: a host-level failure, else the
  /// sync module's (`unreachable: …` reads as offline). A degraded history
  /// module is reported in [moduleErrors], not here — the vault keeps
  /// syncing.
  String? get lastError => _hostError ?? sync?.lastError;
  set lastError(String? value) {
    _hostError = value;
    if (value == null) sync?.lastError = null;
  }

  int get lastSyncMillis => sync?.lastSyncMillis ?? 0;
  int get unsynced => sync?.unsynced ?? 0;
  List<String> get conflictPaths => sync?.conflictPaths ?? const [];
  int get divergent => history?.divergent ?? 0;
  List<String> get divergentFiles => history?.divergentFiles ?? const [];

  String get vaultRoot => profile.vaultRoot;

  // --- the modules' own pieces, for hosts and tests that reach them --------

  SyncModule get _requireSync =>
      sync ??
      (throw StateError('vault "${profile.vaultId}" has no sync module'));
  HistoryModule get _requireHistory =>
      history ??
      (throw StateError('vault "${profile.vaultId}" has no history module'));

  LocalStore get store => _requireSync.store;
  CouchTransport get transport => _requireSync.transport;
  VaultCrypto get crypto => _requireSync.crypto;
  SyncEngine get engine => _requireSync.engine;
  String get replicaId => _requireSync.replicaId;
  LastSyncedIndex get lastSynced => _requireSync.lastSynced;
  HistWriter get hist => _requireHistory.writer;
  HistCommitQueue get histQueue => _requireHistory.queue;

  void _logLine(String message) => _log?.log('[${profile.vaultId}] $message');

  /// Whether [path] is excluded from sync, watching, scanning and history —
  /// the folder's answer (built-ins, the profile list, every applicable
  /// `.syncignore`), which is the only one there is (R7).
  bool excludes(String path) => folder.excludes(path);

  /// The per-vault async mutex: reconcile / ingest / materialize / rescue
  /// passes run strictly one at a time.
  Future<void> _chain = Future<void>.value();

  /// The reconcile pass currently queued but not yet started — a second
  /// request coalesces into it instead of stacking another full pass.
  Future<void>? _queuedReconcile;

  /// Serialize [body] behind the mutex. Errors propagate to the caller but
  /// never break the chain.
  Future<T> _serialized<T>(Future<T> Function() body) {
    final run = _chain.then((_) => body());
    _chain = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// The cheap per-pass rule reload (RV8 "effect and timing"): the folder
  /// stats its known rule files; each module picks up a new generation.
  void _refreshIgnoreRules() {
    folder.refreshRules();
    sync?.syncRules();
    history?.syncRules();
  }

  // ---------------------------------------------------------------------------
  // Failure isolation (R3)
  // ---------------------------------------------------------------------------

  /// Run one module's operation: a failure is recorded against that module
  /// and logged, and never reaches the other module or the pass.
  Future<void> _module(String name, Future<void> Function() body) async {
    try {
      await body();
      moduleErrors.remove(name);
    } catch (e) {
      moduleErrors[name] = e.toString();
      _logLine('[$name] error: $e');
    }
  }

  @override
  Future<void> safely(Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      _noteError(e);
    }
  }

  void _noteError(Object error) {
    _hostError = error.toString();
    _logLine('error: $error');
  }

  /// Run [body] with errors captured into [lastError] and the log — the
  /// guard every fire-and-forget entry point (timers, watcher flushes,
  /// stream handlers) routes through so nothing escapes as an unhandled
  /// async error and kills the daemon.
  Future<void> guarded(Future<void> Function() body) => safely(body);

  /// A reconcile that never throws — the entry point for fire-and-forget
  /// callers (periodic rescan timers, resume catch-up): errors land in
  /// [lastError] and the log instead of escaping as an unhandled async error.
  Future<void> reconcileGuarded() => safely(reconcile);

  // ---------------------------------------------------------------------------
  // Continuous mode
  // ---------------------------------------------------------------------------

  /// Start continuous operation: sync's longpoll pull + debounced push, with
  /// remote winners materialized (and conflicts rescued) as they arrive.
  Future<void> start() async {
    final s = sync;
    if (s != null) await _module(SyncModule.name, s.start);
  }

  Future<void> stop() async {
    final s = sync;
    if (s != null) await _module(SyncModule.name, s.stop);
    final h = history;
    if (h != null) await _module(HistoryModule.name, h.flushAll);
  }

  // ---------------------------------------------------------------------------
  // Reconcile (deterministic pass: scan → sync → rescue → materialize)
  // ---------------------------------------------------------------------------

  /// One full reconciliation pass. Used by tests, `sync-now`, the periodic
  /// rescan, and the startup catch-up. Passes serialize: a reconcile
  /// requested while one is queued joins it; one requested while one is
  /// *running* schedules exactly one follow-up pass.
  Future<void> reconcile() {
    if (paused) return Future.value();
    final queued = _queuedReconcile;
    if (queued != null) return queued;
    late final Future<void> pass;
    pass = _serialized(() {
      if (identical(_queuedReconcile, pass)) _queuedReconcile = null;
      _refreshIgnoreRules();
      return _reconcilePass();
    });
    _queuedReconcile = pass;
    return pass;
  }

  Future<void> _reconcilePass() async {
    final s = sync;
    var seeding = false;
    if (s != null) {
      // A fresh replica must not assume a fresh *database*: pull FIRST, so
      // that re-attaching to a populated database (restored backup, wiped
      // state dir) grafts the server's revision trees before the disk scan —
      // files identical to the pulled winners then repair the cursor without
      // minting revisions, and files that differ become real local edits /
      // conflict branches. Only when the database has no content either does
      // the scan seed (D5: the first scan into an empty database IS the
      // initial sync).
      final fresh = s.freshReplica; // never synced, not even meta
      if (s.replicaHasNoContent) {
        await s.syncNow();
        await s.materializeAll();
      }
      // Seed (D5's baseline-only first scan) only when this replica had never
      // synced anything AND the pull just proved the database empty too.
      seeding = fresh && s.replicaHasNoContent;
    }
    await _scanDisk(seed: seeding);
    if (s != null) {
      await s.syncNow();
      s.refreshConflictPaths();
      await s.rescueLiveConflicts();
      await s.materializeAll();
    }
    final h = history;
    if (h != null) {
      await _module(HistoryModule.name, () async {
        await h.flushIdle();
        // The periodic pass is the backstop: a full recount catches whatever
        // an incremental recount missed (history-surface R18).
        await h.recountAll();
      });
    }
  }

  /// Ask the folder service for everything that changed and act on it —
  /// including rename detection by content hash (`vault_daemon` RV7).
  Future<void> scanDisk({bool seed = false}) => _serialized(() {
        _refreshIgnoreRules();
        return _scanDisk(seed: seed);
      });

  Future<void> _scanDisk({bool seed = false}) async {
    // A failed *listing* (directory vanishing mid-scan, permissions) skips the
    // whole scan pass: a PARTIAL one would misread the missing files as local
    // deletions. The next pass retries; it never crashes the daemon.
    final FolderScan scan;
    try {
      scan = await folder.rescan();
    } on FileSystemException catch (e) {
      _logLine('scan: walk failed, skipping this pass: $e');
      return;
    }
    // One unreadable file never aborts the pass: the folder left it out of
    // its record, so the next pass retries it.
    scan.failures.forEach((path, failure) {
      _noteError('cannot read $path: $failure');
    });
    // The walk may have discovered a rule file; every module tracks it.
    sync?.syncRules();
    history?.syncRules();
    sync?.dropExcludedCheckpoints();

    final gone = [
      for (final s in scan.states)
        if (s.isAbsent) s
    ];
    final present = [
      for (final s in scan.states)
        if (!s.isAbsent) s
    ];

    // Rename: an appeared file whose hash equals a removed file's last-known
    // hash (RV7) — wire delete+create, history marker pair, no folder move.
    // The folder's states carry what was there, so no module's record is
    // needed to pair them. Pair only unambiguous, non-empty matches: empty
    // files are never rename-paired, and a hash shared by several removed or
    // several appeared files degrades to plain delete + create instead of
    // guessing.
    final matchedRemoved = <String>{};
    final renamedNew = <String>{};
    if (gone.isNotEmpty) {
      final removedByHash = <String, List<String>>{};
      for (final old in gone) {
        final hash = old.previousHash ?? sync?.checkpointHashOf(old.path);
        if (hash == null) continue;
        removedByHash.putIfAbsent(hash, () => []).add(old.path);
      }
      final appearedByHash = <String, List<FolderState>>{};
      for (final state in present) {
        if (!state.isNew) continue; // changed, not new
        if (state.sizeBytes == 0) continue; // empty: never a rename candidate
        if (!removedByHash.containsKey(state.hash)) continue;
        appearedByHash.putIfAbsent(state.hash!, () => []).add(state);
      }
      for (final match in appearedByHash.entries) {
        final olds = removedByHash[match.key];
        if (olds == null || olds.length != 1 || match.value.length != 1) {
          continue; // ambiguous — degrade to delete + create
        }
        final state = match.value.single;
        try {
          await _applyRename(olds.single, state);
          matchedRemoved.add(olds.single);
          renamedNew.add(state.path);
        } catch (e) {
          _hostError = e.toString();
          _logLine('rename ${olds.single} → ${state.path} failed: $e');
        }
      }
    }

    for (final state in scan.states) {
      if (state.isAbsent && matchedRemoved.contains(state.path)) continue;
      if (!state.isAbsent && renamedNew.contains(state.path)) continue;
      // One failing file never aborts the pass (or crashes the daemon).
      await safely(() => _apply(state, seed: seed));
    }
  }

  Future<void> _applyRename(String oldPath, FolderState state) async {
    final s = sync;
    if (s != null) await s.applyRename(oldPath, state);
    final h = history;
    if (h != null) {
      await _module(HistoryModule.name, () => h.onRename(oldPath, state));
    }
  }

  /// Route one settled state by its **origin** — the whole interface the
  /// folder service offers, and the reason no module here names another
  /// (`vault_folder` R5).
  ///
  /// A *local* state is an edit made on this machine: sync encrypts and
  /// pushes it, history is offered it — unless sync found it was agreement
  /// with the replica, or this is the seeding scan, in which case history
  /// adopts it as a baseline. A *materialized* one was written by a module on
  /// behalf of a revision somebody else authored: history **adopts** it.
  @override
  Future<void> apply(FolderState state) => _apply(state);

  Future<void> _apply(FolderState state, {bool seed = false}) async {
    final s = sync;
    final h = history;
    switch (state.origin) {
      case LocalEdit():
        var adopt = seed;
        var skipHistory = false;
        if (s != null) {
          try {
            if (state.isAbsent) {
              await s.ingestDelete(state.path);
            } else {
              switch (await s.ingestLocal(state)) {
                case IngestOutcome.edit:
                  break;
                case IngestOutcome.agreed:
                  adopt = true;
                case IngestOutcome.unchanged:
                  skipHistory = true;
              }
            }
          } catch (_) {
            _handBack(state);
            rethrow;
          }
        }
        if (h != null && !skipHistory) {
          await _module(
              HistoryModule.name, () => h.onLocalState(state, adopt: adopt));
        }
      case Materialized():
        if (h != null) {
          await _module(HistoryModule.name, () => h.onMaterialized(state));
        }
    }
    // A history file — written here by the writer, or arriving through
    // sync — changes exactly one path's graph: recount it (R16, R18).
    if (h != null && state.path.startsWith('${HistWriter.mirrorRoot}/')) {
      await _module(HistoryModule.name, () => h.onHistoryFile(state.path));
    }
  }

  /// Hand a state sync could not apply **back** to the folder service, to be
  /// reported again: forgetting a path makes the next pass see it as new,
  /// and restoring what preceded a deletion makes the next pass see the
  /// deletion again. The service queues nothing durably, so without this one
  /// failure would lose the change along with the event that carried it.
  ///
  /// A **materialization** is deliberately never handed back: re-reporting it
  /// would offer somebody else's change to history as this device's edit
  /// (RV6). Its checkpoint already records the winner, so the next pass skips
  /// it — exactly as it did before the service existed.
  void _handBack(FolderState state) {
    if (state.origin is! LocalEdit) return;
    final checkpoint = sync?.checkpointOf(state.path);
    if (state.isAbsent && checkpoint != null) {
      folder.replay(
        state.path,
        hash: checkpoint.hash,
        sizeBytes: checkpoint.size,
        mtimeMillis: checkpoint.mtime,
      );
    } else {
      folder.invalidate(state.path);
    }
  }

  /// Ingest one path's current on-disk state (watcher flush, in-app save).
  /// Missing file ⇒ delete. No-op when nothing changed since the folder last
  /// looked — or when the vault is paused (a paused vault neither ingests nor
  /// pushes; resume runs a reconcile to catch up).
  Future<void> ingestPath(String path, {bool seed = false}) {
    if (paused) return Future.value();
    return _serialized(() {
      _refreshIgnoreRules();
      return _ingestPath(path, seed: seed);
    });
  }

  Future<void> _ingestPath(String path, {bool seed = false}) async {
    if (folder.excludes(path)) return;
    final state = await folder.stateOf(path);
    sync?.syncRules(); // the path may itself have been a rule file
    history?.syncRules();
    if (state == null) return;
    await _apply(state, seed: seed);
  }

  // ---------------------------------------------------------------------------
  // Sync's serialized entry points (materialization, conflicts)
  // ---------------------------------------------------------------------------

  /// Materialize every replica winner that differs from the checkpoint.
  Future<void> materializeAll() => _serialized(() {
        _refreshIgnoreRules();
        return _requireSync.materializeAll();
      });

  /// Bring one document's winning revision to disk.
  @override
  Future<void> materializeChange(String docId) => _serialized(() {
        _refreshIgnoreRules();
        return _requireSync.materializeChange(docId);
      });

  /// Rescue a conflict (RV9); see [SyncModule.rescueConflict].
  @override
  Future<void> rescueConflict(ConflictReport report) => _serialized(() {
        _refreshIgnoreRules();
        return _requireSync.rescueConflict(report);
      });

  /// A losing binary of a conflict, from sync: history keeps it when there
  /// is a history module; otherwise there is nowhere for it to go — a vault
  /// with sync only creates no `.hist/` (R1).
  @override
  Future<void> rescueBinaryLoser(String path, List<int> bytes) async {
    final h = history;
    if (h == null) return;
    await _module(HistoryModule.name, () => h.rescueBinaryLoser(path, bytes));
  }
}

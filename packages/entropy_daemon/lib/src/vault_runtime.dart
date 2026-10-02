import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import 'config.dart';
import 'vault_shell.dart';

/// Builds the filesystem event stream for a vault root. The production
/// factory wraps `package:watcher`'s [DirectoryWatcher]; tests inject a
/// controllable stream (or drive [VaultRuntime.flushPath] directly).
typedef VaultWatchFactory = Stream<WatchEvent> Function(String vaultRoot);

/// The production watch factory: a [DirectoryWatcher] over the vault root.
Stream<WatchEvent> directoryWatchFactory(String vaultRoot) =>
    DirectoryWatcher(vaultRoot).events;

/// One vault's **continuous-mode runtime** (`vault_daemon` R10, RV4):
/// the shell plus everything that drives it while the daemon serves the vault
/// — the filesystem watcher subscription with its per-path debounce, and the
/// periodic full-rescan timer. Owned by the [Daemon]: created when a vault
/// starts continuous mode and disposed when the vault stops or is
/// re-registered, so an edited vault never leaves a stale watcher or rescan
/// timer driving a stopped shell.
class VaultRuntime {
  VaultRuntime({
    required this.shell,
    VaultWatchFactory? watch,
  }) : _watch = watch;

  final VaultShell shell;
  final VaultWatchFactory? _watch;

  VaultProfile get profile => shell.profile;

  final Map<String, Timer> _debounces = {};
  StreamSubscription<WatchEvent>? _watchSub;
  Timer? _rescan;
  bool _disposed = false;

  /// Bring the vault up: the engine's longpoll loop (via [VaultShell.start]),
  /// the watcher with a per-path debounce (RV4), and the periodic
  /// full-reconcile backstop. Every fire-and-forget callback routes through
  /// the shell's guarded entry points — a watcher or timer error records
  /// `lastError` instead of escaping as an unhandled async error.
  Future<void> start() async {
    await shell.start();
    final watch = _watch;
    if (watch != null) {
      _watchSub =
          watch(profile.vaultRoot).listen(_onEvent, onError: (Object _) {
        // Watcher hiccups are covered by the periodic rescan.
      });
    }
    _rescan = Timer.periodic(
      Duration(seconds: profile.rescanSeconds),
      (_) => unawaited(shell.reconcileGuarded()),
    );
  }

  void _onEvent(WatchEvent event) {
    if (_disposed) return;
    final rel = p.posix.joinAll(
      p.split(p.relative(event.path, from: profile.vaultRoot)),
    );
    if (rel.startsWith('..')) return;
    if (shell.excludes(rel)) return;
    // The raw event belongs to the folder service, which owns the folder and
    // folds events into settled states (`vault_folder` R4). The debounce
    // below only decides *when* to ask it for the settled result — the
    // service is what knows whether anything actually changed.
    shell.folder.event(rel);
    _debounces[rel]?.cancel();
    _debounces[rel] = Timer(
      Duration(milliseconds: profile.watchDebounceMillis),
      () {
        _debounces.remove(rel);
        unawaited(flushPath(rel));
      },
    );
  }

  /// The watcher's debounce flush: ingest the path and push. Guarded — an
  /// error records `lastError` instead of crashing the daemon — and gated by
  /// pause: a paused vault neither ingests nor pushes; the resume reconcile
  /// catches up. Tests drive this seam directly in place of a real watcher.
  Future<void> flushPath(String rel) => shell.guarded(() async {
        if (shell.paused || _disposed) return;
        await shell.ingestPath(rel);
        await shell.engine.syncNow();
      });

  /// Tear the runtime down: watcher, debounces, rescan timer, then the shell
  /// (longpoll abort + history flush). Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _rescan?.cancel();
    _rescan = null;
    for (final timer in _debounces.values) {
      timer.cancel();
    }
    _debounces.clear();
    await _watchSub?.cancel();
    _watchSub = null;
    await shell.stop();
  }
}

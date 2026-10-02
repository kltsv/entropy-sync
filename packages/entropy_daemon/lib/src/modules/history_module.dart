import 'dart:typed_data';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:path/path.dart' as p;

import '../folder/vault_folder.dart';
import '../hist_commit_queue.dart';
import '../os_integration.dart';

/// The **history** module of a vault (`daemon-modules` R1, R2; `vault_hist`
/// RV6): records this machine's edits to `.hist/` and nothing else. It
/// consumes the folder service's attributed states — commits `local` ones,
/// adopts `materialized` ones — and knows no other module: whatever sync
/// learns that history should act on (a state that was agreement with the
/// replica, a losing binary to rescue, a rename) reaches it through the
/// **host**, never directly. It runs with no sync present at all — history
/// over a plain folder, the local git-lite.
///
/// **When** an edit becomes a version is decided here, by the commit queue
/// (D7): `vault_hist` owns no timers.
class HistoryModule {
  HistoryModule({
    required this.folder,
    required this.writer,
    required this.queue,
    this.log,
    this.vaultId = '',
    String Function(List<int> bytes)? hasher,
  }) : _hash = hasher ?? sha256Hex {
    syncRules();
  }

  static const String name = 'history';

  final VaultFolder folder;
  final HistWriter writer;

  /// Decides **when** an edit becomes a version: `vault_hist` records what it
  /// is committed, and the coalescing and ordering around that are this
  /// host's job (`vault_daemon`, D7).
  final HistCommitQueue queue;

  final DaemonLog? log;
  final String vaultId;
  final String Function(List<int> bytes) _hash;

  /// `.histignore` only — paths that sync but are not history-*tracked*
  /// (effective hist exclusion = the folder's exclusions ∪ this, RV8). The
  /// files themselves — at any depth — are read by the folder service's
  /// engine (`vault_folder` — *Ignore files nest*); this module only compiles
  /// the sources it is handed, and rebuilds when the folder's rules version
  /// moves.
  late ExclusionMatcher _histExclusions;
  int _rulesSeen = -1;

  /// The files whose history has a divergent line (history-surface R16):
  /// **derived** from the graphs, never stored, and kept incrementally —
  /// every history write observed (this machine's commits, `.hist/` files
  /// arriving through sync) recounts the one path it belongs to; the
  /// reconcile pass recounts in full as the backstop (R18).
  final Set<String> _divergentPaths = {};

  /// How many files have a divergent line — a count of files, not of
  /// branches (R13).
  int get divergent => _divergentPaths.length;

  List<String> get divergentFiles => _divergentPaths.toList()..sort();

  void _logLine(String message) => log?.log('[$vaultId] $message');

  /// Pick up the folder's current rule generation: recompile the
  /// history-tracking exclusions when any rule file changed since this
  /// module last looked.
  void syncRules() {
    if (folder.rulesVersion == _rulesSeen) return;
    _rulesSeen = folder.rulesVersion;
    _histExclusions = ExclusionMatcher.fromSources(
      folder.ignoreSources(VaultFolder.histIgnoreFile),
    );
  }

  /// Whether history tracks this path (effective hist exclusion = the
  /// folder's exclusions ∪ `.histignore`, RV8): not excluded, not
  /// `.histignore`d, not inside `.hist/` (no history-of-history) — the
  /// writer applies its own extension and UTF-8 filters on top. Conflict
  /// rescue deliberately does NOT consult this: a losing binary is rescued
  /// regardless of `.histignore` (RV9 is data-safety, not tracking).
  bool tracks(String? path) {
    if (path == null) return false;
    if (folder.excludes(path)) return false;
    if (_histExclusions.excludes(path)) return false;
    return p.split(path).first != HistWriter.mirrorRoot;
  }

  /// Whether history would version this path's content — the one reason
  /// this module reads the bytes of a file the folder did not inline.
  bool _versions(String path) => tracks(path) && writer.tracks(path);

  // ---------------------------------------------------------------------------
  // The attributed stream (`vault_folder` R5)
  // ---------------------------------------------------------------------------

  /// A **local** state: an edit made on this machine — offered, and
  /// committed once the path is quiet (D7). With [adopt] it is a baseline
  /// instead: the first scan into an empty database, or content the host
  /// found already agreed with the replica — never a version.
  Future<void> onLocalState(FolderState state, {bool adopt = false}) async {
    final path = state.path;
    if (!tracks(path)) return;
    if (state.isAbsent) {
      queue.offer(path, null);
      return;
    }
    var bytes = state.content;
    if (bytes == null) {
      if (!_versions(path)) return; // a large binary: never versioned
      bytes = await folder.read(path);
    }
    if (adopt) {
      await queue.adopt(path, bytes);
    } else {
      queue.offer(path, bytes);
    }
  }

  /// A **materialized** state: written by a module on behalf of a revision
  /// somebody else authored. History **adopts** it — re-recording it would
  /// mint a second edge for one edit and attribute it to this device (RV6)
  /// — and adopting commits any local edit that raced the write first, from
  /// the base it was really made on (D7).
  Future<void> onMaterialized(FolderState state) async {
    if (!tracks(state.path)) return;
    await queue.adopt(state.path, state.content);
    await _recountPath(state.path);
  }

  /// A history file was written or arrived (`.hist/<path>/<file>`): recount
  /// the one path whose graph changed (R16, R18).
  Future<void> onHistoryFile(String histFilePath) async {
    final prefix = '${HistWriter.mirrorRoot}/';
    if (!histFilePath.startsWith(prefix)) return;
    final rel = histFilePath.substring(prefix.length);
    final slash = rel.lastIndexOf('/');
    if (slash <= 0) return;
    await _recountPath(rel.substring(0, slash));
  }

  /// A rename the host detected (`vault_hist` RV7): the marker pair — no
  /// folder ever moves. A raced local edit on the old path records
  /// **first**, from the base it was actually made on; otherwise the rename
  /// would find the edited content unrecorded, anchor it as a fresh root,
  /// and the edit would lose its edge (RV6, RV7).
  Future<void> onRename(String oldPath, FolderState newState) async {
    final newPath = newState.path;
    var bytes = newState.content;
    if (bytes == null && _versions(newPath)) bytes = await folder.read(newPath);
    if (bytes != null && tracks(oldPath) && tracks(newPath)) {
      await queue.flushPath(oldPath);
      await writer.recordRename(oldPath, newPath, bytes);
      // The markers supersede whatever raw delete/create the watcher queued,
      // and the new path's next edit diffs from the renamed content.
      queue.forget(oldPath);
      queue.forget(newPath);
      await queue.adopt(newPath, bytes);
    } else {
      if (tracks(oldPath)) queue.offer(oldPath, null);
      if (bytes != null && tracks(newPath)) queue.offer(newPath, bytes);
    }
  }

  /// A losing **binary** of a sync conflict, handed over by the host: copied
  /// whole into history as a `conflict` file, otherwise it would be gone
  /// forever (RV9). Bypasses `.histignore` — data-safety, not tracking.
  Future<void> rescueBinaryLoser(String path, List<int> bytes) =>
      writer.recordBinaryConflictLoser(path, bytes);

  /// Commit every path quiet for the idle window; recount what was written.
  Future<void> flushIdle() async {
    for (final path in await queue.flushIdle()) {
      await _recountPath(path);
    }
  }

  /// Commit everything pending (shutdown).
  Future<void> flushAll() => queue.flushAll();

  // ---------------------------------------------------------------------------
  // Noticing a divergence (history-surface R16–R18)
  // ---------------------------------------------------------------------------

  Future<void> _recountPath(String path) async {
    if (!tracks(path)) {
      _divergentPaths.remove(path);
      return;
    }
    final reader = HistReader(writer.store);
    if (await hasDivergentLine(reader, path, liveHash: _liveHashOf(path))) {
      _divergentPaths.add(path);
    } else {
      _divergentPaths.remove(path);
    }
  }

  /// The full recount — the periodic pass's backstop for anything an
  /// incremental recount missed.
  Future<void> recountAll() async {
    final reader = HistReader(writer.store);
    final paths = (await writer.store.listPaths()).where(tracks);
    final found = await divergentPaths(reader, paths,
        liveHashOf: (path) async => _liveHashOf(path));
    _divergentPaths
      ..clear()
      ..addAll(found);
  }

  /// The live content's hash: what the folder last saw, else the file
  /// itself; null when absent.
  String? _liveHashOf(String path) {
    final seen = folder.cursor.seen(path);
    if (seen != null) return seen.hash;
    final file = folder.fileOf(path);
    if (!file.existsSync()) return null;
    return _hash(Uint8List.fromList(file.readAsBytesSync()));
  }

  /// Note for the log — the host attributes failures to this module (R3).
  void logError(Object error) => _logLine('[$name] error: $error');
}

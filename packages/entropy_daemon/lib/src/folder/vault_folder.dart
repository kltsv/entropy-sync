import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:entropy_hist/entropy_hist.dart'
    show
        ExclusionMatcher,
        IgnoreFileTree,
        IgnoreSource,
        histIgnoreFileName,
        syncIgnoreFileName;
import 'package:path/path.dart' as p;

import '../os_integration.dart';
import 'folder_cursor.dart';

/// Who produced a settled state (`vault_folder` R5).
///
/// This is the whole interface between modules: one acts on `local` and
/// ignores `materialized`, another does the reverse, and **neither names the
/// other**. Adding a third module later is one more subscriber.
sealed class StateOrigin {
  const StateOrigin();
}

/// Something other than this service changed the file — an editor, a script,
/// the owner.
class LocalEdit extends StateOrigin {
  const LocalEdit();
}

/// A module asked the service to write this content, and it did.
///
/// [by] names the requester so a module can recognise its **own** writes; it
/// is deliberately not how modules find each other.
class Materialized extends StateOrigin {
  const Materialized(this.by);

  final String by;
}

/// One settled state of one path: what it now is, and where it came from.
class FolderState {
  const FolderState({
    required this.path,
    required this.content,
    required this.hash,
    required this.origin,
    this.sizeBytes = 0,
    this.mtimeMillis = 0,
    this.previousHash,
  });

  /// Vault-relative path, `/`-separated.
  final String path;

  /// What the service had for this path before this state — null when it
  /// had nothing (a new file). An absent state therefore names the hash
  /// that was there, and a present one says whether it is new or changed:
  /// a consumer can pair a rename (one path gone, another appeared with the
  /// same content) without a record of its own (R6).
  final String? previousHash;

  bool get isNew => previousHash == null;

  /// The bytes — `null` when the path is now absent, and also when the file
  /// is larger than the service inlines ([VaultFolder.inlineLimitBytes]): a
  /// module that needs those bytes reads or streams them from the service
  /// rather than having them pushed through memory. [isAbsent] tells the two
  /// cases apart.
  final Uint8List? content;

  /// sha256 of the file's content, or null when absent. Computed **once**
  /// here and shared by every subscriber — modules never re-hash what the
  /// service has already hashed. Present even when [content] is not.
  final String? hash;

  /// Size and modification time as recorded, so a module needs no stat of
  /// its own (0 when absent).
  final int sizeBytes;
  final int mtimeMillis;

  final StateOrigin origin;

  /// Whether the path is now gone. Absence is the missing **hash**: content
  /// is also null for a file too large to inline.
  bool get isAbsent => hash == null;
}

/// Everything one full rescan found (`vault_folder` R6).
///
/// A rescan is a batch, not a trickle: renames are pairs of states, so the
/// consumer must see the whole pass at once. Failures are reported rather
/// than thrown — one unreadable file must never cost the pass.
class FolderScan {
  const FolderScan({required this.states, required this.failures});

  /// Every path whose state differs from what the service last saw.
  final List<FolderState> states;

  /// Paths that could not be read this pass, with the error that stopped
  /// them. They are left out of the service's record, so the next scan
  /// retries them.
  final Map<String, Object> failures;
}

/// Raised when a request would leave the vault, or touch an excluded path.
class FolderRefused implements Exception {
  FolderRefused(this.message);

  final String message;

  @override
  String toString() => 'FolderRefused: $message';
}

/// The single owner of a vault folder (`vault_folder`).
///
/// It watches, folds raw editor events into **settled states**, hashes them,
/// performs **every** write, and publishes one attributed stream. Modules
/// subscribe; they never open a watcher and never write into the vault, which
/// is what keeps two capabilities from reading each other's writes as edits —
/// the same hazard that forbids two vaults sharing a folder.
class VaultFolder {
  VaultFolder({
    required this.root,
    required this.cursor,
    Iterable<String> exclusions = const [],
    Iterable<String> ignoreFiles = const [syncIgnoreFile, histIgnoreFile],
    String? exclusionIgnoreFile = syncIgnoreFile,
    Stream<String>? events,
    int Function()? clock,
    this.coalesceMillis = 1500,
    this.inlineLimitBytes = 1 << 20,
    TrashFn? trash,
    String? trashFallbackDir,
    String Function(List<int> bytes)? hasher,
  })  : _trashFallbackDir = trashFallbackDir ?? p.join(root, '.entropy-trash'),
        _configured = exclusions.toList(),
        _ignoreFiles = IgnoreFileTree(root, names: ignoreFiles),
        _exclusionIgnoreFile = exclusionIgnoreFile,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _trash = trash ?? moveToTrash,
        _hash = hasher ?? _sha256Hex {
    // The rule files already in the tree apply from the first pass — a
    // fresh replica materializes before it first walks, and an ignored
    // path must not be written even then.
    _ignoreFiles.discover();
    _ignoreFiles.refresh();
    _compileRules();
    if (events != null) _sub = events.listen(event);
  }

  /// The vault's own rule file for what the folder excludes
  /// (`vault_daemon` RV8), read at any depth.
  static const syncIgnoreFile = syncIgnoreFileName;

  /// The rule file a module consumes through the same engine — paths that
  /// sync but are not history-tracked. The service reads it; it does not
  /// act on it.
  static const histIgnoreFile = histIgnoreFileName;

  /// Exclusions **built in** to the folder, which no configuration can
  /// remove (`vault_folder` R7): `.hist-state/` is this machine's history
  /// working state — per-machine, disposable, never synced and never
  /// tracked — so a half-finished merge draft can never reach another
  /// device.
  static const builtInExclusions = ['.hist-state/'];
  static final _builtIn = ExclusionMatcher(builtInExclusions);

  /// Absolute path of the vault root. Nothing outside it is reachable.
  final String root;

  /// What the service last saw per path — **its own** record, so change
  /// detection works with one module enabled, both, or none (R6).
  final FolderCursor cursor;

  /// How long a path must be quiet before its state is settled (D7).
  final int coalesceMillis;

  /// Content up to this size rides inside the state; above it a state carries
  /// its hash and the bytes stay on disk, so one large file never has to be
  /// held whole in memory by the service or by any subscriber.
  final int inlineLimitBytes;

  /// The configured exclusion list (the vault's profile), root-anchored.
  List<String> _configured;

  /// Every ignore file in the tree, of every tracked name — offered by the
  /// walk, by events and by the service's own writes, re-read by stat.
  final IgnoreFileTree _ignoreFiles;

  /// Which of the tracked names is the folder's own exclusion file.
  final String? _exclusionIgnoreFile;

  /// configured ∪ the exclusion ignore files, compiled through one engine.
  late ExclusionMatcher _exclusions;

  /// Bumped whenever any tracked rule file changed — a module keying its own
  /// rules on one of them (`.histignore`) rebuilds when it sees a new value.
  int _rulesVersion = 0;
  final String _trashFallbackDir;
  final int Function() _clock;
  final TrashFn _trash;
  final String Function(List<int> bytes) _hash;
  StreamSubscription<String>? _sub;

  final _states = StreamController<FolderState>.broadcast();

  /// Every settled state, attributed. Broadcast: each module subscribes for
  /// itself, and a subscriber attaching later simply starts from now — the
  /// scan is how it obtains the folder's current truth.
  Stream<FolderState> get states => _states.stream;

  /// Paths seen but not yet settled, with the moment they were last touched.
  final Map<String, int> _pending = {};

  /// Writes this service performed but has not yet matched to an event, keyed
  /// by `path` and content hash. Attribution is **by content**, so a slow
  /// watcher, a coalesced burst or a restart can never turn a materialization
  /// into a phantom local edit (R5).
  final Map<String, String> _expected = {};

  // --- reading -------------------------------------------------------------

  /// The vault-relative form of an absolute path, or null when it escapes the
  /// root.
  String? relativeOf(String absolute) {
    final rel =
        p.relative(p.canonicalize(absolute), from: p.canonicalize(root));
    if (rel == '.' || rel.startsWith('..') || p.isAbsolute(rel)) return null;
    return rel.replaceAll(Platform.pathSeparator, '/');
  }

  File fileOf(String path) => File(p.join(root, path));

  /// Whether [path] is excluded — by the built-in rules, the configured
  /// list, or any applicable ignore file (R7).
  bool excludes(String path) =>
      _builtIn.excludes(path) || _exclusions.excludes(path);

  /// The current generation of the rule files; see [ignoreSources].
  int get rulesVersion => _rulesVersion;

  /// The anchored sources of every known ignore file named [name] — how a
  /// module reads its own rule file (`.histignore`) through the folder's
  /// engine without walking the tree itself.
  List<IgnoreSource> ignoreSources(String name) => _ignoreFiles.sources(name);

  /// Re-read the ignore files the service knows about (a stat each; content
  /// only when one changed) and recompile the rules if any did. Runs at the
  /// start of every pass, so an edited or newly arrived rule file applies on
  /// the next pass. Returns whether the rules changed.
  bool refreshRules() {
    if (!_ignoreFiles.refresh()) return false;
    _compileRules();
    _dropExcluded();
    return true;
  }

  void _compileRules() {
    final exclusionFile = _exclusionIgnoreFile;
    _exclusions = ExclusionMatcher.fromSources([
      IgnoreSource('', _configured),
      if (exclusionFile != null) ..._ignoreFiles.sources(exclusionFile),
    ]);
    _rulesVersion++;
  }

  /// A path that **became** excluded leaves the record: it is invisible from
  /// now on, and un-excluding it later must re-admit it as new rather than
  /// as unchanged (R7).
  void _dropExcluded() {
    for (final path in cursor.paths.toList()) {
      if (excludes(path)) cursor.forget(path);
    }
    _pending.removeWhere((path, _) => excludes(path));
  }

  /// The bytes at [path] — how a module obtains the content of a state the
  /// service did not inline.
  Future<Uint8List> read(String path) => fileOf(path).readAsBytes();

  /// Every tracked path currently on disk, with its hash — the folder's truth
  /// on demand, so a module attaching later never walks the tree itself.
  Future<Map<String, String>> scan() async {
    final out = <String, String>{};
    for (final entry in _walk().entries) {
      out[entry.key] = await _hashOf(entry.value);
    }
    return out;
  }

  /// One full pass over the folder: everything that changed since the service
  /// last looked, in one batch (R6).
  ///
  /// The fast path is size + mtime; content is hashed only when they differ.
  /// This is the startup scan and the periodic rescan both — the reason a
  /// module can be enabled later and still see a correct picture with no
  /// special catch-up mode. A failed *listing* throws (a partial one would
  /// read as mass deletion); a failed *file* is reported and skipped.
  Future<FolderScan> rescan() async {
    final onDisk = _walk();
    // A full pass settles the whole tree: whatever the watcher had queued is
    // covered by what follows.
    _pending.clear();

    final states = <FolderState>[];
    final failures = <String, Object>{};

    // Gone: in our record, no longer on disk.
    for (final path in cursor.paths.toList()) {
      if (onDisk.containsKey(path)) continue;
      final state = await _settleOne(path);
      if (state != null) states.add(state);
    }
    for (final entry in onDisk.entries) {
      if (cursor.unchangedByStat(entry.key, entry.value)) continue;
      try {
        final state = await _settleOne(entry.key);
        if (state != null) states.add(state);
      } catch (e) {
        // One unreadable file (permissions, vanished mid-scan, a poisoned
        // read) is skipped, not fatal: it stays out of our record, so the
        // next pass tries it again.
        failures[entry.key] = e;
      }
    }
    // Anything we wrote is now reflected in the record; unmatched
    // expectations are stale.
    _expected.clear();
    return FolderScan(states: states, failures: failures);
  }

  /// The settled state of one path right now, whatever the watcher has seen
  /// — the folder's truth for a single path, and the seam a module uses to
  /// ask "did this change under me?". Any pending event for the path is
  /// consumed. Null when nothing changed since the service last looked.
  Future<FolderState?> stateOf(String path) async {
    _pending.remove(path);
    // A rule file the watcher just reported is known from here on; reading
    // it is the refresh every pass begins with.
    _ignoreFiles.offer(path);
    refreshRules();
    if (excludes(path)) return null;
    return _settleOne(path);
  }

  // --- writing (the only writer) -------------------------------------------

  /// Write [bytes] at [path] on behalf of [by], atomically.
  ///
  /// The state is emitted **after** the bytes are on disk, so a subscriber
  /// seeing a materialization can rely on the file being there. [hash] is the
  /// caller's own digest of [bytes] when it already has one — the service
  /// hashes only what nobody has hashed yet.
  Future<FolderState> materialize(
    String path,
    List<int> bytes, {
    required String by,
    int? mtimeMillis,
    String? hash,
  }) async {
    _guard(path);
    final content = Uint8List.fromList(bytes);
    final digest = hash ?? _hash(content);
    _expected[path] = digest;

    final file = fileOf(path);
    file.parent.createSync(recursive: true);
    // Temp-and-rename so a reader never observes a half-written file.
    final temp = File('${file.path}$_tempSuffix');
    temp.writeAsBytesSync(content, flush: true);
    temp.renameSync(file.path);
    if (mtimeMillis != null) {
      file.setLastModifiedSync(
        DateTime.fromMillisecondsSinceEpoch(mtimeMillis),
      );
    }
    final before = cursor.seen(path)?.hash;
    final seen = cursor.record(path, file, digest);
    // A rule file that arrived through a module is known from now on and
    // applies on the next pass, exactly as the root file does.
    _ignoreFiles.offer(path);

    return _emit(FolderState(
      path: path,
      content: content,
      hash: digest,
      sizeBytes: seen.sizeBytes,
      mtimeMillis: seen.mtimeMillis,
      origin: Materialized(by),
      previousHash: before,
    ));
  }

  /// Remove [path] on behalf of [by] — to the **system trash**, never
  /// destroyed: a wrongly propagated deletion must always be recoverable.
  ///
  /// The directory that held it is left in place; removing one another device
  /// may be about to fill is not this service's call.
  Future<FolderState> remove(String path, {required String by}) async {
    _guard(path);
    _expected[path] = _absentHash;
    final file = fileOf(path);
    if (file.existsSync()) {
      await _trash(file, fallbackDir: _trashFallbackDir);
    }
    final before = cursor.seen(path)?.hash;
    cursor.forget(path);
    return _emit(FolderState(
      path: path,
      content: null,
      hash: null,
      origin: Materialized(by),
      previousHash: before,
    ));
  }

  void _guard(String path) {
    if (path.isEmpty || p.isAbsolute(path) || path.split('/').contains('..')) {
      throw FolderRefused('"$path" escapes the vault root');
    }
    if (excludes(path)) {
      throw FolderRefused('"$path" is excluded from this vault');
    }
  }

  // --- the record ----------------------------------------------------------

  /// Forget what we last saw at [path], so the next scan reports it as new —
  /// how a subscriber that could not apply a state asks to be shown it again.
  void invalidate(String path) => cursor.forget(path);

  /// Put back what was last seen at [path]. The counterpart of [invalidate]
  /// for a state the subscriber failed to apply after the file was already
  /// gone: absence is the *missing* record, so replaying it means restoring
  /// what preceded it.
  void replay(
    String path, {
    required String hash,
    required int sizeBytes,
    required int mtimeMillis,
  }) =>
      cursor.seed({
        path: FolderSeen(
          hash: hash,
          sizeBytes: sizeBytes,
          mtimeMillis: mtimeMillis,
        ),
      });

  /// The vault's configured exclusion list changed (R7). The ignore files are
  /// the service's own to re-read; this is the other source. A path that
  /// **became** excluded leaves the record either way.
  void applyExclusions(Iterable<String> patterns) {
    _configured = patterns.toList();
    _compileRules();
    _dropExcluded();
  }

  // --- watching and coalescing ---------------------------------------------

  /// A raw filesystem event. Not a state: editors save by writing a temporary
  /// file and renaming, or by deleting and recreating, so events are folded
  /// per path and only the final one is emitted once the path goes quiet (D7).
  void event(String path) {
    if (excludes(path)) return;
    _ignoreFiles.offer(path);
    _pending[path] = _clock();
  }

  /// Emit every path quiet for [coalesceMillis]; returns what was emitted.
  Future<List<FolderState>> settle() async {
    refreshRules();
    final now = _clock();
    final out = <FolderState>[];
    for (final path in _pending.keys.toList()) {
      if (now - _pending[path]! < coalesceMillis) continue;
      _pending.remove(path);
      final state = await _settleOne(path);
      if (state != null) out.add(state);
    }
    return out;
  }

  /// Settle one path immediately, whatever its quiet time — used to emit a
  /// pending local edit **before** a write lands on the same path, so a
  /// module records it from the state it was really made on.
  Future<FolderState?> settleNow(String path) async {
    refreshRules();
    if (!_pending.containsKey(path)) return null;
    _pending.remove(path);
    return _settleOne(path);
  }

  Future<FolderState?> _settleOne(String path) async {
    final file = fileOf(path);
    if (!file.existsSync()) {
      // Our own removal, recognised the same way a write is.
      if (_expected[path] == _absentHash) {
        _expected.remove(path);
        return null;
      }
      if (cursor.matches(path, null)) return null;
      final before = cursor.seen(path)?.hash;
      cursor.forget(path);
      return _emit(FolderState(
        path: path,
        content: null,
        hash: null,
        origin: const LocalEdit(),
        previousHash: before,
      ));
    }

    final stat = file.statSync();
    final inline = stat.size <= inlineLimitBytes;
    // Above the inline limit the digest comes from a stream: the service
    // never holds one large file whole, and neither does a subscriber.
    final content = inline ? await file.readAsBytes() : null;
    final hash =
        inline ? _hash(content!) : await _hashOfStream(file.openRead());

    // Our own write, recognised by content — never a phantom local edit.
    if (_expected[path] == hash) {
      _expected.remove(path);
      return null; // already emitted when it was written
    }

    // Nothing changed since we last looked.
    if (cursor.matches(path, hash)) {
      // Same bytes, new stat (a touch, a byte-identical re-save): repair the
      // fast path so the next scan skips the file without hashing it again.
      if (!cursor.unchangedByStat(path, file)) cursor.record(path, file, hash);
      return null;
    }

    final before = cursor.seen(path)?.hash;
    final seen = cursor.record(path, file, hash);
    return _emit(FolderState(
      path: path,
      content: content,
      hash: hash,
      sizeBytes: seen.sizeBytes,
      mtimeMillis: seen.mtimeMillis,
      origin: const LocalEdit(),
      previousHash: before,
    ));
  }

  FolderState _emit(FolderState state) {
    if (!_states.isClosed) _states.add(state);
    return state;
  }

  Future<void> close() async {
    await _sub?.cancel();
    await _states.close();
  }

  /// Every file in the vault, vault-relative — excluded paths and the
  /// service's own half-written temporaries left out.
  ///
  /// The walk is also how nested ignore files are **discovered**: every rule
  /// file it passes is offered to the tree and read before the listing is
  /// filtered, so a file that appeared in a new directory applies to this
  /// very pass (`vault_folder` — *Ignore files nest*).
  Map<String, File> _walk() {
    final dir = Directory(root);
    final all = <String, File>{};
    if (!dir.existsSync()) return all;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.posix.joinAll(p.split(p.relative(entity.path, from: root)));
      if (rel.startsWith('..')) continue;
      if (_isTemp(rel)) continue;
      _ignoreFiles.offer(rel);
      all[rel] = entity;
    }
    refreshRules();
    all.removeWhere((rel, _) => excludes(rel));
    return all;
  }

  Future<String> _hashOf(File file) async {
    if (file.statSync().size <= inlineLimitBytes) {
      return _hash(await file.readAsBytes());
    }
    return _hashOfStream(file.openRead());
  }

  /// Constant-memory sha256 of a byte stream — deliberately **not** routed
  /// through the injected whole-bytes hasher, which exists for content the
  /// service actually holds.
  Future<String> _hashOfStream(Stream<List<int>> source) async {
    final catcher = _DigestCatcher();
    final input = c.sha256.startChunkedConversion(catcher);
    await for (final chunk in source) {
      input.add(chunk);
    }
    input.close();
    return catcher.digest!.toString();
  }

  static bool _isTemp(String rel) =>
      rel.endsWith(_tempSuffix) || rel.endsWith('.entropy-sync.tmp');

  static String _sha256Hex(List<int> bytes) =>
      c.sha256.convert(bytes).toString();

  /// The suffix of a materialization in flight, never a vault file.
  static const _tempSuffix = '.entropy-tmp';

  /// Stands in for "no content" when matching a write to its event.
  static const _absentHash = '-';
}

class _DigestCatcher implements Sink<c.Digest> {
  c.Digest? digest;

  @override
  void add(c.Digest data) => digest = data;

  @override
  void close() {}
}

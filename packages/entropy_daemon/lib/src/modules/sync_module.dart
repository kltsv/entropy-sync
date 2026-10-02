import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:entropy_sync/entropy_sync.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../folder/vault_folder.dart';
import '../last_synced.dart';
import '../os_integration.dart';

/// What the sync module needs from its host (`daemon-modules` R2): every
/// arrow that would otherwise point at another module points here instead.
/// The host routes a state through itself (so a racing local edit or a
/// materialization reaches every module), relays a losing binary to
/// whichever module rescues it, and serializes the passes the engine's
/// streams trigger.
abstract interface class SyncHost {
  bool get paused;

  /// Route one settled state through the host — the racing local edit sync
  /// found before a write, or the materialization it just performed.
  Future<void> apply(FolderState state);

  /// A losing binary of a conflict, for whichever module keeps such things.
  Future<void> rescueBinaryLoser(String path, List<int> bytes);

  /// The host's serialized entry points, for the engine's change and
  /// conflict streams.
  Future<void> materializeChange(String docId);
  Future<void> rescueConflict(ConflictReport report);

  /// Run [body] with errors captured, never escaping.
  Future<void> safely(Future<void> Function() body);
}

/// What ingesting a local state told the host (`daemon-modules` R5): the
/// state was an **edit** (pushed as a new revision), it was **agreement** —
/// content the replica's winner already holds, a re-attached vault or a lost
/// checkpoint — or it was **unchanged** since the checkpoint. History acts on
/// the distinction without knowing sync exists: an edit is offered, an
/// agreement is adopted.
enum IngestOutcome { edit, agreed, unchanged }

/// The **sync** module of a vault (`daemon-modules` R1, R2; `vault_daemon`
/// RV1, RV4, RV9): composes `vault_crypto` between the folder and the
/// document-opaque `vault_sync` replica — files are encrypted on the way
/// out, decrypted and materialized on the way in — and owns the replication
/// checkpoint. It knows the folder service and its host, never another
/// module.
class SyncModule {
  SyncModule({
    required this.profile,
    required this.folder,
    required this.store,
    required this.transport,
    required this.crypto,
    required this.engine,
    required this.replicaId,
    required String stateDir,
    DaemonLog? log,
    Notifier? notifier,
    int Function()? clock,
    String Function(List<int> bytes)? hasher,
  })  : _log = log,
        _notifier = notifier ?? osNotify,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _hash = hasher ?? _sha256Hex,
        lastSynced = LastSyncedIndex(p.join(stateDir, 'last-synced.json')) {
    rebuildIndex();
  }

  static const String name = 'sync';

  final VaultProfile profile;
  final VaultFolder folder;
  final LocalStore store;
  final CouchTransport transport;
  final VaultCrypto crypto;
  final SyncEngine engine;
  final String replicaId;

  final DaemonLog? _log;
  final Notifier _notifier;
  final int Function() _clock;
  final String Function(List<int> bytes) _hash;

  late SyncHost _host;

  /// Bind to the host that routes states and relays hand-offs. Done by the
  /// host itself when the module is attached.
  void bind(SyncHost host) => _host = host;

  /// The **replication checkpoint** (`vault_daemon` RV4): what this
  /// module last brought into agreement with the replica, and the revision
  /// that agreement corresponds to. Change detection is not its job — that
  /// belongs to the folder service's own record (`daemon-modules` R6).
  final LastSyncedIndex lastSynced;

  /// How the folder service attributes this module's writes (`vault_folder`
  /// R5). It names the requester so a module can recognise its own writes;
  /// no module keys behaviour on another module's name.
  static const _writer = 'sync';

  /// Wire ids known to decrypt to a currently-ignored path — a per-rules
  /// generation memo so already-known-ignored documents are not re-decrypted
  /// on every pass. Cleared whenever the rules change (un-ignoring must
  /// re-admit the path).
  final Set<String> _ignoredDocIds = {};
  int _rulesSeen = -1;

  /// Loser revisions already rescued (or deliberately skipped), so a replayed
  /// conflict event is a no-op: no duplicate rescue file, no repeated
  /// notification (`vault_daemon` RV9 — "once per conflict, not per
  /// replay"). A revision is marked only **after** its rescue succeeded, so a
  /// transient failure (missing blob, IO error) retries on the next pass
  /// instead of permanently dropping the loser.
  final Set<String> _rescuedLoserRevs = {};

  /// Wire id → vault path, rebuilt from the cursor (ids are one-way HMACs, so
  /// tombstones can only be mapped back through this index).
  final Map<String, String> _pathByDocId = {};

  /// The replication error surfaced in status: null after a successful sync,
  /// the engine's word otherwise (`unreachable: …` reads as offline).
  String? lastError;
  int lastSyncMillis = 0;

  /// The conflict list surfaced in status: rebuilt from the store's live
  /// conflicts on every reconcile (resolved conflicts drop off), with the
  /// most recent rescues appended as they happen.
  final List<String> conflictPaths = [];

  StreamSubscription<Change>? _changesSub;
  StreamSubscription<ConflictReport>? _conflictsSub;

  int get _now => _clock();
  int get unsynced => store.pendingPushCount;

  void _logLine(String message) => _log?.log('[${profile.vaultId}] $message');

  /// Pick up the folder's rule generation: the ignored-doc memo is per
  /// rules generation (un-ignoring must re-admit the path).
  void syncRules() {
    if (folder.rulesVersion == _rulesSeen) return;
    _rulesSeen = folder.rulesVersion;
    _ignoredDocIds.clear();
  }

  /// Rebuild the id→path index from the persisted cursor (constructor and
  /// startup).
  void rebuildIndex() {
    _pathByDocId.clear();
    for (final path in lastSynced.paths) {
      _pathByDocId[crypto.idFor(path)] = path;
    }
  }

  // ---------------------------------------------------------------------------
  // Continuous mode
  // ---------------------------------------------------------------------------

  /// Start continuous operation: the core engine's longpoll pull + debounced
  /// push, with remote winners materialized (and conflicts rescued) as they
  /// arrive — through the host's serialized entry points.
  Future<void> start() async {
    rebuildIndex();
    _changesSub = engine.changes.listen((change) {
      if (_host.paused || change.origin != ChangeOrigin.remote) return;
      unawaited(_host.safely(() => _host.materializeChange(change.id)));
    });
    _conflictsSub = engine.conflicts.listen((report) {
      if (_host.paused) return;
      unawaited(_host.safely(() => _host.rescueConflict(report)));
    });
    await engine.start();
  }

  Future<void> stop() async {
    await _changesSub?.cancel();
    await _conflictsSub?.cancel();
    await engine.stop();
  }

  // ---------------------------------------------------------------------------
  // The reconcile pass, piece by piece (the host orders them)
  // ---------------------------------------------------------------------------

  /// Never synced, not even `meta`.
  bool get freshReplica => store.allDocIds.isEmpty;

  /// Whether the replica holds no vault documents yet (`meta` rides along on
  /// the pull and does not count as content).
  bool get replicaHasNoContent => store.allDocIds.every((id) => id == 'meta');

  Future<void> syncNow() async {
    try {
      await engine.syncNow();
      lastError = null;
      lastSyncMillis = _now;
    } on SyncException catch (e) {
      lastError = '${e.kind.name}: ${e.message}';
    }
  }

  /// Rebuild the surfaced conflict list from the store's live conflicts, so
  /// resolved conflicts drop off instead of accumulating forever.
  void refreshConflictPaths() {
    final current = <String>[];
    for (final report in store.conflicts()) {
      final label = _pathByDocId[report.id] ?? report.id;
      if (!current.contains(label)) current.add(label);
    }
    conflictPaths
      ..clear()
      ..addAll(current);
  }

  /// Rescue every conflict the store currently reports.
  Future<void> rescueLiveConflicts() async {
    for (final report in store.conflicts()) {
      await _host.safely(() => rescueConflict(report));
    }
  }

  /// A checkpoint entry whose path BECAME excluded (an ignore-file edit, a
  /// profile change) is NOT a local deletion: drop it without tombstoning —
  /// exclusion is never mistaken for deletion (RV8 "effect and timing").
  /// The folder has already forgotten the path, so the scan is silent about
  /// the still-existing file; this is what keeps it from pushing a tombstone
  /// to every other device.
  void dropExcludedCheckpoints() {
    for (final path in lastSynced.paths.toList()) {
      if (!folder.excludes(path)) continue;
      lastSynced.remove(path);
      _pathByDocId.remove(crypto.idFor(path));
      _logLine('now ignored: $path (cursor dropped, not tombstoned)');
    }
  }

  /// The checkpoint's hash for [path] — what this module last agreed on.
  String? checkpointHashOf(String path) => lastSynced[path]?.hash;

  LastSyncedEntry? checkpointOf(String path) => lastSynced[path];

  // ---------------------------------------------------------------------------
  // Disk → store (ingestion)
  // ---------------------------------------------------------------------------

  /// Ingest one settled **local** state: encrypt it into the replica. Its
  /// hash, size and mtime were computed once by the folder service — nothing
  /// is re-read or re-hashed here. Returns what the state turned out to be,
  /// so the host can tell history whether to offer or adopt it.
  Future<IngestOutcome> ingestLocal(FolderState state) async {
    final path = state.path;
    final hash = state.hash!;
    final checkpoint = lastSynced[path];
    if (checkpoint?.hash == hash) {
      // Already in agreement with the replica: refresh the checkpoint, mint
      // nothing.
      _touchCursor(state, rev: checkpoint?.rev);
      return IngestOutcome.unchanged;
    }

    final docId = crypto.idFor(path);
    // A lost checkpoint must not mint spurious revisions: if the replica's
    // winner already holds identical content, just repair it.
    if (checkpoint == null && await _winnerMatches(docId, hash)) {
      _pathByDocId[docId] = path;
      _touchCursor(state, rev: store.get(docId)?.rev);
      return IngestOutcome.agreed;
    }

    // Above the folder's inline limit the content is encrypted straight from
    // disk in constant memory (`vault_crypto.encryptStreamed`).
    final bytes = state.content;
    final EncryptedDoc enc;
    if (bytes == null) {
      enc = await crypto.encryptStreamed(
        path: path,
        mtime: state.mtimeMillis,
        size: state.sizeBytes,
        openContent: () => folder.fileOf(path).openRead(),
      );
    } else {
      enc = await crypto.encrypt(LogicalDoc(
        path: path,
        bytes: bytes,
        mtime: state.mtimeMillis,
      ));
    }
    final rev = await store.put(
      enc.wire.id,
      enc.wire.body!,
      attachment: enc.attachment,
      parentRev: _ingestParentRev(docId, path),
    );
    _pathByDocId[docId] = path;
    _touchCursor(state, rev: rev);
    return IngestOutcome.edit;
  }

  /// The revision a local edit of [path] is parented on (`vault_sync` R3):
  ///
  /// - The checkpoint's recorded revision when it is still in the tree — an
  ///   edit based on stale disk content (a pull grafted a newer winner while
  ///   the edit raced) then becomes a **sibling branch**, a real conflict for
  ///   the conflict machinery, instead of silently fast-forwarding the freshly
  ///   grafted remote winner.
  /// - With no checkpoint and no replica document: `null` — a brand-new file
  ///   roots normally.
  /// - With no checkpoint but a live replica winner (re-attach to a populated
  ///   database, or a created-but-never-ingested file racing a pull): the
  ///   winner's parent when the tree holds one, so the local content and the
  ///   remote winner meet as a conflict; a generation-1 winner has nothing to
  ///   branch from and the edit parents on the winner itself.
  String? _ingestParentRev(String docId, String path) {
    final cursor = lastSynced[path];
    if (cursor != null) {
      final rev = cursor.rev;
      if (rev != null && store.hasRevision(docId, rev)) return rev;
      return null; // no revision recorded for the path — parent on the winner
    }
    final winner = store.get(docId);
    if (winner == null || winner.rev == null || winner.deleted) return null;
    final transferred = store.revisionedDoc(docId, winner.rev!);
    if (transferred == null || transferred.revisionIds.length < 2) return null;
    final parent =
        '${transferred.revisionsStart - 1}-${transferred.revisionIds[1]}';
    return store.hasRevision(docId, parent) ? parent : null;
  }

  /// A local deletion: tombstone the document — only when this module ever
  /// brought the path into agreement with the replica (a path it never
  /// synced has nothing to tombstone). Returns whether it did.
  Future<bool> ingestDelete(String path) async {
    if (lastSynced[path] == null) return false;
    final docId = crypto.idFor(path);
    await store.delete(docId);
    lastSynced.remove(path);
    _logLine('local delete: $path');
    return true;
  }

  /// A rename the host detected (`vault_daemon` RV7): on the wire it is
  /// what it always is — tombstone the old id, create the new one (the HMAC
  /// id is path-derived, so there is no "move").
  Future<void> applyRename(String oldPath, FolderState state) async {
    final newPath = state.path;
    await store.delete(crypto.idFor(oldPath));
    final bytes = state.content;
    final EncryptedDoc enc;
    if (bytes != null) {
      enc = await crypto.encrypt(
        LogicalDoc(path: newPath, bytes: bytes, mtime: state.mtimeMillis),
      );
    } else {
      enc = await crypto.encryptStreamed(
        path: newPath,
        mtime: state.mtimeMillis,
        size: state.sizeBytes,
        openContent: () => folder.fileOf(newPath).openRead(),
      );
    }
    final rev = await store.put(enc.wire.id, enc.wire.body!,
        attachment: enc.attachment);
    lastSynced.remove(oldPath);
    _pathByDocId[crypto.idFor(newPath)] = newPath;
    _touchCursor(state, rev: rev);
    _logLine('rename: $oldPath → $newPath');
  }

  // ---------------------------------------------------------------------------
  // Store → disk (materialization, RV4)
  // ---------------------------------------------------------------------------

  /// Materialize every replica winner that differs from the checkpoint (used
  /// by the reconcile pass; the continuous mode materializes per change
  /// event).
  Future<void> materializeAll() async {
    for (final id in store.allDocIds) {
      if (id == 'meta') continue;
      // One failing document must not abort the pass (or crash the daemon).
      await _host.safely(() => materializeChange(id));
    }
  }

  /// Bring one document's winning revision to disk.
  Future<void> materializeChange(String docId) async {
    if (docId == 'meta') return;
    // Known to decrypt to an ignored path under the current rules — skip
    // without re-decrypting (the memo clears when the rules change).
    if (_ignoredDocIds.contains(docId)) return;
    final doc = store.get(docId);
    if (doc == null) return;

    // Skip without decrypting when the checkpoint already records this exact
    // winner revision as materialized — a reconcile over an unchanged vault
    // decrypts nothing.
    final knownPath = _pathByDocId[docId];
    if (!doc.deleted &&
        knownPath != null &&
        lastSynced[knownPath]?.rev != null &&
        lastSynced[knownPath]!.rev == doc.rev) {
      return;
    }

    if (doc.deleted) {
      final path = knownPath;
      if (path == null) return; // never materialized here — nothing on disk
      if (folder.excludes(path)) {
        // Remote changes for an ignored path are not materialized (RV8) —
        // a remote deletion never trashes the local copy of an ignored file.
        _ignoredDocIds.add(docId);
        return;
      }
      // A file the module has no record of (created locally, never ingested)
      // or a local edit racing the delete is ingested first — never trashed;
      // the conflict machinery reconciles (`vault_daemon`
      // "local-edit-during-pull").
      final racing = await _racingLocalEdit(path);
      if (racing != null) {
        await _host.apply(racing);
        return;
      }
      final existed = folder.fileOf(path).existsSync();
      // The service removes to the system trash, never destroys: a wrongly
      // propagated deletion must always be recoverable by hand.
      final removed = await folder.remove(path, by: _writer);
      if (existed) _logLine('remote delete: $path → trash');
      lastSynced.remove(path);
      _pathByDocId.remove(docId);
      await _host.apply(removed);
      return;
    }

    final decrypted = await crypto.decryptBody(
      WireDoc(id: doc.id, body: doc.body, deleted: false),
    );
    final path = decrypted.header.path;
    if (folder.excludes(path)) {
      // A remote change for an ignored path stays grafted in the replica
      // (replication is document-level) but is never written to disk and
      // gains no checkpoint entry (RV8). Memoized so the next pass skips the
      // decrypt; un-ignoring clears the memo and the next pass re-admits it.
      _ignoredDocIds.add(docId);
      return;
    }
    _pathByDocId[docId] = path;

    // Local edit racing the pull: ingest it first; CouchDB reconciles (R9).
    final racing = await _racingLocalEdit(path);
    if (racing != null) {
      await _host.apply(racing);
      return;
    }

    final Uint8List bytes;
    if (decrypted.inlineContent != null) {
      bytes = decrypted.inlineContent!;
    } else {
      final att = doc.attachment;
      if (att == null) return; // malformed: header says attachment, none came
      final builder = BytesBuilder(copy: false);
      await for (final chunk in crypto
          .decryptStream(store.blobStore.openRead(att.digest), docId: doc.id)) {
        builder.add(chunk);
      }
      bytes = builder.takeBytes();
    }

    final hash = _sha256(bytes);
    if (lastSynced[path]?.hash == hash) {
      // Already on disk — no echo. Record the winner revision so the next
      // pass skips this document without decrypting.
      if (lastSynced[path]!.rev != doc.rev &&
          folder.fileOf(path).existsSync()) {
        _touchCursorOnDisk(path, hash, rev: doc.rev);
      }
      return;
    }

    // The decrypt suspended above — re-check the disk immediately before
    // writing, so a local save that landed during the await is ingested
    // instead of overwritten (TOCTOU).
    final landedDuringDecrypt = await _racingLocalEdit(path);
    if (landedDuringDecrypt != null) {
      await _host.apply(landedDuringDecrypt);
      return;
    }

    // The service performs the write — atomically, with the logical mtime —
    // and reports it back attributed to this module, which is what keeps it
    // from ever returning as a local edit (no echo loop).
    final written = await folder.materialize(
      path,
      bytes,
      by: _writer,
      mtimeMillis: decrypted.header.mtime,
      hash: hash,
    );
    _touchCursor(written, rev: doc.rev);
    await _host.apply(written);
  }

  /// The local edit racing an arrival on [path], if there is one.
  ///
  /// The folder settles the path — consuming whatever the watcher had pending
  /// for it, which is what makes the racing edit land **before** the write —
  /// and reports a state only when the disk differs from what it last saw. A
  /// file the service has no record of IS such a difference (a creation the
  /// watcher has not flushed yet): it is ingested, never overwritten. An
  /// absent path is not a racing edit; the arrival applies to it as usual.
  Future<FolderState?> _racingLocalEdit(String path) async {
    if (!folder.fileOf(path).existsSync()) return null;
    final state = await folder.stateOf(path);
    if (state == null || state.isAbsent) return null;
    return state;
  }

  // ---------------------------------------------------------------------------
  // Conflicts (RV9)
  // ---------------------------------------------------------------------------

  /// Rescue a conflict: the winner is already materialized (LWW, untouched);
  /// a losing text version was recorded by its author (nothing to do); a
  /// losing binary is handed to the host for whichever module keeps such
  /// things. Then resolve (idempotent), log, and notify the owner. No
  /// `*.conflict` files in the vault. A loser whose rescue fails transiently
  /// (missing blob, IO error) stays unmarked and unresolved, so the next
  /// pass retries instead of tombstoning bytes that were never saved.
  Future<void> rescueConflict(ConflictReport report) async {
    // A sync-excluded path does not participate at all (it cannot genuinely
    // conflict here — nothing local is ever pushed for it): leave the report
    // untouched for whichever device does serve the path. `.histignore` is a
    // different matter — rescue deliberately BYPASSES it (RV9 is
    // data-safety, not tracking).
    if (_ignoredDocIds.contains(report.id)) return;
    final knownPath = _pathByDocId[report.id];
    if (knownPath != null && folder.excludes(knownPath)) {
      _ignoredDocIds.add(report.id);
      return;
    }
    final loserRevs = [for (final loser in report.losers) loser.rev!];
    // A replayed conflict event must be a no-op beyond the (idempotent)
    // resolution: no duplicate rescue file, no duplicate log line, no
    // repeated notification (`vault_daemon` RV9 — "once per conflict,
    // not per replay").
    final fresh = [
      for (final loser in report.losers)
        if (!_rescuedLoserRevs.contains(_loserKey(report.id, loser.rev!)))
          loser,
    ];
    if (fresh.isEmpty) {
      await engine.resolve(report.id, loserRevs);
      return;
    }
    String? path;
    var rescuedAll = true;
    for (final loser in fresh) {
      final key = _loserKey(report.id, loser.rev!);
      if (loser.deleted || loser.body == null) {
        _rescuedLoserRevs.add(key);
        continue;
      }
      try {
        final decrypted = await crypto.decryptBody(
          WireDoc(id: loser.id, body: loser.body, deleted: false),
        );
        path = decrypted.header.path;
        if (folder.excludes(path)) {
          _ignoredDocIds.add(report.id);
          return; // ignored path — not this device's conflict to handle
        }
        Uint8List? bytes;
        if (decrypted.inlineContent != null) {
          bytes = decrypted.inlineContent!;
        } else if (loser.attachment != null) {
          final builder = BytesBuilder(copy: false);
          await for (final chunk in crypto.decryptStream(
              store.blobStore.openRead(loser.attachment!.digest),
              docId: loser.id)) {
            builder.add(chunk);
          }
          bytes = builder.takeBytes();
        }
        if (bytes != null && !_isTextContent(bytes)) {
          await _host.rescueBinaryLoser(path, bytes);
        }
        // Text losers: already in history via their author (RV6) — nothing.
        _rescuedLoserRevs.add(key); // only after the rescue truly succeeded
      } on VaultCryptoException {
        // An undecryptable loser can never be rescued — a deliberate skip
        // (not a transient failure); resolution still proceeds.
        _rescuedLoserRevs.add(key);
      } catch (e) {
        // Transient failure (blob missing, disk error): leave the loser
        // unmarked and hold the resolution — resolving now would tombstone
        // bytes that were never rescued. The next pass retries.
        rescuedAll = false;
        lastError = 'conflict rescue failed: $e';
        _logLine('conflict rescue failed on ${report.id} ${loser.rev}: $e');
      }
    }
    if (!rescuedAll) return;
    await engine.resolve(report.id, loserRevs);
    final label = path ?? _pathByDocId[report.id] ?? report.id;
    if (!conflictPaths.contains(label)) conflictPaths.add(label);
    _logLine('conflict resolved on $label '
        '(winner ${report.winnerRev}, losers ${loserRevs.join(", ")})');
    await _notifier('entropy-sync',
        'Conflict on $label — previous version kept in history');
  }

  String _loserKey(String id, String rev) => '$id $rev';

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<bool> _winnerMatches(String docId, String diskHash) async {
    final doc = store.get(docId);
    if (doc == null || doc.deleted || doc.body == null) return false;
    try {
      final decrypted = await crypto.decryptBody(
        WireDoc(id: docId, body: doc.body, deleted: false),
      );
      if (decrypted.inlineContent != null) {
        return _sha256(decrypted.inlineContent!) == diskHash;
      }
      final att = doc.attachment;
      if (att == null) return false;
      return await _sha256OfStream(crypto.decryptStream(
              store.blobStore.openRead(att.digest),
              docId: docId)) ==
          diskHash;
    } on VaultCryptoException {
      return false;
    }
  }

  bool _isTextContent(List<int> bytes) {
    if (bytes.contains(0)) return false;
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Record the agreement a settled state represents. Size and mtime are the
  /// folder service's, so both records describe the same observation of the
  /// same file.
  void _touchCursor(FolderState state, {String? rev}) {
    lastSynced.set(
      state.path,
      LastSyncedEntry(
        hash: state.hash!,
        mtime: state.mtimeMillis,
        size: state.sizeBytes,
        rev: rev,
      ),
    );
  }

  /// The same, for content that was already on disk when the winner arrived
  /// (nothing was written, so there is no state to record from).
  void _touchCursorOnDisk(String path, String hash, {String? rev}) {
    final stat = folder.fileOf(path).statSync();
    lastSynced.set(
      path,
      LastSyncedEntry(
        hash: hash,
        mtime: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
        rev: rev,
      ),
    );
  }

  /// Hashing of **decrypted replica content** — what came off the wire, not
  /// what is in the folder (the service hashes that, once). Routed through
  /// the injectable hasher, so tests can observe exactly when content is
  /// hashed (`vault_daemon` "unchanged files are skipped by the
  /// mtime+size fast path").
  String _sha256(List<int> bytes) => _hash(bytes);

  /// Constant-memory sha256 of a byte stream — the large-content counterpart
  /// of [_sha256], for a winner that rides as an attachment.
  Future<String> _sha256OfStream(Stream<List<int>> source) async {
    final catcher = _DigestCatcher();
    final input = c.sha256.startChunkedConversion(catcher);
    await for (final chunk in source) {
      input.add(chunk);
    }
    input.close();
    return catcher.digest!.toString();
  }

  static String _sha256Hex(List<int> bytes) =>
      c.sha256.convert(bytes).toString();
}

class _DigestCatcher implements Sink<c.Digest> {
  c.Digest? digest;

  @override
  void add(c.Digest data) => digest = data;

  @override
  void close() {}
}

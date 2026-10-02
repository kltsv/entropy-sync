import 'dart:convert';
import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:entropy_sync/entropy_sync.dart';
import 'package:path/path.dart' as p;

import 'dart:async';

import 'config.dart';
import 'control_protocol.dart';
import 'device_id.dart';
import 'folder/folder_cursor.dart';
import 'folder/vault_folder.dart';
import 'hist_commit_queue.dart';
import 'modules/history_module.dart';
import 'modules/sync_module.dart';
import 'os_integration.dart';
import 'secret_store.dart';
import 'vault_registry.dart';
import 'vault_runtime.dart';
import 'vault_shell.dart';

/// Raised when a vault would target the same CouchDB (endpoint, database) as one
/// the daemon already serves — two vaults must not share one database
/// (`vault_daemon` R23, isolation).
class VaultTargetConflict implements Exception {
  VaultTargetConflict({
    required this.vaultId,
    required this.conflictsWith,
    required this.endpoint,
    required this.database,
  });

  final String vaultId;
  final String conflictsWith;
  final String endpoint;
  final String database;

  @override
  String toString() =>
      'VaultTargetConflict: vault "$vaultId" targets the same database '
      '($endpoint / $database) as already-served vault "$conflictsWith"; '
      'two vaults must not share one CouchDB database.';
}

/// Raised when a vault's folder is the same directory as an already-served
/// vault's — or nested either way. Two shells over one directory read each
/// other's materializations as local edits and mint revisions forever; nesting
/// makes the outer vault swallow the inner one (`vault_daemon` R23,
/// isolation).
class VaultFolderConflict implements Exception {
  VaultFolderConflict({
    required this.vaultId,
    required this.conflictsWith,
    required this.vaultRoot,
    required this.otherRoot,
  });

  final String vaultId;
  final String conflictsWith;
  final String vaultRoot;
  final String otherRoot;

  @override
  String toString() =>
      'VaultFolderConflict: vault "$vaultId" ($vaultRoot) overlaps the folder '
      'of already-served vault "$conflictsWith" ($otherRoot); two vaults must '
      'not share or nest folders.';
}

/// One served vault: its shell when healthy, or the error that kept it from
/// starting (bad passphrase, unreachable hub with no cached `meta`). A failed
/// vault is still *registered* — it surfaces its error in status and is
/// retried on the next daemon start (`vault_daemon` RV3).
class VaultEntry {
  VaultEntry({required this.profile, this.shell, this.error});

  /// Replaced in place by a configuration change (`daemon-modules` R9).
  VaultProfile profile;
  final VaultShell? shell;
  String? error;
}

/// A configuration change the daemon cannot apply — an unknown vault, or
/// one that would enable sync with no connection to enable it on.
class ConfigError implements Exception {
  ConfigError(this.message, {this.unknownVault = false});

  final String message;
  final bool unknownVault;

  @override
  String toString() => message;
}

/// The single authoritative daemon service (`vault_daemon` R20). It serves
/// multiple vaults concurrently, each isolated behind its own [VaultShell], and
/// is the single source of truth for their status. Front-ends drive it through
/// the control server; it also runs and syncs with no front-end attached.
class Daemon {
  Daemon({
    required this.version,
    required this.shellFactory,
    this.registry,
    this.secrets,
    this.watchFactory,
  });

  final String version;

  /// Builds a [VaultShell] for a profile. The production factory
  /// ([productionShell]) wires the file replica, blob store, HTTP transport,
  /// crypto (with the `meta` flow) and history; tests inject fakes. Throws
  /// [VaultCryptoException] (wrong passphrase) or [SyncException] to mark the
  /// vault failed-but-registered.
  final Future<VaultShell> Function(VaultProfile profile) shellFactory;

  /// Persistence for control-channel registrations (null in unit tests).
  final VaultRegistry? registry;
  final DaemonSecretStore? secrets;

  /// Builds each served vault's filesystem watcher stream. `null` (unit
  /// tests) runs continuous mode without a watcher — the periodic rescan and
  /// explicit `sync-now` still drive ingestion.
  final VaultWatchFactory? watchFactory;

  final Map<String, VaultEntry> vaults = {};

  /// The continuous-mode runtime per served vault (shell + watcher + rescan
  /// timer), owned by the daemon: created by [startContinuous], disposed on
  /// [registerVault] re-registration, [removeVault], and [stopAll] — so an
  /// edited vault never leaves the old shell's watcher or timer running.
  final Map<String, VaultRuntime> _runtimes = {};

  /// The runtime currently serving [vaultId], if any (observability seam).
  VaultRuntime? runtimeOf(String vaultId) => _runtimes[vaultId];

  /// Add (or attach to) a vault. **Idempotent** (`vault_daemon` R20): a
  /// vault already served is left as-is. Refuses (throws
  /// [VaultTargetConflict]) a *different* vault that targets the same
  /// (endpoint, database) as one already served, unless
  /// [allowSharedDatabase] carries the owner's acknowledgement — a folder
  /// collision ([VaultFolderConflict]) is refused either way.
  Future<void> addVault(
    VaultProfile profile, {
    bool allowSharedDatabase = false,
  }) async {
    if (vaults.containsKey(profile.vaultId)) return;
    _checkTarget(profile, allowSharedDatabase: allowSharedDatabase);
    try {
      final shell = await shellFactory(profile);
      vaults[profile.vaultId] = VaultEntry(profile: profile, shell: shell);
      await shell.reconcile();
    } on VaultCryptoException catch (e) {
      vaults[profile.vaultId] =
          VaultEntry(profile: profile, error: 'bad passphrase: ${e.message}');
    } on SyncException catch (e) {
      vaults[profile.vaultId] =
          VaultEntry(profile: profile, error: '${e.kind.name}: ${e.message}');
    }
  }

  /// A stable key for a vault's server target, so two profiles that resolve to
  /// the same CouchDB database compare equal (trailing slashes and endpoint
  /// case normalized; database names are case-sensitive in CouchDB).
  static String _targetKey(VaultProfile profile) {
    final endpoint =
        profile.endpoint.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
    return '$endpoint::${profile.database}';
  }

  /// Refuse a registration that would collide with an already-served vault.
  ///
  /// Two passes, database first: a candidate colliding on **both** reports the
  /// database conflict, because that is the one the owner can act on
  /// (`vault_daemon` R23). Two passes rather than one per-vault loop, so
  /// the reported conflict does not depend on map iteration order when the
  /// database and the folder collide with *different* vaults.
  ///
  /// [allowSharedDatabase] is the owner's explicit acknowledgement that one
  /// vault is being put in two folders on purpose; it suppresses the database
  /// rule (a policy guard) and **never** the folder rule (a technical limit).
  void _checkTarget(VaultProfile profile, {bool allowSharedDatabase = false}) {
    final others =
        vaults.values.where((e) => e.profile.vaultId != profile.vaultId);

    if (!allowSharedDatabase) {
      final target = _targetKey(profile);
      for (final existing in others) {
        if (_targetKey(existing.profile) == target) {
          throw VaultTargetConflict(
            vaultId: profile.vaultId,
            conflictsWith: existing.profile.vaultId,
            endpoint: profile.endpoint,
            database: profile.database,
          );
        }
      }
    }

    final root = p.canonicalize(profile.vaultRoot);
    for (final existing in others) {
      final otherRoot = p.canonicalize(existing.profile.vaultRoot);
      if (foldersOverlap(root, otherRoot)) {
        throw VaultFolderConflict(
          vaultId: profile.vaultId,
          conflictsWith: existing.profile.vaultId,
          vaultRoot: profile.vaultRoot,
          otherRoot: existing.profile.vaultRoot,
        );
      }
    }
  }

  /// Register a vault from a front-end over the control channel
  /// (`vault_sync_control` "setup ends with a syncing vault"): store the
  /// secrets in the OS secret store, persist the non-secret registry entry,
  /// and start serving — idempotently, without a restart.
  Future<void> registerVault(AddVaultRequest request) async {
    final profile = VaultProfile.fromRegistryJson(
      request.profile,
      serverPassword: request.serverPassword,
      passphrase: request.passphrase,
      // Editing a connection or re-entering a passphrase must not reset the
      // vault's tuning to defaults just because the request did not mention
      // it (`vault_daemon` R23).
      keep: vaults[request.profile['vaultId']]?.profile,
    );
    // Refuse before storing anything. The front-end sets the acknowledgement
    // after the owner confirms the shared-database warning
    // (`vault_sync_control`); the folder rule holds regardless.
    _checkTarget(profile, allowSharedDatabase: request.allowSharedDatabase);
    final s = secrets;
    // A vault with history only stores no secret at all (`daemon-modules`
    // R8) — there is no connection to keep one for.
    if (s != null && profile.syncEnabled) {
      await s.write(profile.vaultId, DaemonSecretStore.keyServerPassword,
          request.serverPassword);
      await s.write(
          profile.vaultId, DaemonSecretStore.keyPassphrase, request.passphrase);
    }
    registry?.upsert(profile);
    // Editing an existing vault: dispose the old runtime (watcher + rescan
    // timer + shell) so nothing keeps driving the stale shell, then rebuild.
    await _disposeRuntime(profile.vaultId);
    final existing = vaults.remove(profile.vaultId);
    await existing?.shell?.stop(); // no runtime existed — stop the bare shell
    // The acknowledgement must travel with it: `addVault` re-checks, and
    // without the flag it would refuse the registration this method just
    // accepted.
    await addVault(profile, allowSharedDatabase: request.allowSharedDatabase);
    await startContinuous(profile.vaultId);
  }

  /// One vault's per-module configuration — the registry shape, which never
  /// holds a secret (`daemon-modules` R9).
  Map<String, Object?> vaultConfig(String vaultId) {
    final entry = vaults[vaultId];
    if (entry == null) {
      throw ConfigError('unknown vault: $vaultId', unknownVault: true);
    }
    return entry.profile.toRegistryJson();
  }

  /// Change part of one vault's configuration without re-registering it
  /// (`daemon-modules` R9, R10): [patch] names only what changes; omitted
  /// means unchanged. A history change is applied **in place** — the sync
  /// module is never stopped; an exclusion change goes to the folder live;
  /// a change that reaches the runtime replaces it. The result is persisted.
  Future<VaultProfile> updateConfig(
      String vaultId, Map<String, Object?> patch) async {
    final entry = vaults[vaultId];
    if (entry == null) {
      throw ConfigError('unknown vault: $vaultId', unknownVault: true);
    }
    final current = entry.profile;
    final next = current.patched(patch);
    if (next.syncEnabled && next.endpoint.isEmpty) {
      throw ConfigError('vault "$vaultId" has no connection to enable sync '
          'on — add one with the front-end\'s setup or `init`, which is how '
          'sync is added');
    }
    registry?.upsert(next);
    entry.profile = next;
    final shell = entry.shell;
    if (shell == null) return next; // a failed vault: picked up on next start

    if (current.runtimeDiffers(next)) {
      // The connection, the folder's timing, or sync itself changed: the
      // same path a re-registration takes.
      final hadRuntime = _runtimes.containsKey(vaultId);
      await _disposeRuntime(vaultId);
      await shell.stop();
      vaults.remove(vaultId);
      await addVault(next, allowSharedDatabase: true);
      if (hadRuntime) await startContinuous(vaultId);
      return next;
    }
    if (current.historyDiffers(next)) {
      await shell.reconfigureHistory(next);
    } else {
      shell.profile = next;
    }
    if (current.exclusionsDiffer(next)) {
      shell.folder.applyExclusions(next.exclusions);
    }
    return next;
  }

  /// Start continuous operation for one vault or all healthy, unpaused ones:
  /// each gets a [VaultRuntime] — the longpoll engine plus the watcher and
  /// the periodic-rescan backstop — owned and later disposed by the daemon.
  Future<void> startContinuous([String? vaultId]) async {
    for (final entry in _select(vaultId)) {
      final shell = entry.shell;
      if (shell == null || shell.paused) continue;
      if (_runtimes.containsKey(entry.profile.vaultId)) continue;
      final runtime = VaultRuntime(shell: shell, watch: watchFactory);
      _runtimes[entry.profile.vaultId] = runtime;
      await runtime.start();
    }
  }

  Future<void> _disposeRuntime(String vaultId) async {
    final runtime = _runtimes.remove(vaultId);
    await runtime?.dispose();
  }

  Future<void> stopAll() async {
    for (final vaultId in _runtimes.keys.toList()) {
      await _disposeRuntime(vaultId);
    }
    for (final entry in vaults.values) {
      await entry.shell?.stop();
    }
  }

  Future<void> removeVault(String vaultId) async {
    await _disposeRuntime(vaultId);
    final entry = vaults.remove(vaultId);
    await entry?.shell?.stop();
  }

  void pause(String vaultId) => vaults[vaultId]?.shell?.paused = true;

  /// Resume a paused vault and run a catch-up reconcile: remote changes that
  /// arrived while paused were deliberately not applied, and local edits were
  /// deliberately not ingested — the reconcile brings both up to date.
  void resume(String vaultId) {
    final shell = vaults[vaultId]?.shell;
    if (shell == null) return;
    shell.paused = false;
    unawaited(shell.reconcileGuarded());
  }

  /// Run a reconcile (scan + pull + push + materialize + history) now.
  Future<void> syncNow([String? vaultId]) async {
    for (final entry in _select(vaultId)) {
      await entry.shell?.reconcile();
    }
  }

  List<VaultEntry> _select(String? vaultId) => vaultId == null
      ? vaults.values.toList()
      : [if (vaults[vaultId] != null) vaults[vaultId]!];

  Future<void> applyCommand(ControlCommand command, String? vaultId) async {
    switch (command) {
      case ControlCommand.pause:
        if (vaultId != null) pause(vaultId);
      case ControlCommand.resume:
        if (vaultId != null) resume(vaultId);
      case ControlCommand.syncNow:
        await syncNow(vaultId);
    }
  }

  DaemonStatus status() => DaemonStatus(
        version: version,
        vaults: [for (final e in vaults.values) _statusOf(e)],
      );

  VaultStatus _statusOf(VaultEntry entry) {
    final shell = entry.shell;
    final modules = [
      for (final m in VaultModule.values)
        if (entry.profile.modules.contains(m)) m.name,
    ];
    if (shell == null) {
      return VaultStatus(
        vaultId: entry.profile.vaultId,
        state: SyncState.error,
        unsynced: 0,
        error: entry.error,
        modules: modules,
      );
    }
    final SyncState state;
    if (shell.paused) {
      state = SyncState.paused;
    } else if (shell.lastError != null) {
      state = shell.lastError!.startsWith('unreachable')
          ? SyncState.offline
          : SyncState.error;
    } else {
      state = SyncState.running;
    }
    return VaultStatus(
      vaultId: entry.profile.vaultId,
      state: state,
      unsynced: shell.unsynced,
      lastSyncMillis: shell.lastSyncMillis == 0 ? null : shell.lastSyncMillis,
      error: shell.lastError,
      conflicts: List<String>.from(shell.conflictPaths),
      divergent: shell.divergent,
      modules: modules,
      degraded: Map<String, String>.from(shell.moduleErrors),
    );
  }
}

/// Whether two vault roots are the same directory or nested either way — the
/// folder half of vault isolation (`vault_daemon` R23). Both sides are
/// canonicalized here, so a caller cannot get it wrong by passing a raw path;
/// canonicalizing an already-canonical path is a no-op.
bool foldersOverlap(String a, String b) {
  final x = p.canonicalize(a);
  final y = p.canonicalize(b);
  return x == y || p.isWithin(x, y) || p.isWithin(y, x);
}

/// Resolve the vault's key material with the offline-first `meta` flow
/// (`vault_daemon` RV3): prefer the server's `meta` (verifying the
/// passphrase, caching locally), fall back to the cached copy when offline
/// — or when the server serves a `meta` that fails to parse/verify while
/// the previously verified cache still verifies (the untrusted server must
/// not be able to brick a provisioned device by mangling `meta`) —
/// initialize a fresh `meta` on an empty database, and never overwrite an
/// existing one. Throws [VaultCryptoException] (wrong passphrase) or
/// [SyncException] (offline with no cached meta).
Future<KeyMaterial> resolveKeyMaterial({
  required CouchTransport transport,
  required String passphrase,
  required File cacheFile,
  void Function(String message)? log,
}) async {
  Map<String, Object?>? cached;
  if (cacheFile.existsSync()) {
    cached = (jsonDecode(cacheFile.readAsStringSync()) as Map)
        .cast<String, Object?>();
  }

  Map<String, Object?>? remote;
  var online = true;
  try {
    remote = await transport.getDoc('meta');
  } on SyncException {
    online = false;
  }

  if (remote != null) {
    final KeyMaterial keys;
    try {
      keys = await VaultCrypto.init(passphrase, meta: remote);
    } on VaultCryptoException catch (remoteError) {
      // A corrupt/tampered remote meta must not hard-fail a device that
      // already holds a verified cache: fall back to the cache when it
      // still verifies. A genuinely wrong passphrase fails against the
      // cache too and the original error propagates.
      if (cached != null) {
        try {
          final fromCache = await VaultCrypto.init(passphrase, meta: cached);
          log?.call('warning: the server meta failed verification '
              '(${remoteError.kind.name}); using the valid cached meta — '
              'the remote meta is divergent or tampered');
          return fromCache;
        } on VaultCryptoException {
          // Both fail — surface the remote error (e.g. wrongPassphrase).
        }
      }
      rethrow;
    }
    cacheFile.parent.createSync(recursive: true);
    cacheFile.writeAsStringSync(jsonEncode(keys.meta));
    return keys;
  }
  if (cached != null) {
    return VaultCrypto.init(passphrase, meta: cached);
  }
  if (!online) {
    throw SyncException(
      SyncErrorKind.unreachable,
      'hub unreachable and no cached meta — first init needs the server',
    );
  }
  // Empty database: first device initializes. A concurrent init races via the
  // plain MVCC PUT — the loser re-reads and verifies.
  final keys = await VaultCrypto.init(passphrase);
  try {
    await transport.putDoc('meta', keys.meta);
    cacheFile.parent.createSync(recursive: true);
    cacheFile.writeAsStringSync(jsonEncode(keys.meta));
    return keys;
  } on SyncException {
    final existing = await transport.getDoc('meta');
    if (existing != null) {
      final verified = await VaultCrypto.init(passphrase, meta: existing);
      cacheFile.parent.createSync(recursive: true);
      cacheFile.writeAsStringSync(jsonEncode(verified.meta));
      return verified;
    }
    rethrow;
  }
}

/// The production [VaultShell] factory (`daemon-modules` R1): the
/// [VaultFolder] that owns the vault folder, and each module the profile
/// enables — sync over a durable file-backed replica and blob store under
/// `<stateRoot>/data/<vaultId>/`, the real HTTP transport, crypto from the
/// `meta` flow and the continuous engine; history over the vault's `.hist/`.
/// A vault with history only never builds a transport, never resolves a
/// key, never opens a replica.
///
/// [histStore] overrides history's storage — the seam a test uses to rig
/// the module to fail (R3).
Future<VaultShell> productionShell(
  VaultProfile profile, {
  required String stateRoot,
  DaemonLog? log,
  Notifier? notifier,
  TrashFn? trash,
  String Function(List<int> bytes)? hasher,
  int Function()? clock,
  HistStore Function(String vaultRoot)? histStore,
}) async {
  final dataDir = p.join(stateRoot, 'data', profile.vaultId);
  // The single owner of the vault folder (`vault_folder` R4). Its record of
  // what it last saw lives beside the replica, and it inlines content up to
  // the same threshold the crypto module streams above — so a large file is
  // never held whole by anyone.
  final folder = VaultFolder(
    root: profile.vaultRoot,
    cursor: FolderCursor(FolderCursor.pathIn(dataDir)),
    exclusions: profile.exclusions,
    coalesceMillis: profile.watchDebounceMillis,
    inlineLimitBytes: profile.inlineThresholdBytes,
    clock: clock,
    trash: trash,
    trashFallbackDir: p.join(dataDir, 'trash'),
    hasher: hasher,
  );

  SyncModule? sync;
  if (profile.syncEnabled) {
    final transport = CouchTransport(
      baseUrl: Uri.parse(profile.endpoint),
      database: profile.database,
      username: profile.serverUser,
      password: profile.serverPassword,
    );
    // Offline-first (R4): registration succeeds with the hub unreachable as
    // long as a cached meta exists; ensureDatabase is best-effort.
    try {
      await transport.ensureDatabase();
    } on SyncException {
      // Hub not reachable yet — the engine retries and surfaces offline
      // status.
    }
    final keys = await resolveKeyMaterial(
      transport: transport,
      passphrase: profile.passphrase,
      cacheFile: File(p.join(dataDir, 'meta.json')),
      log: log?.log,
    );
    final crypto = VaultCrypto(
      keys,
      inlineThreshold: profile.inlineThresholdBytes,
    );
    final store = LocalStore(
      backend: FileBackend(p.join(dataDir, 'replica')),
      blobStore: FsBlobStore(p.join(dataDir, 'blobs')),
    );
    final replicaId = replicaIdFor(
      profile.vaultId,
      readOrCreateDeviceId(stateRoot),
    );
    sync = SyncModule(
      profile: profile,
      folder: folder,
      store: store,
      transport: transport,
      crypto: crypto,
      engine: SyncEngine(
        store: store,
        transport: transport,
        replicaId: replicaId,
      ),
      replicaId: replicaId,
      stateDir: dataDir,
      log: log,
      notifier: notifier,
      hasher: hasher,
      clock: clock,
    );
  }

  HistoryModule buildHistory(VaultProfile p, VaultFolder f) =>
      buildHistoryModule(p, f, log: log, hasher: hasher, histStore: histStore);

  return VaultShell(
    profile: profile,
    folder: folder,
    stateDir: dataDir,
    sync: sync,
    history: profile.historyEnabled ? buildHistory(profile, folder) : null,
    historyFactory: buildHistory,
    log: log,
  );
}

/// The history module over [folder] as the profile's history block tunes it:
/// the writer, and the commit queue that decides **when** an edit becomes a
/// version — the idle window lives here, on the daemon's side: `vault_hist`
/// records what it is committed and owns no timers (D7).
HistoryModule buildHistoryModule(
  VaultProfile profile,
  VaultFolder folder, {
  DaemonLog? log,
  String Function(List<int> bytes)? hasher,
  HistStore Function(String vaultRoot)? histStore,
}) {
  final writer = HistWriter(
    store: histStore?.call(profile.vaultRoot) ?? FsHistStore(profile.vaultRoot),
    now: () => DateTime.now().millisecondsSinceEpoch,
    extensions: profile.histExtensions,
    writerName: profile.effectiveWriterName,
  );
  return HistoryModule(
    folder: folder,
    writer: writer,
    queue: HistCommitQueue(
      hist: writer,
      now: () => DateTime.now().millisecondsSinceEpoch,
      idleMillis: profile.histIdleMillis,
    ),
    log: log,
    vaultId: profile.vaultId,
    hasher: hasher,
  );
}

/// The modules a vault can enable (`daemon-modules` R1). Any subset works:
/// history alone needs no server, no credentials and no passphrase; sync
/// alone creates no `.hist/`; both is the daemon as it always was.
enum VaultModule { sync, history }

/// A per-vault profile (`vault_daemon` R23, RV10, `daemon-modules` R8).
/// The daemon serves many vaults, each with its own profile. Secrets
/// (`serverPassword`, `passphrase`) are hydrated **in memory** from the OS
/// secret store keyed by vault — they are never written into the vault, the
/// server, or the persisted registry (C11) — and exist only when the sync
/// module is enabled: a history-only vault stores no secret at all.
///
/// Persisted **per module**: the connection under `sync`, the writer name,
/// tracked extensions and idle window under `history`, folder-level tuning
/// under `folder`. The Dart surface stays flat for the hosts that build
/// profiles. That is the registry's only shape.
class VaultProfile {
  const VaultProfile({
    required this.vaultId,
    required this.vaultRoot,
    this.endpoint = '',
    this.database = '',
    this.serverUser = '',
    this.serverPassword = '',
    this.passphrase = '',
    this.modules = allModules,
    this.writerName,
    this.exclusions = defaultExclusions,
    this.histExtensions = const ['.md'],
    this.histIdleMillis = 60000,
    this.watchDebounceMillis = 1500,
    this.rescanSeconds = 300,
    this.inlineThresholdBytes = 1024 * 1024,
  });

  /// Both modules — the default.
  static const Set<VaultModule> allModules = {
    VaultModule.sync,
    VaultModule.history,
  };

  /// A stable id for this vault (keys the replica, checkpoints and secrets).
  final String vaultId;

  /// Absolute path to the vault folder the daemon owns.
  final String vaultRoot;

  /// Which modules this vault enables (`daemon-modules` R1).
  final Set<VaultModule> modules;

  bool get syncEnabled => modules.contains(VaultModule.sync);
  bool get historyEnabled => modules.contains(VaultModule.history);

  /// e.g. `https://sync.example.com`. Empty when sync is off.
  final String endpoint;

  /// The CouchDB database name, e.g. `vault`. Empty when sync is off.
  final String database;

  final String serverUser;

  /// Secret — from the OS secret store, never synced, never persisted here.
  final String serverPassword;

  /// The E2EE passphrase — secret, from the OS secret store, never synced and
  /// never written into the vault it encrypts.
  final String passphrase;

  /// This client's identity in history file headers (`vault_hist` RV5).
  /// Defaults to the vault id when unset.
  final String? writerName;

  /// Paths excluded from sync, watching, and history (`vault_daemon`
  /// RV8). `.hist/` is NOT here — it syncs; it is excluded only from
  /// history tracking.
  final List<String> exclusions;

  /// Extensions history versions (`vault_hist` RV5).
  final List<String> histExtensions;

  final int histIdleMillis;

  /// Per-path watcher debounce (`vault_daemon` RV4, ~1–2 s).
  final int watchDebounceMillis;

  /// Periodic full-rescan interval — the watcher's safety net.
  final int rescanSeconds;

  /// Inline-vs-attachment size threshold handed to `vault_crypto` (RV2).
  final int inlineThresholdBytes;

  /// The default exclusion list (`vault_daemon` RV8). `.obsidian/` itself
  /// syncs; only its volatile workspace files and the legacy sync plugins are
  /// excluded.
  static const defaultExclusions = [
    '.DS_Store',
    '.trash/',
    '.git/',
    '_workspace/',
    '.obsidian/workspace*.json',
    '.obsidian/plugins/obsidian-livesync/',
    '.obsidian/plugins/remotely-save/',
  ];

  String get effectiveWriterName => writerName ?? vaultId;

  /// The **non-secret** persisted form (the daemon's vault registry, RV10),
  /// shaped per module (`daemon-modules` R8).
  Map<String, Object?> toRegistryJson() => {
        'vaultId': vaultId,
        'vaultRoot': vaultRoot,
        'modules': [
          for (final m in VaultModule.values)
            if (modules.contains(m)) m.name
        ],
        'folder': {
          'exclusions': exclusions,
          'watchDebounceMillis': watchDebounceMillis,
          'rescanSeconds': rescanSeconds,
          'inlineThresholdBytes': inlineThresholdBytes,
        },
        if (syncEnabled)
          'sync': {
            'endpoint': endpoint,
            'database': database,
            'serverUser': serverUser,
          },
        if (historyEnabled)
          'history': {
            'writerName': writerName,
            'extensions': histExtensions,
            'idleMillis': histIdleMillis,
          },
      };

  /// Rebuild from the registry plus secrets hydrated from the secret store.
  /// The **connection only** — what a front-end owns and may legitimately
  /// send when it registers or re-registers a vault.
  ///
  /// Deliberately not the whole profile: a surface editing a connection or
  /// re-entering a passphrase would otherwise serialize its own constructor
  /// defaults over the vault's tuning and silently reset it. Omitting those
  /// keys lets the daemon keep what it already holds
  /// (`vault_daemon` R23).
  Map<String, Object?> toConnectionJson() => {
        'vaultId': vaultId,
        'vaultRoot': vaultRoot,
        'endpoint': endpoint,
        'database': database,
        'serverUser': serverUser,
      };

  /// Rebuild a profile from its non-secret registry form — the per-module
  /// shape `toRegistryJson` writes. The **connection** alone may also arrive
  /// flat (`toConnectionJson`, a front-end's registration), and a flat
  /// connection key on top of a nested entry is the caller's deliberate value.
  /// Nothing else is read from the top level.
  ///
  /// [keep] is the profile this one replaces, when the daemon already serves
  /// the vault. A **field the JSON omits takes its value from [keep]**, not
  /// from the documented default: a registration carries the *connection*,
  /// and a front-end must not have to model every tuning field in existence
  /// to avoid silently resetting the ones it does not know about
  /// (`vault_daemon` R23, `daemon-modules` R10). With no [keep] — a
  /// vault the daemon has never seen — the defaults apply, because there is
  /// nothing to preserve.
  static VaultProfile fromRegistryJson(
    Map<String, Object?> json, {
    required String serverPassword,
    required String passphrase,
    VaultProfile? keep,
  }) {
    final folder = _block(json, 'folder');
    final sync = _block(json, 'sync');
    final history = _block(json, 'history');
    Object? connection(String key) =>
        json.containsKey(key) ? json[key] : sync?[key];

    final named = json['modules'];
    final modules = named is List
        ? {for (final m in named.cast<String>()) VaultModule.values.byName(m)}
        : keep?.modules ?? allModules;

    final hasWriter = history?.containsKey('writerName') ?? false;

    return VaultProfile(
      vaultId: json['vaultId'] as String,
      vaultRoot: json['vaultRoot'] as String,
      modules: modules,
      endpoint: connection('endpoint') as String? ?? keep?.endpoint ?? '',
      database: connection('database') as String? ?? keep?.database ?? '',
      serverUser: connection('serverUser') as String? ?? keep?.serverUser ?? '',
      serverPassword: serverPassword,
      passphrase: passphrase,
      writerName:
          hasWriter ? history!['writerName'] as String? : keep?.writerName,
      exclusions: (folder?['exclusions'] as List?)?.cast<String>() ??
          keep?.exclusions ??
          defaultExclusions,
      histExtensions: (history?['extensions'] as List?)?.cast<String>() ??
          keep?.histExtensions ??
          const ['.md'],
      histIdleMillis: (history?['idleMillis'] as num?)?.toInt() ??
          keep?.histIdleMillis ??
          60000,
      watchDebounceMillis: (folder?['watchDebounceMillis'] as num?)?.toInt() ??
          keep?.watchDebounceMillis ??
          1500,
      rescanSeconds: (folder?['rescanSeconds'] as num?)?.toInt() ??
          keep?.rescanSeconds ??
          300,
      inlineThresholdBytes:
          (folder?['inlineThresholdBytes'] as num?)?.toInt() ??
              keep?.inlineThresholdBytes ??
              1024 * 1024,
    );
  }

  static Map<String, Object?>? _block(Map<String, Object?> json, String key) {
    final value = json[key];
    return value is Map ? value.cast<String, Object?>() : null;
  }

  /// This profile with a **partial** configuration applied (`daemon-modules`
  /// R9, R10): [patch] is shaped like the registry entry — any of the
  /// `modules`, `folder`, `sync` and `history` keys — and a block it names
  /// is merged field by field into the existing one. Omitted means
  /// unchanged. Secrets are untouched: a configuration change never carries
  /// or needs one.
  VaultProfile patched(Map<String, Object?> patch) {
    final merged = Map<String, Object?>.from(toRegistryJson());
    for (final entry in patch.entries) {
      final current = merged[entry.key];
      final incoming = entry.value;
      if (current is Map && incoming is Map) {
        merged[entry.key] = {
          ...current.cast<String, Object?>(),
          ...incoming.cast<String, Object?>(),
        };
      } else {
        merged[entry.key] = incoming;
      }
    }
    return fromRegistryJson(merged,
        serverPassword: serverPassword, passphrase: passphrase, keep: this);
  }

  /// Whether a change from this profile to [next] reaches the runtime — the
  /// connection, the folder's timing and thresholds, or the sync module's
  /// presence — rather than only a module that can be rebuilt in place.
  bool runtimeDiffers(VaultProfile next) =>
      syncEnabled != next.syncEnabled ||
      endpoint != next.endpoint ||
      database != next.database ||
      serverUser != next.serverUser ||
      watchDebounceMillis != next.watchDebounceMillis ||
      rescanSeconds != next.rescanSeconds ||
      inlineThresholdBytes != next.inlineThresholdBytes;

  /// Whether the history block differs — writer name, extensions, idle
  /// window, or the module's presence.
  bool historyDiffers(VaultProfile next) =>
      historyEnabled != next.historyEnabled ||
      writerName != next.writerName ||
      !_sameList(histExtensions, next.histExtensions) ||
      histIdleMillis != next.histIdleMillis;

  bool exclusionsDiffer(VaultProfile next) =>
      !_sameList(exclusions, next.exclusions);

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  VaultProfile copyWith({
    String? serverPassword,
    String? passphrase,
    Set<VaultModule>? modules,
    String? writerName,
    bool clearWriterName = false,
    List<String>? exclusions,
    List<String>? histExtensions,
    int? histIdleMillis,
    int? watchDebounceMillis,
    int? rescanSeconds,
    int? inlineThresholdBytes,
  }) =>
      VaultProfile(
        vaultId: vaultId,
        vaultRoot: vaultRoot,
        endpoint: endpoint,
        database: database,
        serverUser: serverUser,
        serverPassword: serverPassword ?? this.serverPassword,
        passphrase: passphrase ?? this.passphrase,
        modules: modules ?? this.modules,
        writerName: clearWriterName ? null : (writerName ?? this.writerName),
        exclusions: exclusions ?? this.exclusions,
        histExtensions: histExtensions ?? this.histExtensions,
        histIdleMillis: histIdleMillis ?? this.histIdleMillis,
        watchDebounceMillis: watchDebounceMillis ?? this.watchDebounceMillis,
        rescanSeconds: rescanSeconds ?? this.rescanSeconds,
        inlineThresholdBytes: inlineThresholdBytes ?? this.inlineThresholdBytes,
      );
}

// The control/status wire types shared by the daemon and its front-ends
// (`vault_daemon` R18, `vault_sync_control` R17). This channel carries
// **only** control and status — never vault plaintext (C3), so nothing here
// holds a document body or a secret.

enum SyncState { running, paused, offline, error }

/// Per-vault status shown by every front-end (`vault_sync_control` R17): state,
/// last-sync time, un-synced count, an error slot, the conflict list, and
/// the divergence count — how many files have a divergent history line
/// (history-surface R16), carried as data; rendering it is the later
/// presentation effort.
class VaultStatus {
  const VaultStatus({
    required this.vaultId,
    required this.state,
    required this.unsynced,
    this.lastSyncMillis,
    this.error,
    this.conflicts = const [],
    this.divergent = 0,
    this.modules = const [],
    this.degraded = const {},
  });

  final String vaultId;
  final SyncState state;
  final int unsynced;
  final int? lastSyncMillis;
  final String? error;
  final List<String> conflicts;

  /// Files whose history has a divergent line — a count of files, never of
  /// branches (R13).
  final int divergent;

  /// The modules this vault enables, by name (`daemon-modules` R1).
  final List<String> modules;

  /// Modules whose last operation failed, with the error (`daemon-modules`
  /// R3) — the vault is **degraded**, not down: the others keep running.
  final Map<String, String> degraded;

  Map<String, Object?> toJson() => {
        'vaultId': vaultId,
        'state': state.name,
        'unsynced': unsynced,
        'lastSyncMillis': lastSyncMillis,
        'error': error,
        'conflicts': conflicts,
        'divergent': divergent,
        'modules': modules,
        'degraded': degraded,
      };

  static VaultStatus fromJson(Map<String, Object?> json) => VaultStatus(
        vaultId: json['vaultId'] as String,
        state: SyncState.values.byName(json['state'] as String),
        unsynced: (json['unsynced'] as num).toInt(),
        lastSyncMillis: (json['lastSyncMillis'] as num?)?.toInt(),
        error: json['error'] as String?,
        conflicts: ((json['conflicts'] as List?) ?? const []).cast<String>(),
        divergent: (json['divergent'] as num?)?.toInt() ?? 0,
        modules: ((json['modules'] as List?) ?? const []).cast<String>(),
        degraded:
            ((json['degraded'] as Map?) ?? const {}).cast<String, String>(),
      );
}

/// The daemon's authoritative status (`vault_daemon` R20): its version and
/// each served vault's status.
class DaemonStatus {
  const DaemonStatus({required this.version, required this.vaults});

  final String version;
  final List<VaultStatus> vaults;

  Map<String, Object?> toJson() => {
        'version': version,
        'vaults': [for (final v in vaults) v.toJson()],
      };

  static DaemonStatus fromJson(Map<String, Object?> json) => DaemonStatus(
        version: json['version'] as String,
        vaults: [
          for (final v in (json['vaults'] as List).cast<Map<String, Object?>>())
            VaultStatus.fromJson(v),
        ],
      );
}

/// The v1 control set (`vault_sync_control` D10): pause/resume (enable/disable)
/// and sync-now. Install/bootstrap is a front-end concern (`vault_sync_control`).
enum ControlCommand { pause, resume, syncNow }

/// Registering (or editing) a vault over the control channel
/// (`vault_daemon` "add/edit a vault profile", `vault_sync_control`
/// "setup ends with a syncing vault"). The non-secret profile fields travel
/// beside the two secrets; the daemon stores the secrets in the OS secret
/// store and persists only the non-secret registry entry — this request is
/// in-memory, loopback-only, token-authenticated, and never logged.
class AddVaultRequest {
  const AddVaultRequest({
    required this.profile,
    required this.passphrase,
    required this.serverPassword,
    this.allowSharedDatabase = false,
  });

  /// The non-secret profile fields (`VaultProfile.toRegistryJson` shape).
  final Map<String, Object?> profile;

  final String passphrase;
  final String serverPassword;

  /// The owner's explicit acknowledgement that this vault targets a database
  /// another vault already uses — set by a front-end only after the owner
  /// confirms the warning (`vault_sync_control`). Absent means "not
  /// acknowledged", so an old client keeps the safe default.
  final bool allowSharedDatabase;

  Map<String, Object?> toJson() => {
        'profile': profile,
        'secrets': {
          'passphrase': passphrase,
          'serverPassword': serverPassword,
        },
        if (allowSharedDatabase) 'allowSharedDatabase': true,
      };

  static AddVaultRequest fromJson(Map<String, Object?> json) {
    final secrets = (json['secrets'] as Map).cast<String, Object?>();
    return AddVaultRequest(
      profile: (json['profile'] as Map).cast<String, Object?>(),
      passphrase: secrets['passphrase'] as String? ?? '',
      serverPassword: secrets['serverPassword'] as String? ?? '',
      allowSharedDatabase: json['allowSharedDatabase'] == true,
    );
  }
}

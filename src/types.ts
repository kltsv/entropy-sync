// The control/status wire types, mirroring the daemon's control_protocol.dart so
// the plugin is an interchangeable control plane over the same daemon
// (vault_sync_control R20, R22). Carries only control/status — never plaintext.

export type SyncState = 'running' | 'paused' | 'offline' | 'error';

export interface VaultStatus {
  vaultId: string;
  state: SyncState;
  unsynced: number;
  lastSyncMillis: number | null;
  error: string | null;
  conflicts: string[];
}

export interface DaemonStatus {
  version: string;
  vaults: VaultStatus[];
}

export type ControlCommand = 'pause' | 'resume' | 'syncNow';

/// The non-secret connection of the daemon's add-vault handoff — the flat
/// `VaultProfile.toConnectionJson` shape. The daemon applies its own defaults
/// for everything else (the writer name defaults to the vault id); a module's
/// tuning is changed afterwards through its configuration, never here.
export interface AddVaultProfile {
  vaultId: string;
  vaultRoot: string;
  endpoint: string;
  database: string;
  serverUser: string;
}

/// Registering (or editing) a vault over the control channel, mirroring the
/// Dart AddVaultRequest: the non-secret profile beside the two secrets. Sent
/// loopback-only, token-authenticated; the daemon stores the secrets in the OS
/// secret store and persists only the non-secret registry entry.
export interface AddVaultRequest {
  profile: AddVaultProfile;
  passphrase: string;
  serverPassword: string;
  /// The owner's explicit acknowledgement that this vault targets a database
  /// another vault already uses — set only after they confirm the warning.
  /// Omitted means "not acknowledged", the safe default.
  allowSharedDatabase?: boolean;
}

/// The non-secret connection a setup-URI carries (vault_sync_control D9).
export interface SetupConnection {
  endpoint: string;
  database: string;
  serverUser: string;
  serverPassword: string;
}

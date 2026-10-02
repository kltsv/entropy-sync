import type { AddVaultRequest, ControlCommand, DaemonStatus } from './types';

// A front-end client to the daemon's authenticated localhost control channel
// (vault_sync_control R18, R19), mirroring the Dart ControlClient. It presents
// the daemon token on every request; without it the daemon refuses status and
// commands. The plugin runs NO replication of its own (N3) — it only controls.

export class ControlClient {
  constructor(
    private readonly port: number,
    private readonly token: string,
  ) {}

  private get headers(): Record<string, string> {
    return { 'x-entropy-token': this.token, 'content-type': 'application/json' };
  }

  async status(): Promise<DaemonStatus> {
    const resp = await fetch(`http://127.0.0.1:${this.port}/status`, {
      headers: this.headers,
    });
    this.check(resp);
    return (await resp.json()) as DaemonStatus;
  }

  async command(command: ControlCommand, vaultId?: string): Promise<DaemonStatus> {
    const resp = await fetch(`http://127.0.0.1:${this.port}/control`, {
      method: 'POST',
      headers: this.headers,
      body: JSON.stringify({ command, vaultId: vaultId ?? null }),
    });
    this.check(resp);
    return (await resp.json()) as DaemonStatus;
  }

  /**
   * Register (or edit) a vault on the running daemon — the front-end handoff
   * that makes setup end with a syncing vault (vault_sync_control R21, R23).
   * Idempotent: re-sending the same vault attaches (R20). The wire shape
   * mirrors the Dart AddVaultRequest.toJson():
   * `{profile: {...registry fields}, secrets: {passphrase, serverPassword}}`.
   * Throws ControlVaultConflict when the daemon refuses a target already
   * served by a different vault (HTTP 409, error=targetConflict).
   */
  async addVault(request: AddVaultRequest): Promise<DaemonStatus> {
    const resp = await fetch(`http://127.0.0.1:${this.port}/vaults`, {
      method: 'POST',
      headers: this.headers,
      body: JSON.stringify({
        profile: request.profile,
        secrets: {
          passphrase: request.passphrase,
          serverPassword: request.serverPassword,
        },
        ...(request.allowSharedDatabase ? { allowSharedDatabase: true } : {}),
      }),
    });
    if (resp.status === 409) {
      const body = (await resp.json()) as {
        conflictsWith?: string;
        message?: string;
        error?: string;
      };
      throw new ControlVaultConflict(
        body.conflictsWith ?? '?',
        body.message ?? 'target conflict',
        body.error === 'folderConflict' ? 'folder' : 'database',
      );
    }
    this.check(resp);
    return (await resp.json()) as DaemonStatus;
  }

  private check(resp: Response): void {
    if (resp.status === 401 || resp.status === 403) {
      throw new Error('control channel refused: not authenticated');
    }
    if (!resp.ok) {
      throw new Error(`control channel error: HTTP ${resp.status}`);
    }
  }
}

/// The daemon refused to register a vault whose (endpoint, database) is already
/// served by a different vault — the daemon-side isolation-by-database, the
/// same rule setup enforces locally (mirrors the Dart ControlVaultConflict).
/**
 * Which isolation rule the daemon refused on. A `database` conflict is a policy
 * guard the owner may acknowledge; a `folder` conflict is a technical limit
 * with no override (vault_daemon R23).
 */
export type VaultConflictKind = 'database' | 'folder';

export class ControlVaultConflict extends Error {
  constructor(
    readonly conflictsWith: string,
    message: string,
    readonly kind: VaultConflictKind = 'database',
  ) {
    super(message);
    this.name = 'ControlVaultConflict';
  }

  /** Whether re-sending with the acknowledgement could succeed. */
  get isAcknowledgeable(): boolean {
    return this.kind === 'database';
  }
}

import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';

import { discoveryDir } from './discovery';

// Per-vault secret storage (vault_sync_control R23, C11): the passphrase and
// server password are kept keyed by vault, OUTSIDE the vault (so they are never
// written into the vault the passphrase encrypts) and outside anything the
// daemon syncs (~/.entropy-sync is not a vault). A real OS keychain is the ideal
// backend; this file-backed store is the fallback, restricted to the owner.

export interface SecretStore {
  write(vaultId: string, key: string, value: string): void;
  read(vaultId: string, key: string): string | null;
}

export const SECRET_PASSPHRASE = 'passphrase';
export const SECRET_SERVER_PASSWORD = 'serverPassword';

export class FileSecretStore implements SecretStore {
  private readonly dir: string;

  constructor(baseDir: string = join(discoveryDir(), 'secrets')) {
    this.dir = baseDir;
    if (!existsSync(this.dir)) {
      mkdirSync(this.dir, { recursive: true });
    }
  }

  private fileFor(vaultId: string, key: string): string {
    return join(this.dir, `${encodeURIComponent(vaultId)}.${encodeURIComponent(key)}`);
  }

  write(vaultId: string, key: string, value: string): void {
    const file = this.fileFor(vaultId, key);
    writeFileSync(file, value, 'utf8');
    chmodSync(file, 0o600);
  }

  read(vaultId: string, key: string): string | null {
    const file = this.fileFor(vaultId, key);
    return existsSync(file) ? readFileSync(file, 'utf8') : null;
  }
}

/** Where the daemon's per-vault config lives (non-secret), outside any vault. */
export function daemonConfigDir(): string {
  return process.env.ENTROPY_SYNC_HOME ?? join(homedir(), '.entropy-sync');
}

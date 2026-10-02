import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs';
import { dirname, join, relative, resolve, isAbsolute } from 'path';

import { discoveryDir } from './discovery';

// A shared, non-secret registry of what each configured vault claimed — its
// (endpoint, database) and its folder (vault_sync_control R23), mirroring the
// Dart SyncTargetRegistry. Setup consults it for both isolation rules: a shared
// database, which the owner may confirm, and an overlapping folder, which is
// refused outright. Lives outside every vault (~/.entropy-sync/targets.json),
// so a claim made by the app is seen here too — which is what lets the folder
// rule catch a vault nested inside one configured in the other front-end.

/** The comparison key — identical to the Dart daemon/app normalization. */
export function targetKey(endpoint: string, database: string): string {
  const e = endpoint.trim().toLowerCase().replace(/\/+$/, '');
  return `${e}::${database}`;
}

/** One vault's entry: the normalized target and the vault's canonical root. */
export interface SyncClaim {
  target: string;
  root: string;
}

/**
 * Whether two vault roots are the same directory or nested either way — the
 * port of the Dart `foldersOverlap`. Both sides are resolved first, so a raw
 * path compares correctly.
 */
export function foldersOverlap(a: string, b: string): boolean {
  const x = resolve(a);
  const y = resolve(b);
  if (x === y) return true;
  const within = (outer: string, inner: string): boolean => {
    const rel = relative(outer, inner);
    return rel !== '' && !rel.startsWith('..') && !isAbsolute(rel);
  };
  return within(x, y) || within(y, x);
}

export class SyncTargetRegistry {
  constructor(private readonly dir: string = discoveryDir()) {}

  private file(): string {
    return join(this.dir, 'targets.json');
  }

  // Claims are `{target, root}` objects — the one shape the file has (identical
  // to the Dart SyncTargetRegistry). Anything else in it is not a claim.
  private load(): Record<string, SyncClaim> {
    const f = this.file();
    if (!existsSync(f)) return {};
    try {
      const raw = JSON.parse(readFileSync(f, 'utf8')) as Record<string, unknown>;
      const out: Record<string, SyncClaim> = {};
      for (const [id, value] of Object.entries(raw)) {
        if (!value || typeof value !== 'object') continue;
        const v = value as { target?: unknown; root?: unknown };
        if (typeof v.target === 'string' && typeof v.root === 'string') {
          out[id] = { target: v.target, root: v.root };
        }
      }
      return out;
    } catch {
      return {};
    }
  }

  private write(map: Record<string, SyncClaim>): void {
    mkdirSync(dirname(this.file()), { recursive: true });
    writeFileSync(this.file(), JSON.stringify(map));
  }

  /**
   * The id of a different vault already claiming this target, or null. A hit is
   * confirmable by the owner, not fatal: both folders then become one vault.
   */
  conflict(vaultId: string, endpoint: string, database: string): string | null {
    const key = targetKey(endpoint, database);
    for (const [id, value] of Object.entries(this.load())) {
      if (id !== vaultId && value.target === key) return id;
    }
    return null;
  }

  /**
   * The different vault whose folder is `vaultRoot`, or contains it, or sits
   * inside it — id and root — or null. Unlike `conflict` this has no override.
   */
  folderConflict(
    vaultId: string,
    vaultRoot: string,
  ): { vaultId: string; vaultRoot: string } | null {
    for (const [id, value] of Object.entries(this.load())) {
      if (id === vaultId) continue;
      if (foldersOverlap(vaultRoot, value.root)) {
        return { vaultId: id, vaultRoot: value.root };
      }
    }
    return null;
  }

  claim(vaultId: string, endpoint: string, database: string, vaultRoot: string): void {
    const map = this.load();
    map[vaultId] = { target: targetKey(endpoint, database), root: vaultRoot };
    this.write(map);
  }

  /**
   * Drop a vault's claim — on removal, or when a setup that had already claimed
   * fails before the vault is serving. A claim outliving its vault would make
   * that database look occupied forever.
   */
  release(vaultId: string): void {
    const map = this.load();
    if (delete map[vaultId]) {
      this.write(map);
    }
  }
}

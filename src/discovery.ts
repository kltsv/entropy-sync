import { existsSync, readFileSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';

// Discover an already-running daemon by reading the control endpoint it advertises
// (vault_sync_control R18, R20; mirrors the Dart ControlDiscovery). Lets the
// plugin attach to a live daemon without re-setup.

export interface ControlEndpoint {
  port: number;
  token: string;
}

export function discoveryDir(): string {
  return process.env.ENTROPY_SYNC_HOME ?? join(homedir(), '.entropy-sync');
}

export function discoverDaemon(dir: string = discoveryDir()): ControlEndpoint | null {
  const file = join(dir, 'control.json');
  if (!existsSync(file)) return null;
  try {
    const json = JSON.parse(readFileSync(file, 'utf8')) as {
      port: number;
      token: string;
    };
    return { port: json.port, token: json.token };
  } catch {
    return null;
  }
}

// The idempotent daemon-bootstrap decision (vault_sync_control R21), mirroring
// the Dart BootstrapPlanner. A running daemon at the right version is attached
// to, an old one upgraded in place, a missing one installed — never duplicated.
// The Obsidian front-end's install source is always a verified download (D11).

export type BootstrapAction = 'install' | 'upgrade' | 'start' | 'attach';
export type InstallSource = 'bundled' | 'download';
export type FrontEnd = 'app' | 'obsidian';

export interface BootstrapDecision {
  action: BootstrapAction;
  source?: InstallSource;
  verifyIntegrity: boolean;
}

export function planBootstrap(params: {
  running: boolean;
  installedVersion: string | null;
  requiredVersion: string;
  frontEnd: FrontEnd;
}): BootstrapDecision {
  const { running, installedVersion, requiredVersion, frontEnd } = params;
  const source: InstallSource = frontEnd === 'app' ? 'bundled' : 'download';
  const verifyIntegrity = source === 'download';

  if (running && installedVersion === requiredVersion) {
    return { action: 'attach', verifyIntegrity: false };
  }
  if (installedVersion === null) {
    return { action: 'install', source, verifyIntegrity };
  }
  if (installedVersion !== requiredVersion) {
    return { action: 'upgrade', source, verifyIntegrity };
  }
  return { action: 'start', verifyIntegrity: false };
}

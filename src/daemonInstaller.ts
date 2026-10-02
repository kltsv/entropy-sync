import { execFileSync } from 'child_process';
import { createHash, randomUUID } from 'crypto';
import { existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from 'fs';
import { dirname } from 'path';
import { downloadBytes } from './download';

// Installs/upgrades the entropyd binary for the Obsidian control plane
// (vault_sync_control R21, D11). The plugin DOWNLOADS the matching OS/arch binary
// from a public release channel and VERIFIES its integrity before installing —
// unlike the entropy app, which bundles it.

export interface ReleaseAsset {
  url: string;
  sha256: string;
  version: string;
}

export interface DaemonRelease { version: string; daemonVersion: string; baseUrl: string; assets: Record<string, string> }
declare const __SYNC_RELEASE__: DaemonRelease;
export const daemonRelease: DaemonRelease = typeof __SYNC_RELEASE__ === 'undefined'
  ? { version: 'development', daemonVersion: '0.2.0', baseUrl: '', assets: {} } : __SYNC_RELEASE__;

export function releaseAsset(release = daemonRelease, platform = process.platform, arch = process.arch): ReleaseAsset {
  const name = assetNameFor(platform, arch);
  const sha256 = release.assets[name];
  if (!release.baseUrl || !/^[a-f0-9]{64}$/.test(sha256 ?? '')) throw new Error(`This release has no verified daemon for ${platform}/${arch}.`);
  return { url: `${release.baseUrl}/${name}`, sha256, version: release.daemonVersion };
}

/** The release asset filename for this OS/architecture. */
export function assetNameFor(
  platform: NodeJS.Platform = process.platform,
  arch: string = process.arch,
): string {
  if (!['darwin', 'linux', 'win32'].includes(platform) || !['arm64', 'x64'].includes(arch) || (platform === 'win32' && arch !== 'x64')) {
    throw new Error(`Entropy Sync has no daemon for ${platform}/${arch}.`);
  }
  const os =
    platform === 'darwin' ? 'macos' : platform === 'win32' ? 'windows' : 'linux';
  const cpu = arch === 'arm64' ? 'arm64' : 'x64';
  const ext = platform === 'win32' ? '.exe' : '';
  return `entropyd-${os}-${cpu}${ext}`;
}

/** Download the binary and verify its sha256 before writing it (R21). */
export async function downloadAndVerify(
  asset: ReleaseAsset,
  destPath: string,
): Promise<void> {
  if (!/^[a-f0-9]{64}$/.test(asset.sha256)) throw new Error('Missing valid release checksum.');
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 120_000);
  const temporary = `${destPath}.${randomUUID()}.tmp`;
  try {
    const buffer = await downloadBytes(asset.url, controller.signal);
    const digest = createHash('sha256').update(buffer).digest('hex');
    if (digest !== asset.sha256) throw new Error(`Integrity check failed: expected ${asset.sha256}, got ${digest}`);
    mkdirSync(dirname(destPath), { recursive: true });
    writeFileSync(temporary, buffer, { flag: 'wx', mode: 0o755 });
    renameSync(temporary, destPath);
  } finally { clearTimeout(timeout); rmSync(temporary, { force: true }); }
}

/** The installed binary's version, or null if not installed. */
export function installedVersion(binPath: string): string | null {
  if (!existsSync(binPath)) return null;
  try {
    return execFileSync(binPath, ['--version']).toString().trim();
  } catch {
    return null;
  }
}

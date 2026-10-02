import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const pluginRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const packageRoot = join(pluginRoot, 'packages/entropy_daemon');
const os = { darwin: 'macos', linux: 'linux', win32: 'windows' }[process.platform];
if (!os || !['x64', 'arm64'].includes(process.arch) || (process.platform === 'win32' && process.arch !== 'x64')) throw new Error('Unsupported native build host');
export const asset = `entropyd-${os}-${process.arch}${process.platform === 'win32' ? '.exe' : ''}`;
export const binary = join(pluginRoot, 'bin', asset);
export function buildEngine() {
  const dart = process.env.SYNC_DART || 'dart';
  const options = { cwd: packageRoot, stdio: 'inherit', env: { ...process.env, CI: 'true' } };
  mkdirSync(dirname(binary), { recursive: true });
  execFileSync(dart, ['pub', 'get'], options);
  execFileSync(dart, ['compile', 'exe', 'bin/entropyd.dart', '-o', binary], options);
  const daemonVersion = execFileSync(binary, ['--version']).toString().trim();
  const version = JSON.parse(readFileSync(join(pluginRoot, 'manifest.json'), 'utf8')).version;
  if (daemonVersion !== version) throw new Error(`Manifest ${version} differs from daemon ${daemonVersion}`);
  const sha256 = createHash('sha256').update(readFileSync(binary)).digest('hex');
  writeFileSync(join(pluginRoot, 'bin', 'engine.json'), `${JSON.stringify({ daemonVersion, assets: { [asset]: sha256 } }, null, 2)}\n`);
  return { binary, asset, sha256 };
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) buildEngine();

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
const input = resolve(process.argv[2] ?? '.artifacts/native');
const output = resolve('dist/release');
const manifest = JSON.parse(readFileSync('manifest.json', 'utf8'));
const pkg = JSON.parse(readFileSync('package.json', 'utf8'));
if (manifest.version !== pkg.version) throw new Error('Manifest and package versions differ.');
if (process.env.GITHUB_REF_TYPE === 'tag' && process.env.GITHUB_REF_NAME !== manifest.version) throw new Error('Release tag must equal manifest version.');
mkdirSync(output, { recursive: true });
const assets = {};
for (const name of readdirSync(input).sort()) {
  if (!/^entropyd-(macos|linux|windows)-(arm64|x64)(\.exe)?$/.test(name)) continue;
  assets[name] = createHash('sha256').update(readFileSync(join(input, name))).digest('hex');
  cpSync(join(input, name), join(output, name));
}
const required = ["entropyd-macos-arm64", "entropyd-macos-x64", "entropyd-linux-arm64", "entropyd-linux-x64", "entropyd-windows-x64.exe"];
for (const name of required) if (!assets[name]) throw new Error(`Missing platform binary: ${name}`);
const metadata = { daemonVersion: manifest.version, assets };
writeFileSync('.release-assets.json', JSON.stringify(metadata));
execFileSync(process.execPath, ['node_modules/typescript/bin/tsc', '--noEmit'], { stdio: 'inherit' });
execFileSync(process.execPath, ['esbuild.config.mjs', 'production'], { stdio: 'inherit', env: { ...process.env, RELEASE_ASSETS: '.release-assets.json' } });
for (const name of ['main.js', 'manifest.json', 'styles.css']) cpSync(name, join(output, name));
writeFileSync(join(output, 'SHA256SUMS'), Object.entries(assets).map(([name, hash]) => `${hash}  ${name}`).join('\n')+'\n');
console.log(`BRAT release ${manifest.version}: ${output}`);

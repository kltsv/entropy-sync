import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const override = join(root, 'spec_sources_overrides.json');
const config = JSON.parse(readFileSync(existsSync(override) ? override : join(root, 'spec_sources.json'), 'utf8'));
const target = resolve(root, config.sources[0]);
const dependency = JSON.parse(readFileSync(join(root, 'history-dependency.json'), 'utf8'));
const pubspec = readFileSync(join(root, 'packages/entropy_daemon/pubspec.yaml'), 'utf8');
if (!pubspec.includes(`ref: ${dependency.ref}`) || !pubspec.includes(`url: ${dependency.url}`)) throw new Error('History metadata and daemon Git dependency differ.');
if (existsSync(override)) {
  if (!existsSync(join(target, 'app/vault_hist.md'))) throw new Error('Local History override is missing.');
} else {
  const git = (args) => execFileSync('git', args, { cwd: target, encoding: 'utf8' }).trim();
  if (!existsSync(join(target, '.git'))) {
    mkdirSync(dirname(target), { recursive: true });
    execFileSync('git', ['clone', dependency.url, target], { stdio: 'inherit' });
    git(['checkout', '--detach', dependency.ref]);
  }
  if (git(['rev-parse', 'HEAD']) !== dependency.ref || git(['status', '--porcelain'])) {
    throw new Error('History dependency is dirty or differs from its pin. Use a fresh .deps checkout or a local spec override.');
  }
}
console.log(`History specs and fixtures: ${target}`);

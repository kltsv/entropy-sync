import esbuild from 'esbuild';
import { existsSync, readFileSync } from 'node:fs';

const production = process.argv.includes('production');
const version = JSON.parse(readFileSync('manifest.json', 'utf8')).version;
const metadata = process.env.RELEASE_ASSETS ?? 'bin/engine.json';
const release = existsSync(metadata) ? JSON.parse(readFileSync(metadata, 'utf8')) : { assets: {}, daemonVersion: version };
if (process.env.RELEASE_ASSETS && (!Object.keys(release.assets).length || release.daemonVersion !== version)) throw new Error('Matching release assets are required.');
const context = await esbuild.context({
  entryPoints: ['src/main.ts'], bundle: true,
  external: ['obsidian', 'electron', 'node:*', 'fs', 'path', 'os', 'crypto', 'http', 'child_process'],
  format: 'cjs', target: 'es2020', platform: 'node',
  sourcemap: production ? false : 'inline', minify: production, outfile: 'main.js',
  define: { __SYNC_RELEASE__: JSON.stringify({ ...release, version, baseUrl: `https://github.com/kltsv/entropy-sync/releases/download/${version}` }) },
});
if (production) { await context.rebuild(); await context.dispose(); }
else await context.watch();

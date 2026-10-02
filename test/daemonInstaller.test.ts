import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { assetNameFor, downloadAndVerify, releaseAsset } from '../src/daemonInstaller';

test('release metadata selects exact OS/CPU digest and refuses unsupported hosts', () => {
  assert.equal(assetNameFor('darwin', 'arm64'), 'entropyd-macos-arm64');
  assert.equal(assetNameFor('darwin', 'x64'), 'entropyd-macos-x64');
  assert.equal(assetNameFor('linux', 'arm64'), 'entropyd-linux-arm64');
  assert.equal(assetNameFor('linux', 'x64'), 'entropyd-linux-x64');
  assert.equal(assetNameFor('win32', 'x64'), 'entropyd-windows-x64.exe');
  assert.throws(() => assetNameFor('aix', 'x64'), /no daemon/);
  assert.throws(() => assetNameFor('win32', 'arm64'), /no daemon/);
  const release = { version: '0.2.0', daemonVersion: '0.2.0', baseUrl: 'https://github.com/kltsv/entropy-sync/releases/download/0.2.0', assets: { 'entropyd-macos-arm64': 'a'.repeat(64) } };
  assert.deepEqual(releaseAsset(release, 'darwin', 'arm64'), { url: `${release.baseUrl}/entropyd-macos-arm64`, sha256: 'a'.repeat(64), version: '0.2.0' });
  assert.throws(() => releaseAsset(release, 'linux', 'x64'), /no verified daemon/);
});

test('download follows redirects, verifies bytes and atomically replaces; every failure keeps old binary', async () => {
  const root = mkdtempSync(join(tmpdir(), 'sync-installer-')); const dest = join(root, 'entropyd');
  const bytes = Buffer.from('new native daemon');
  const hash = createHash('sha256').update(bytes).digest('hex');
  const server = createServer((req, res) => {
    if (req.url === '/redirect') { res.writeHead(302, { location: '/asset' }); res.end(); }
    else if (req.url === '/asset') res.end(bytes);
    else { res.writeHead(404); res.end(); }
  });
  await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  try {
    writeFileSync(dest, 'old daemon');
    const asset = { url: `${base}/redirect`, sha256: hash, version: '0.2.0' };
    await assert.rejects(downloadAndVerify({ ...asset, sha256: '' }, dest), /checksum/);
    await assert.rejects(downloadAndVerify({ ...asset, sha256: 'a'.repeat(64) }, dest), /Integrity/);
    await assert.rejects(downloadAndVerify({ ...asset, url: `${base}/missing` }, dest), /404/);
    assert.equal(readFileSync(dest, 'utf8'), 'old daemon'); assert.deepEqual(readdirSync(root), ['entropyd']);
    await downloadAndVerify(asset, dest);
    assert.deepEqual(readFileSync(dest), bytes); assert.deepEqual(readdirSync(root), ['entropyd']);
  } finally { server.closeAllConnections(); await new Promise<void>(r => server.close(() => r())); rmSync(root, { recursive: true }); }
});

import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import {
  launchdPlist,
  linuxUnitPath,
  macPlistPath,
  registerAutostart,
  systemdUnit,
  unregisterAutostart,
  type Runner,
} from '../src/autostart';

class RecordingRunner implements Runner {
  calls: string[][] = [];
  run(executable: string, args: string[]): void {
    this.calls.push([executable, ...args]);
  }
  ran(executable: string, contains: string): boolean {
    return this.calls.some(
      (c) => c[0] === executable && c.some((a) => a.includes(contains)),
    );
  }
}

test('launchdPlist runs the daemon with run --state-root, run-at-load', () => {
  const plist = launchdPlist(
    '/opt/entropyd',
    ['run', '--state-root', '/home/u/.entropy-sync'],
    '/home/u/.entropy-sync',
  );
  assert.ok(plist.includes('/opt/entropyd'));
  assert.ok(plist.includes('<string>run</string>'));
  assert.ok(plist.includes('--state-root'));
  assert.ok(plist.includes('/home/u/.entropy-sync'));
  assert.ok(plist.includes('<key>RunAtLoad</key>'));
  assert.ok(plist.includes('<key>KeepAlive</key>'));
});

test('systemdUnit ExecStarts the daemon and installs to default target', () => {
  const unit = systemdUnit('/usr/bin/entropyd', [
    'run',
    '--state-root',
    '/home/u/.entropy-sync',
  ]);
  assert.ok(
    unit.includes(
      'ExecStart=/usr/bin/entropyd run --state-root /home/u/.entropy-sync',
    ),
  );
  assert.ok(unit.includes('WantedBy=default.target'));
});

test('macOS registration writes a plist and loads it', () => {
  const home = mkdtempSync(join(tmpdir(), 'autostart-'));
  try {
    const runner = new RecordingRunner();
    registerAutostart({
      binPath: '/opt/d',
      stateRoot: '/home/u/.entropy-sync',
      platform: 'darwin',
      home,
      runner,
    });
    assert.ok(existsSync(macPlistPath(home)));
    const plist = readFileSync(macPlistPath(home), 'utf8');
    assert.ok(plist.includes('/opt/d'));
    // The daemon CLI: `entropyd run --state-root <dir>` — the service
    // definition carries no per-vault config (the state root's registry does).
    assert.ok(plist.includes('<string>run</string>'));
    assert.ok(plist.includes('<string>--state-root</string>'));
    assert.ok(plist.includes('<string>/home/u/.entropy-sync</string>'));
    assert.ok(!plist.includes('--config'));
    assert.ok(runner.ran('launchctl', 'load'));
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('re-registering is idempotent (unloads before loading), then unregisters', () => {
  const home = mkdtempSync(join(tmpdir(), 'autostart-'));
  try {
    const runner = new RecordingRunner();
    const opts = {
      binPath: '/opt/d',
      stateRoot: '/home/u/.entropy-sync',
      platform: 'darwin' as const,
      home,
      runner,
    };
    registerAutostart(opts);
    registerAutostart(opts);
    assert.ok(runner.ran('launchctl', 'unload'));
    assert.ok(existsSync(macPlistPath(home)));

    unregisterAutostart({ platform: 'darwin', home, runner });
    assert.ok(!existsSync(macPlistPath(home)));
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('linux registration writes a systemd user unit and enables it', () => {
  const home = mkdtempSync(join(tmpdir(), 'autostart-'));
  try {
    const runner = new RecordingRunner();
    registerAutostart({
      binPath: '/usr/bin/entropyd',
      stateRoot: '/home/u/.entropy-sync',
      platform: 'linux',
      home,
      runner,
    });
    assert.ok(existsSync(linuxUnitPath(home)));
    const unit = readFileSync(linuxUnitPath(home), 'utf8');
    assert.ok(unit.includes('run --state-root /home/u/.entropy-sync'));
    assert.ok(runner.ran('systemctl', 'enable'));
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

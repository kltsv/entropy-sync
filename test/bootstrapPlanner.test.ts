import assert from 'node:assert/strict';
import { test } from 'node:test';

import { planBootstrap } from '../src/bootstrapPlanner';

test('with no daemon present, bootstrap installs (obsidian downloads+verifies)', () => {
  const d = planBootstrap({
    running: false,
    installedVersion: null,
    requiredVersion: '1.0.0',
    frontEnd: 'obsidian',
  });
  assert.equal(d.action, 'install');
  assert.equal(d.source, 'download');
  assert.equal(d.verifyIntegrity, true);
});

test('an already-running daemon is attached to, never duplicated', () => {
  const d = planBootstrap({
    running: true,
    installedVersion: '1.0.0',
    requiredVersion: '1.0.0',
    frontEnd: 'obsidian',
  });
  assert.equal(d.action, 'attach');
});

test('an out-of-date installed daemon is upgraded, not duplicated', () => {
  const d = planBootstrap({
    running: false,
    installedVersion: '0.9.0',
    requiredVersion: '1.0.0',
    frontEnd: 'obsidian',
  });
  assert.equal(d.action, 'upgrade');
  assert.equal(d.source, 'download');
});

test('the app front-end uses a bundled binary with no integrity download', () => {
  const d = planBootstrap({
    running: false,
    installedVersion: null,
    requiredVersion: '1.0.0',
    frontEnd: 'app',
  });
  assert.equal(d.source, 'bundled');
  assert.equal(d.verifyIntegrity, false);
});

import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { SyncTargetRegistry, foldersOverlap, targetKey } from '../src/targetRegistry';

test('targetKey normalizes endpoint (trailing slash + case) and keeps database', () => {
  assert.equal(targetKey('https://Srv/', 'vault'), 'https://srv::vault');
  assert.equal(targetKey('https://srv', 'vault'), 'https://srv::vault');
  assert.notEqual(targetKey('https://srv', 'a'), targetKey('https://srv', 'b'));
});

test('conflict detects a different vault claiming the same target', () => {
  const dir = mkdtempSync(join(tmpdir(), 'targets-'));
  try {
    const reg = new SyncTargetRegistry(dir);
    reg.claim('A', 'https://s', 'shared', '/vaults/a');

    assert.equal(reg.conflict('B', 'https://s', 'shared'), 'A'); // collision
    assert.equal(reg.conflict('A', 'https://s', 'shared'), null); // self ok
    assert.equal(reg.conflict('B', 'https://s', 'other'), null); // other db ok
    assert.equal(reg.conflict('B', 'https://S/', 'shared'), 'A'); // normalized
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('release drops a claim so the target is free again', () => {
  const dir = mkdtempSync(join(tmpdir(), 'targets-'));
  try {
    const reg = new SyncTargetRegistry(dir);
    reg.claim('A', 'https://s', 'shared', '/vaults/a');
    reg.release('A');
    assert.equal(reg.conflict('B', 'https://s', 'shared'), null);
    assert.equal(reg.folderConflict('B', '/vaults/a'), null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('foldersOverlap is symmetric and path-normalized (mirrors the Dart port)', () => {
  assert.equal(foldersOverlap('/a/b', '/a/b'), true);
  assert.equal(foldersOverlap('/a/b', '/a/b/c'), true);
  assert.equal(foldersOverlap('/a/b/c', '/a/b'), true);
  assert.equal(foldersOverlap('/a/b', '/a/bc'), false);
  assert.equal(foldersOverlap('/a/b', '/a/c'), false);
  assert.equal(foldersOverlap('/a/b/', '/a/./b'), true); // raw paths resolve
});

test('folderConflict catches the same folder and nesting either way', () => {
  const dir = mkdtempSync(join(tmpdir(), 'targets-'));
  try {
    const reg = new SyncTargetRegistry(dir);
    reg.claim('A', 'https://s', 'dbA', '/vaults/a');

    assert.equal(reg.folderConflict('B', '/vaults/a')?.vaultId, 'A'); // same
    assert.equal(reg.folderConflict('B', '/vaults/a/notes')?.vaultId, 'A'); // inside
    assert.equal(reg.folderConflict('B', '/vaults')?.vaultId, 'A'); // contains
    assert.equal(reg.folderConflict('B', '/vaults/b'), null); // sibling ok
    assert.equal(reg.folderConflict('A', '/vaults/a'), null); // self ok
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});


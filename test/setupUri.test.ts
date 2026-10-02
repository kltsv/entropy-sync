import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  decodeSetupUri,
  encodeSetupUri,
  setupUriCarriesSecret,
} from '../src/setupUri';

// A real setup-URI produced by the Dart `entropyd setup-uri --split` (transfer secret
// "code123"). Decoding it here proves the TypeScript and Dart front-ends share
// one byte-for-byte E2EE format — a URI from either works in the other.
const DART_FIXTURE =
  'entropy-sync://setup#YUpvVSt0TkpWSmxqdzlDODc5dnVYQnp5YlBkK0x6YlhYaUlPVEtXTk1iYndOS2lUS3NjVVE3SWVWSXI0TmprL05wcGdvTFFMNWxqaFIxUlh3SkNabFhzOStkNjhxSWFCN0REV2lvS0VUR3BKcEdnb3FhYzJ4c1BvbXViTXhHQjM2MjJQMWlRWnVHYTNNeG5nbldsZUFrcXU1NTRZNGxXS3IzNU1LK2xjaUcrUmc5SXBOd0E9';

test('decodes a setup-URI produced by the Dart front-end (cross-language E2EE)', () => {
  const conn = decodeSetupUri(DART_FIXTURE, 'code123');
  assert.equal(conn.endpoint, 'https://server.example');
  assert.equal(conn.database, 'vault');
  assert.equal(conn.serverUser, 'admin');
  assert.equal(conn.serverPassword, 'server-pw');
});

test('a wrong transfer secret is rejected', () => {
  assert.throws(() => decodeSetupUri(DART_FIXTURE, 'WRONG'));
});

test('a malformed URI is rejected', () => {
  assert.throws(() => decodeSetupUri('not-a-uri', 'code123'));
});

test('round-trips its own encoding', () => {
  const conn = {
    endpoint: 'https://server.example',
    database: 'notes',
    serverUser: 'user',
    serverPassword: 's3cr3t-pw',
  };
  const uri = encodeSetupUri(conn, 'transfer-code');
  assert.deepEqual(decodeSetupUri(uri, 'transfer-code'), conn);
});

test('a string carrying its own secret decodes with no second argument', () => {
  const connection = {
    endpoint: 'https://sync.example.com',
    database: 'vault',
    serverUser: 'entropy',
    serverPassword: 'pw',
  };
  const combined = encodeSetupUri(connection, 'abcd-efgh-jkmn-pqrs');
  assert.ok(setupUriCarriesSecret(combined));
  assert.deepEqual(decodeSetupUri(combined), connection);

  // The split form: same URI without its secret, secret supplied apart.
  const bare = encodeSetupUri(connection, 'abcd-efgh-jkmn-pqrs', {
    embedSecret: false,
  });
  assert.equal(setupUriCarriesSecret(bare), false);
  assert.deepEqual(decodeSetupUri(bare, 'abcd-efgh-jkmn-pqrs'), connection);
  assert.throws(() => decodeSetupUri(bare), /no transfer secret/);
  assert.throws(() => decodeSetupUri(combined, 'wrong'), /wrong transfer secret/);
});

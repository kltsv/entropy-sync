import { createDecipheriv, createCipheriv, pbkdf2Sync, randomBytes } from 'crypto';

import type { SetupConnection } from './types';

// The setup-URI codec (vault_sync_control D9), byte-for-byte compatible with the
// Dart `SetupUri` / `AesVaultCipher` so a URI produced by either front-end works
// in the other. Format:
//
//   entropy-sync://setup#<base64url( utf8( base64(nonce ‖ ct ‖ tag) ) )>[~<secret>]
//
// The transfer secret rides inside the string by default (one paste, one
// field); the split form — the URI alone plus the secret supplied separately —
// stays supported for a real second channel.
//
// The inner blob is AES-256-GCM of the connection JSON, keyed by
// PBKDF2(HMAC-SHA256, 120k, salt="entropy-sync-v1-vault-salt") over the transfer
// secret. The 12-byte nonce is random; the 16-byte GCM tag is appended.

const SCHEME = 'entropy-sync';
// Not in the base64url alphabet, so it can never occur inside the payload.
const SECRET_SEPARATOR = '~';

/** Split a pasted string into its URI and the secret it carries, if any. */
export function splitSetupUri(input: string): {
  uri: string;
  transferSecret: string | null;
} {
  const trimmed = input.trim();
  const at = trimmed.indexOf(SECRET_SEPARATOR);
  if (at < 0) return { uri: trimmed, transferSecret: null };
  const secret = trimmed.slice(at + 1).trim();
  return {
    uri: trimmed.slice(0, at),
    transferSecret: secret.length > 0 ? secret : null,
  };
}

/** Whether a pasted string already carries its transfer secret. */
export function setupUriCarriesSecret(input: string): boolean {
  return splitSetupUri(input).transferSecret !== null;
}
const SALT = 'entropy-sync-v1-vault-salt';
const ITERATIONS = 120000;
const KEY_BYTES = 32;
const NONCE_BYTES = 12;
const TAG_BYTES = 16;

function deriveKey(transferSecret: string): Buffer {
  return pbkdf2Sync(
    Buffer.from(transferSecret, 'utf8'),
    Buffer.from(SALT, 'utf8'),
    ITERATIONS,
    KEY_BYTES,
    'sha256',
  );
}

export function encodeSetupUri(
  connection: SetupConnection,
  transferSecret: string,
  { embedSecret = true }: { embedSecret?: boolean } = {},
): string {
  const key = deriveKey(transferSecret);
  const nonce = randomBytes(NONCE_BYTES);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  const payload = Buffer.from(JSON.stringify(connection), 'utf8');
  const ct = Buffer.concat([cipher.update(payload), cipher.final()]);
  const tag = cipher.getAuthTag();
  const blob = Buffer.concat([nonce, ct, tag]).toString('base64');
  const fragment = Buffer.from(blob, 'utf8').toString('base64url');
  const uri = `${SCHEME}://setup#${fragment}`;
  return embedSecret ? `${uri}${SECRET_SEPARATOR}${transferSecret}` : uri;
}

export function decodeSetupUri(
  input: string,
  transferSecret?: string,
): SetupConnection {
  const split = splitSetupUri(input);
  const secret =
    transferSecret && transferSecret.trim().length > 0
      ? transferSecret.trim()
      : split.transferSecret;
  if (!secret) throw new Error('setup-URI has no transfer secret');
  const url = new URL(split.uri);
  if (url.protocol !== `${SCHEME}:` || !url.hash || url.hash.length < 2) {
    throw new Error('not a valid setup-URI');
  }
  const fragment = url.hash.slice(1); // strip '#'
  const blob = Buffer.from(fragment, 'base64url').toString('utf8');
  const bytes = Buffer.from(blob, 'base64');
  const nonce = bytes.subarray(0, NONCE_BYTES);
  const tag = bytes.subarray(bytes.length - TAG_BYTES);
  const ct = bytes.subarray(NONCE_BYTES, bytes.length - TAG_BYTES);

  const key = deriveKey(secret);
  const decipher = createDecipheriv('aes-256-gcm', key, nonce);
  decipher.setAuthTag(tag);
  let plaintext: Buffer;
  try {
    plaintext = Buffer.concat([decipher.update(ct), decipher.final()]);
  } catch {
    throw new Error('wrong transfer secret or corrupt setup-URI');
  }
  return JSON.parse(plaintext.toString('utf8')) as SetupConnection;
}

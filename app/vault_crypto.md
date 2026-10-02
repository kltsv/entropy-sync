---
name: vault_crypto
description: The E2EE module — a pure transformation between logical vault documents (path, bytes, mtime) and wire documents (HMAC path id, AES-256-GCM framed body, STREAM-encrypted attachment), with Argon2id/HKDF key derivation from one passphrase and an open per-database meta document for salt, KDF parameters, and passphrase verification.
status: draft
---

# Vault crypto

## Purpose

The server must never see vault content **or file names**: it stores only
ciphertext, and anyone who compromises it learns nothing but sizes and timing
(R5, C3). This module is the end-to-end encryption layer that guarantees that —
a **pure transformation** between what the shells and `vault_hist` see (the
**logical document**: a real file's path, bytes, and mtime) and what
`vault_sync` replicates (the **wire document**: an opaque id, an encrypted
body, an encrypted attachment) (RV1, RV2).

It is one of the three independent modules: it knows nothing about replication
and nothing about history. The shells (desktop daemon, Flutter app) compose it
between the vault and the sync core; removing or replacing it must not touch
either neighbour (RV1).

## Inputs

- **The passphrase**, entered once per device by the owner, held by the shell
  in the OS secret store (macOS Keychain; Android/iOS secure storage) — never
  in plain config, never inside the vault, never on the server (R23, C11).
- **The `meta` document** of the target database (or none, on first
  initialization): the single plaintext document holding the KDF salt and
  parameters and a passphrase check value (RV3).
- **Logical documents** to encrypt: `{path, bytes, mtime, deleted}` — path is
  vault-relative with `/` separators, Unicode NFC, case-sensitive; bytes are
  the file content as-is (markdown is UTF-8; binaries are bytes); mtime is UTC
  epoch milliseconds.
- **Wire documents** to decrypt: `{id, body, attachment-stream?, deleted}` as
  produced by any client of the same vault.
- **Configuration**: the inline-size threshold (default 1 MiB).

## Outputs

- **Key material** derived from the passphrase (kept in memory by the shell's
  process; derivation is expensive and done once per device per vault).
- **A new or verified `meta` document**: created on first init; on later
  inits, the passphrase is verified against the existing check value, and
  overwriting an existing `meta` is **refused** (RV3).
- **Wire documents** from logical ones, and **logical documents** from wire
  ones — byte-faithful round trips.
- **Streamed ciphertext / plaintext** for attachment-sized content, produced
  and consumed in constant memory (RV3).
- **Typed failures**: a wrong passphrase is a clean verification error (from
  the `meta` check) or an authenticated-decryption error — never silently
  corrupt plaintext.

## Behavior

### Logical ⇄ wire (RV2)

One vault file maps to one wire document:

- **`id` = lowercase hex of `HMAC-SHA256(k_id, path-bytes)`** — 64 hex
  characters, deterministic and **one-way**. Determinism is what makes
  multi-master possible: every client independently maps the same path to the
  same document id with no coordination. One-wayness means the id reveals
  nothing; the path travels only **inside** the encrypted frame and is
  recovered from there on decrypt (RV2). Path bytes are UTF-8 of the
  canonical path (vault-relative, `/`, NFC, case preserved).
- **`body` = `{v: 1, n: base64(nonce), c: base64(ciphertext)}`** — AES-256-GCM
  under `k_body` with a fresh random 96-bit nonce per encryption and
  **AAD = the wire id** (UTF-8), binding each ciphertext to its document so a
  ciphertext cannot be transplanted under another id. The GCM tag is appended
  to the ciphertext inside `c`. `v` versions the scheme for future migration.
- **The plaintext of `c` is a binary frame**:
  `u32 big-endian header length ‖ header JSON (UTF-8) ‖ content bytes`.
  The header is `{path, mtime, size, inline}`. If `size ≤` the inline
  threshold (default 1 MiB), the content bytes follow in the frame and there
  is no attachment; otherwise the frame carries no content and the bytes ride
  as the encrypted attachment. The threshold is **by size, not by file type**:
  after encryption everything is bytes, and distinguishing text from binary at
  this layer would only leak (RV2).
- **The attachment** (only for large content) is the STREAM ciphertext (below)
  under the fixed name `data` with content type `application/octet-stream` —
  the real type is never sent (RV2).
- **Deletion** maps to a deleted revision of the same HMAC id, no body. The
  fact that *something* was deleted is inside the accepted leakage budget.
- **mtime, path, and size cross the wire only inside the encrypted frame** —
  never as plaintext fields.

### Keys (RV3)

- `master = Argon2id(passphrase, salt)` with `m = 64 MiB, t = 3, p = 1` —
  acceptable on mobile, one-time per device per vault. The salt is random,
  per-vault, generated at first init.
- Subkeys via HKDF-SHA256 from `master`: `k_id` (info `"id"`), `k_body`
  (info `"body"`), `k_att` (info `"att"`).
- **The `meta` document** — fixed id `meta`, the **only plaintext document**
  in the database — holds `{v, kdf: {alg: "argon2id", salt, m, t, p},
  check: {n, c}}`, where the check value is `AES-256-GCM(k_body,
  "vault-sync-check")` with AAD `"meta"`. The first device's `init` generates
  the salt and writes `meta`; every later device reads it, derives keys with
  the stored parameters, and verifies the passphrase against the check value
  **before any sync runs**. `init` against a database that already has a
  `meta` never overwrites it.
- **An empty passphrase is refused** — by the module itself, so every shell
  inherits the refusal. There is no "sync without encryption" mode to opt into:
  everything crossing the wire goes through this module. An empty passphrase
  would not disable encryption, it would derive the key from the empty string
  plus the salt and parameters that sit in the **public** `meta` document —
  ciphertext anyone can decrypt, which is worse than either honest option, so
  `init` rejects it outright.
- **Passphrase change = re-encrypting everything = a new database + full
  rescan** by the shells. There is no key-rotation mechanism (RV3).
- Crypto primitives come from an audited Dart package (e.g. `cryptography`),
  never hand-rolled.

### Streaming attachment encryption (RV3)

Large content is encrypted **by chunks in constant memory** — on a phone,
never holding the file whole:

- The construction is **STREAM** (the segmented-AEAD scheme used by age and
  Tink's `AesGcmHkdfStreaming`) — an existing, analyzed construction, adopted
  as-is, not invented here (RV3).
- Layout: `16-byte random key salt ‖ 4-byte random nonce prefix ‖ segments`.
  A per-attachment key is `HKDF-SHA256(k_att, salt = key salt,
  info = "entropy-sync/att" ‖ 0x00 ‖ UTF-8 wire id)` — the document id in
  the key derivation **binds the attachment to its document**: ciphertext
  served under any other id derives a different key and fails segment
  authentication, so a hostile server cannot swap the encrypted attachments
  of two documents, equal sizes included. Each segment is AES-256-GCM over
  up to
  **64 KiB** of plaintext; the segment nonce is
  `nonce prefix (4 B) ‖ segment counter (7 B, big-endian) ‖ final flag (1 B)`.
  The final segment (and only it) sets the flag.
- Decryption enforces the counter sequence and the final flag: truncation,
  reordering, duplication, or tampering of any segment fails loudly. A short
  final read without the flag is an error, not a short file.
- Both directions are `Stream<bytes> → Stream<bytes>` with per-segment peak
  memory: incoming chunks are segmented in place, never copied wholesale
  into a second whole-input buffer.
- The module also offers a **streamed logical → wire path** taking
  `{path, mtime, size, open-content stream}`: above the inline threshold the
  wire body is built from the header alone and the content is piped through
  the id-bound STREAM cipher lazily — the shell never holds the file whole;
  at or below the threshold the content is buffered (bounded by the
  threshold) and sealed inline, identically to the byte-based path. A
  content stream that contradicts the declared size is a typed error, never
  a header that lies.

### What leaks, and is accepted (RV2)

The server sees: the number of documents, ciphertext sizes, times and
frequency of changes, deletion facts, attachment sizes. It cannot see:
content, paths, file types. Consequence, accepted deliberately: the server
**cannot filter by path** — e.g. it cannot exclude `.hist/` for a phone;
every client pulls everything. If that volume ever matters, a plaintext
`kind` field could be added to the wire document at the cost of leaking which
documents are history — explicitly **not built now** (RV2).

### Failure modes

- Wrong passphrase on a later device: the `meta` check value fails to decrypt
  → a typed verification error before any document is touched.
- Tampered or transplanted ciphertext: GCM authentication (body, with its AAD
  binding) or STREAM verification (attachment, with its id-bound key —
  including an attachment swapped from another document of the **same
  size**) fails → a typed decrypt error; nothing partial is emitted.
- A `meta` written by a different passphrase generation (after a passphrase
  change created a new database) never mixes: the database is new by
  definition.

## Non-goals

- **No storage, no transport, no replication** — pure transformation;
  `vault_sync` moves what this module produces (RV1).
- **No history awareness** — history files encrypt like any other logical
  document.
- **No key escrow, no key sync, no multi-key sharing** — one passphrase, one
  vault, one owner (R5).
- **No per-file keys, no key rotation** — passphrase change is a new database
  (RV3).
- **No compression** before encryption (compression oracles trade size for
  leakage; content is small).
- **No self-invented primitives or constructions** — standard AES-GCM, HKDF,
  Argon2id, and the published STREAM construction only (RV3).
- **Does not choose where keys rest** — the shell owns the OS secret store
  (R23, C11); this module receives the passphrase/keys in memory.

## Examples

### One file, one deterministic id, opaque to the server (RV2)

`notes/plan.md`, 2 KiB, mtime `1788000000000`. Every device computes
`id = hex(HMAC-SHA256(k_id, "notes/plan.md"))` — the same 64-hex string. The
body's frame header is `{path: "notes/plan.md", mtime: 1788000000000,
size: 2048, inline: true}` followed by the content; the server stores
`{_id: "9c41…", body: {v: 1, n: "…", c: "…"}}` and learns nothing else.

### Large binary rides as a STREAM attachment (RV3)

`img/scan.pdf`, 8.4 MB. The frame says `{…, size: 8810214, inline: false}`
with no content; the bytes are encrypted as ~135 64-KiB STREAM segments and
travel as the `data` attachment. Decrypting on the phone streams segment by
segment; truncating the download fails verification rather than yielding a
short "valid" file.

### First device initializes, second verifies (RV3)

Device A runs init with passphrase P: generates a random salt, derives keys,
writes `meta` with the salt, Argon2id parameters, and the check value. Device
B connects, reads `meta`, derives keys from P and the stored salt, decrypts
the check value — match → sync proceeds. With a typo'd passphrase the check
fails and B reports "wrong passphrase" without pulling a single document.
A second `init` against the same database refuses to overwrite `meta`.

### Round trip is byte-faithful

`encrypt(logical)` then `decrypt(wire)` returns exactly the original path,
bytes, and mtime — including non-ASCII NFC paths and binary content with NUL
bytes. Two encryptions of the same document produce different ciphertexts
(fresh nonces) that decrypt to the same logical document.

### Ciphertext transplant is rejected

A hostile server moves document X's valid `body` under document Y's id. On
decrypt, the AAD (Y's id) does not match the one X was sealed with — GCM
authentication fails and the client reports tampering instead of writing X's
content to Y's path. Swapping the encrypted **attachments** of two documents
fails the same way — even when both plaintexts have identical byte lengths —
because the per-attachment key is derived with the owning document's id: the
swapped ciphertext fails at its first segment.

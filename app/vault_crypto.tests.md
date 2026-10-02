---
tests: vault_crypto
---

# Vault crypto — test-spec

Agnostic test cases for the `vault_crypto` module, in strict Arrange / Act /
Assert form. The module is a pure transformation — no storage, no transport —
so every case runs on in-memory documents and byte streams (RV1). Terms used
below:

- **crypto(P)** — an instance of the module holding key material derived from
  passphrase `P` (created by `init` on a fresh database, or by verifying `P`
  against an existing `meta`).
- **logical(path, bytes, mtime)** — a logical document
  `{path, bytes, mtime, deleted: false}`; path is vault-relative, `/`
  separators, Unicode NFC, case-sensitive; mtime is UTC epoch ms.
- **encrypt / decrypt** — the transformations logical → wire and
  wire → logical.
- **wire document** — `{id, body: {v, n, c}, attachment-stream?, deleted}`.
- **meta** — the database's single plaintext document (fixed id `meta`).

## Logical ⇄ wire round trip (RV2)

### a text file round-trips byte-faithfully

- **Arrange:** `crypto("P")` on a freshly initialized database;
  `logical("notes/plan.md", <UTF-8 markdown bytes>, 1788000000000)`.
- **Act:** `w = encrypt(l)`, then `l2 = decrypt(w)`.
- **Assert:** `l2.path` is exactly `notes/plan.md`, `l2.bytes` are
  byte-identical to the input, `l2.mtime` is `1788000000000`, and
  `l2.deleted` is false.

### binary content with NUL bytes round-trips

- **Arrange:** the same instance; `logical("img/logo.png", B, m)` where `B`
  contains runs of `0x00` and spans the full byte range.
- **Act:** encrypt, then decrypt.
- **Assert:** the recovered bytes are byte-identical, NULs included — nothing
  was treated as text or transcoded.

### a non-ASCII NFC path round-trips

- **Arrange:** `logical("заметки/café.md", …, …)` with the path in Unicode
  NFC.
- **Act:** encrypt, then decrypt.
- **Assert:** the recovered path is code-point-identical NFC
  `заметки/café.md` — case preserved, no normalization drift.

### two encryptions of one document differ, and both decrypt

- **Arrange:** one logical document.
- **Act:** encrypt it twice → `w1`, `w2`.
- **Assert:** `w1.body.n ≠ w2.body.n` (a fresh random 96-bit nonce each
  time) and `w1.body.c ≠ w2.body.c`; both decrypt to the identical logical
  document; `w1.id = w2.id` — determinism belongs to the id, randomness to
  the encryption.

## The document id (RV2)

### the id is deterministic across independent instances

- **Arrange:** two independently constructed instances from the same
  passphrase and the same `meta` (hence the same salt), with no shared state.
- **Act:** both compute the id for `notes/plan.md`.
- **Assert:** both produce the identical 64-character lowercase hex string —
  `hex(HMAC-SHA256(k_id, UTF-8 path bytes))`; a different path (even one
  character off) yields an entirely different id.

### the id is one-way — the path is recovered only from the decrypted frame

- **Arrange:** the wire document of `notes/plan.md`.
- **Act:** inspect every plaintext-visible part of the wire document; then
  decrypt it.
- **Assert:** no plaintext part contains the path, any substring of it, or
  any decodable form of it — the id is opaque hex; the path comes back
  **only** from the frame header inside the decrypted `c`.

## The frame and the inline threshold (RV2)

### the frame layout is u32 BE header length ‖ JSON header ‖ content

- **Arrange:** an instance whose derived keys the test can read; a small
  (inline-sized) logical document.
- **Act:** encrypt; then decrypt `body.c` directly with AES-256-GCM under
  `k_body`, nonce `body.n`, and AAD = the wire id.
- **Assert:** the plaintext begins with a 4-byte big-endian length `L`; the
  next `L` bytes parse as the JSON header
  `{path, mtime, size, inline: true}` with exactly the logical document's
  values; the remaining bytes are exactly the content and their count equals
  `size`.

### the inline threshold is by size, not type — and configurable

- **Arrange:** the threshold at its default 1 MiB; a 4 KiB binary file and a
  2 MiB markdown text file.
- **Act:** encrypt both; then reconfigure the threshold to 1 KiB and encrypt
  the 4 KiB binary again.
- **Assert:** at 1 MiB the tiny **binary** is inline (`inline: true`,
  content inside the frame, no attachment) while the large **text** file has
  `inline: false`, a frame with no content bytes, and the bytes riding as
  the attachment; at the 1 KiB threshold the same 4 KiB file now produces an
  attachment — the split follows size and configuration only, never content
  type.

### a deleted logical document becomes a wire tombstone with no body

- **Arrange:** `logical {path: "notes/gone.md", deleted: true}`.
- **Act:** encrypt.
- **Assert:** the wire document carries the same deterministic HMAC id a
  live `notes/gone.md` would have, `deleted: true`, and **no** body and no
  attachment — there is nothing to decrypt.

### the attachment name and content type are fixed

- **Arrange:** a large PDF file (above the threshold).
- **Act:** encrypt.
- **Assert:** the single attachment is named `data` with content type
  `application/octet-stream` — the real file type appears nowhere on the
  wire.

### path, mtime, and size never appear in plaintext outside the ciphertext

- **Arrange:** a logical document with a distinctive path, mtime, and size.
- **Act:** encrypt; serialize the entire wire document.
- **Assert:** outside the ciphertext in `body.c`, the serialization contains
  no occurrence of the path bytes, no field carrying the mtime, and no field
  carrying the plaintext size — those three cross the wire only inside the
  encrypted frame. (The observable ciphertext and attachment lengths are the
  accepted leakage budget.)

## AAD binding (RV2)

### a ciphertext transplanted under another id fails authentication

- **Arrange:** wire documents X and Y produced from two different paths under
  the same keys.
- **Act:** decrypt a forged document carrying Y's id with X's
  `body {v, n, c}`.
- **Assert:** authenticated decryption fails with a typed tamper error — the
  AAD (Y's id) is not the id X's body was sealed with; no partial or garbled
  logical document is emitted.

### equal-size attachments swapped between two documents fail decryption

- **Arrange:** two attachment-bearing documents A and B under the same keys
  whose plaintext byte lengths are **identical** (both above the inline
  threshold); their wire bodies untouched.
- **Act:** decrypt A's wire document supplying B's attachment ciphertext as
  its attachment, and vice versa — the hostile-server swap no length check
  can catch.
- **Assert:** both decryptions fail with a typed tamper error at the first
  segment — the per-attachment key is derived with the owning document's
  wire id, so the swap is rejected cryptographically; correctly paired, both
  documents still round-trip byte-faithfully.

## Keys and the meta document (RV3)

### first init generates a salt and writes meta with KDF parameters and a check value

- **Arrange:** a database with no `meta`; passphrase `P`.
- **Act:** `init`.
- **Assert:** a plaintext document with the fixed id `meta` now exists,
  holding `{v, kdf: {alg: "argon2id", salt, m, t, p}, check: {n, c}}` with
  `m = 64 MiB, t = 3, p = 1`; the salt is random per vault (a second init on
  a **different** empty database yields a different salt); the check value
  decrypts under `k_body` with AAD `"meta"` to the fixed check plaintext.

### a second device verifies the passphrase from meta before touching any document

- **Arrange:** a database initialized by device A with `P`, containing one
  document A encrypted; device B given `P` and the database's `meta`.
- **Act:** B derives keys using the salt and parameters stored in `meta` and
  verifies against the check value; then B decrypts A's document.
- **Assert:** verification succeeds using only `meta`; B recovers A's
  logical document exactly (the independently derived keys match A's); the
  verification needed no vault document.

### the wrong passphrase is a typed error and nothing is decrypted

- **Arrange:** the same database; device C given a typo'd passphrase.
- **Act:** C verifies against `meta`.
- **Assert:** a typed wrong-passphrase verification error is raised from the
  check value alone — before any vault document is fetched or decrypted; no
  partial plaintext of anything exists.

### init against an existing meta refuses to overwrite

- **Arrange:** the database with A's `meta`.
- **Act:** run `init` again (with the same or a different passphrase).
- **Assert:** the init is refused with a typed error and `meta` is
  byte-identical to before — never regenerated, never overwritten.

### Argon2id parameters and distinct HKDF subkeys

- **Arrange:** passphrase `P` and a fixed salt.
- **Act:** derive `master` and the subkeys.
- **Assert:** `master = Argon2id(P, salt)` with `m = 64 MiB, t = 3, p = 1`;
  `k_id`, `k_body`, `k_att` are derived via HKDF-SHA256 with infos `"id"`,
  `"body"`, `"att"` and are pairwise **different** byte strings — possessing
  one subkey is not possessing another (id-key compromise does not decrypt
  bodies).

## Streaming attachment encryption (RV3)

The streaming APIs are invoked with the owning document's wire id — the
per-attachment key derivation includes it.

### a multi-segment payload round-trips through the streaming API in constant memory

- **Arrange:** a payload of several hundred KiB — more than four 64 KiB
  segments plus a short tail — fed as a stream of small chunks.
- **Act:** run the encrypting stream over it, collecting the ciphertext; run
  the decrypting stream over that, collecting the plaintext.
- **Assert:** the plaintext is byte-identical to the payload; the ciphertext
  begins with the 16-byte random key salt and 4-byte random nonce prefix,
  followed by per-64 KiB segments; both directions emit output
  incrementally — the first decrypted segment is produced **before** the
  final ciphertext chunk is supplied — and neither direction ever holds more
  than one segment at a time.

### ciphertext decrypts only under the document id it was sealed for

- **Arrange:** a multi-segment attachment ciphertext sealed for document id
  D.
- **Act:** run the decrypting stream over it under a different document id.
- **Assert:** a typed tamper error at the first segment, before any
  plaintext is emitted — the derived key differs; under D the same
  ciphertext still decrypts byte-faithfully.

### streamed document encryption emits ciphertext before the content ends

- **Arrange:** a document above the inline threshold whose content arrives
  as a stream of small chunks; its path, mtime, and byte size are declared
  up front.
- **Act:** encrypt through the streamed logical → wire path, subscribing to
  the attachment ciphertext while feeding the content chunk-at-a-time.
- **Assert:** the wire document (its sealed body frame) exists before any
  content is consumed — it is built from the header alone; the first
  ciphertext segment is observed **before** the final content chunk is
  supplied — the content is never buffered whole; decrypting the wire
  document with the collected attachment reproduces the exact path, bytes,
  and mtime. Content at or below the threshold is buffered (bounded by the
  threshold) and sealed inline, identically to the byte-based path; a
  content stream that contradicts the declared size ends in a typed error.

### truncation fails loudly

- **Arrange:** a valid multi-segment ciphertext.
- **Act:** decrypt a copy with its trailing bytes cut off mid-segment.
- **Assert:** the decrypting stream ends in a typed verification error — not
  a shorter "valid" plaintext.

### segment reorder fails

- **Arrange:** a valid ciphertext of at least three segments.
- **Act:** swap two whole segments; decrypt.
- **Assert:** a typed verification error at the first out-of-order segment —
  the counter embedded in each segment nonce enforces the sequence.

### tampering with a segment fails

- **Arrange:** a valid multi-segment ciphertext.
- **Act:** flip one bit inside one segment; decrypt.
- **Assert:** a typed verification error at that segment; no plaintext for
  the tampered segment is emitted.

### a missing final segment is an error, not a short file

- **Arrange:** a valid ciphertext with its entire final segment removed, so
  the stream ends cleanly on a segment boundary.
- **Act:** decrypt.
- **Assert:** the stream completes with a typed error — the segment carrying
  the final flag never arrived — instead of yielding a shorter but seemingly
  valid file.

### an empty passphrase is refused, not treated as "no encryption"

- **Arrange:** a fresh database (no `meta`) and, separately, an existing one.
- **Act:** call init with an empty passphrase in both cases.
- **Assert:** both are refused with the typed wrong-passphrase error; no `meta`
  is generated and no key material is returned — there is no code path that
  produces plaintext documents.

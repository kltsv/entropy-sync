# entropy_sync

The pure-Dart sync library of the entropy-sync stack: the **two independent
modules** replication is made of — sync and crypto. No Flutter; `dart:io` is
allowed (file backends, HTTP), but hosts may inject their own
storage/transport. Reused verbatim by the desktop daemon (`entropy_daemon`)
and the Flutter app. Depends on no other entropy package; per-file history
is `entropy_hist`, a sibling this package neither imports nor is imported by.

The modules are deliberately **independent**: neither imports the other;
every arrow between them goes through a shell (the daemon or the app). That
is what lets each be tested alone and replaced alone (spec `vault_sync` RV1).

## Shape

- `lib/src/sync/` — `implements: vault_sync`. The document-**opaque** CouchDB
  replication client: revision trees with **random** rev ids, the winner
  algorithm, an offline-first `LocalStore` over an injected `StorageBackend` +
  digest-keyed `BlobStore`, the full replication protocol (longpoll `_changes`
  with `style=all_docs`, `_revs_diff`, `_bulk_get` / `_bulk_docs`
  `new_edits:false`, `multipart/related` streamed attachments, **local-only**
  checkpoints), and the continuous `SyncEngine` (start/stop, change stream
  with `origin`, conflict stream, status stream, idempotent `resolve`). It
  never sees plaintext or paths — in production everything through it is
  ciphertext, and it neither knows nor cares.
- `lib/src/crypto/` — `implements: vault_crypto`. E2EE as a pure
  transformation: HMAC-SHA256 path ids, `{v, n, c}` framed AES-256-GCM bodies
  (AAD = id), STREAM-chunked attachment encryption, Argon2id + HKDF key
  derivation, and the plaintext `meta` document (salt, KDF params, passphrase
  check). Knows nothing about replication or history.
- `lib/testing.dart` — the in-memory Couch emulator, serving real HTTP so the
  real transport is exercised end-to-end by this package's tests, the
  daemon's and the front-ends'.

## Key design choices

- **Sync is opaque** (RV1): the replica stores wire docs; the shells compose
  `vault_crypto` between the vault files and the sync core. There is no
  crypto decorator inside the sync layer.
- **Random revision ids** (RV4): rev hashes are 32 random hex chars — nothing
  content-derived ever reaches the server. The same edit made on two devices
  becomes a benign same-content conflict, resolved deterministically.
- **The winner is a pure function of the tree** (live > deleted, then higher
  generation, then lexicographically greater hash) — identical on every
  replica and the server.
- **Checkpoints are local-only** (RV4): no server `_local/` documents.

## Verify

```
dart pub get && dart analyze && dart test
```

Integration against a real CouchDB HTTP surface lives in `entropy_daemon`'s
tests (the emulator here serves real HTTP to this package's transport).

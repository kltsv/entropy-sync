# entropy_daemon

The headless desktop daemon (`entropyd`) of the entropy-sync stack.
`implements: vault_daemon`. A **thin shell** over the three independent
core modules (RV1): it owns each vault folder, composes `vault_crypto` between
the files and the document-opaque `vault_sync` replica, records this machine's
edits to multi-writer `vault_hist`, serves multiple vaults, and exposes an
authenticated localhost control channel that interchangeable front-ends share.

## Shape

- `lib/src/config.dart` — `VaultProfile` (per-vault modules, connection and
  tuning, R23, `daemon-modules` R1/R8); secrets are hydrated in memory,
  never persisted here, and only for a vault that enables sync. The Dart
  surface is flat; `toRegistryJson` writes the non-secret persisted form
  **per module** (`modules`, `folder`, `sync`, `history` blocks) — the
  registry's only shape, any other is refused — and `fromRegistryJson`
  reads it (the connection alone may arrive flat, a front-end's
  registration); `keep:` keeps every field a request omits (R10).
- `lib/src/vault_shell.dart` — `VaultShell`: one vault's **host** over the
  folder service, driving the vault's enabled modules — any subset. It
  neither walks nor writes the vault itself: it asks `VaultFolder` for what
  changed and routes each settled state **by its origin** — a *local* one
  goes to sync (encrypted and `put`) and is offered to history; a
  *materialized* one is adopted by history. Every arrow between modules goes
  through the host (sync reports "this state agreed with the replica" →
  history adopts; a losing binary → history rescues; a rename → both).
  Rename detection pairs the absent and appeared states of one pass by the
  folder's own previous hashes. A module that fails is **isolated** (R3):
  its error lands in `moduleErrors`, the others keep running, and status
  reports the vault degraded. Public accessors (`store`, `engine`,
  `hist`, …) reach into the modules for hosts and tests.
- `lib/src/modules/sync_module.dart` — `SyncModule`: replication. Encrypts
  local states into the document-opaque replica, decrypts and materializes
  winners **through** the folder service (atomic temp+rename, mtime, system
  trash for deletions), owns the replication checkpoint (`last_synced`) and
  the conflict machinery per RV9 (text: author already recorded; binary:
  handed to the host) + notification + log. Knows the folder and its
  `SyncHost`, never another module.
- `lib/src/modules/history_module.dart` — `HistoryModule`: records this
  machine's edits to `.hist/` via `HistWriter` + `HistCommitQueue`, adopts
  materializations, applies `.histignore` (read by the folder's engine),
  writes the rename marker pair, rescues a binary the host hands it, and
  keeps the divergence count. Runs with no sync present at all.
- `lib/src/vault_runtime.dart` — `VaultRuntime`: one served vault's
  continuous-mode unit — the shell plus the watcher subscription (raw events
  go to the folder service, which owns them; the per-path debounce decides
  when to ask it for the settled result) and the periodic-rescan timer. Owned by `Daemon`: created on
  `startContinuous`, disposed on stop/re-register, so an edited vault never
  leaves a stale watcher or timer driving a stopped shell. The watch stream
  is injectable (`VaultWatchFactory`); production uses `DirectoryWatcher`.
- `lib/src/daemon.dart` — `Daemon`: the single authoritative multi-vault
  service; idempotent `addVault`, same-(endpoint,database) refusal,
  `registerVault` (control-channel handoff: secrets → OS store, profile →
  registry, runtime replaced, no restart), runtime ownership per served
  vault, `resolveKeyMaterial` (the offline-first `meta` flow with
  corrupt-remote-falls-back-to-cache, RV3), and the `productionShell`
  factory.
- `lib/src/folder/` — **`implements: vault_folder`**, the single owner of a
  vault folder and the keystone of the module split (`app/vault_folder.md`).
  It watches, folds raw editor events into **settled states**, hashes them once,
  performs **every** write (atomic temp+rename; removals to the system trash),
  and publishes one stream of states each **attributed** — `LocalEdit`, or
  `Materialized(by:)` naming the module that asked. That attribution is the
  whole interface between modules: history commits `local` and adopts
  `materialized`, replication pushes `local` and ignores `materialized`, and
  **neither names the other**. Attribution is matched by content hash, so a
  slow watcher or a coalesced burst never turns a write into a phantom edit.
  `folder_cursor.dart` is the service's **own** record of what it last saw, so
  change detection works with one module enabled, both, or none — and it is
  the only change detection there is: `last_synced` keeps the replication
  checkpoint half (which revision each path's content corresponds to) and
  nothing else. `rescan()` reports one pass as a batch (a rename is a pair of
  states) with per-file failures reported rather than thrown; content above
  the inline limit is hashed from a stream and left on disk.
- `lib/src/hist_commit_queue.dart` — **when** an edit becomes a version
  (D7). `vault_hist` owns no timers, so the idle window lives here: states
  offered for a path accumulate and only the last one is committed once the
  path is quiet, and a local edit racing an arrival is committed *before* the
  arrival is applied. An arriving change is **never** committed — its own
  writer recorded it. A commit that fails stays pending and is retried on
  the next flush, so a history module that cannot write is degraded until
  it can, and no edit is silently dropped.
- `lib/src/vault_registry.dart` — the persisted **non-secret** vault registry
  (`<state-root>/vaults.json`).
- `lib/src/secret_store.dart` — Keychain (`security` CLI) + user-only file
  fallback, byte-compatible with the front-ends' secret files.
- `lib/src/last_synced.dart` — the persisted replication checkpoint. The
  RV8 **exclusion engine** lives in `entropy_hist`
  (`lib/src/exclusions/`), shared with the standalone history CLI: one `ExclusionMatcher` compiles every source through the
  documented gitignore subset (basename globs, anchored `/` paths, `dir/`,
  `*`/`**`; comments and `!` skipped), each source anchored at the directory
  its ignore file sits in. The **folder service** owns the rule files: it
  discovers `.syncignore` / `.histignore` at any depth during its walk (and
  from events and its own writes), re-reads them by mtime+size at the start
  of every pass, applies `.syncignore` itself, and hands `.histignore`
  sources to the shell (`ignoreSources`, keyed by `rulesVersion`). Nesting
  is additive. `.hist-state/` is a **built-in** folder exclusion no
  configuration removes. A path that *becomes* ignored has its cursor entry
  dropped without tombstoning, and remote changes for ignored paths are never
  materialized (a per-rules-generation memo keeps known-ignored docs
  undecrypted); conflict rescue bypasses `.histignore`.
- `lib/src/os_integration.dart` — system trash, OS notification, daemon log.
- `lib/src/transfer_cipher.dart` — the setup-URI transfer codec (D9),
  byte-compatible with the plugin's TS port; deliberately separate from vault
  E2EE.
- `lib/src/control_protocol.dart` / `control_server.dart` / `control_client.dart`
  — the localhost, token-authenticated control channel: status,
  pause/resume/sync-now, and `POST /vaults` (`AddVaultRequest`) for the
  front-end vault handoff; discovery file; Dart client.
- `lib/src/hub/` — **`implements: vault_sync_hub`**, the server half: a VPS as
  a managed object. `hub_registry.dart` persists the non-secret hub records
  (`<state-root>/hubs.json`); `ssh.dart` runs commands through the **system**
  SSH client, so no key is ever stored (authentication is the owner's agent or
  `~/.ssh/config`); `couch_admin.dart` reaches the hub's CouchDB **over SSH on
  its loopback**, reading the admin password out of the hub's own `.env` at use
  time and discarding it, so nothing about the hub survives locally;
  `hub_service.dart` is provisioning, databases and per-device grants (one
  device = one CouchDB user = one labelled setup-URI, revocable alone).
  `remote_setup_script.dart` is a **generated** verbatim copy of
  `tools/vps-provision/remote-setup.sh` (the recipe's source of truth) —
  regenerate with `dart run tool/sync_remote_setup.dart`; `test/hub/
  hub_script_test.dart` fails if the two drift.
- `bin/entropyd.dart` — the CLI (RV10), wrapped in `runZonedGuarded` so
  nothing escaping an unawaited future kills the daemon: `init` (hands off to
  a discoverable running daemon via `POST /vaults`; direct profile + secrets +
  `meta` + first scan only when none answers), `run` (serve the registry;
  continuous runtimes owned by `Daemon`), `status` (stale discovery → clean
  message + exit 1), `inspect [path]` (client-side decrypt-and-show),
  `hist [--vault-id] <verb> …` (the history command line of
  `entropy_hist` — `commit`/`log`/`show`/`restore`/`diff`/`blame`/`merge`/
  `status` — run over the vault's folder with its writer name),
  `config <vault-id> [changes…]` (read or change one
  vault's per-module configuration with no secrets and no re-registration
  — through the running daemon via `GET`/`PATCH /vaults/<id>/config`, else
  the registry; a history change is applied in place without touching
  sync, `daemon-modules` R9/R10), and `hub` (`add`/`list`/`remove`/`provision`, `db …`, `grant …` —
  the headless half of `vault_sync_hub`, so a server can be set up and granted
  from a script).

## Reconcile is poll-based; continuous mode adds longpoll

`VaultShell.reconcile()` (scan → sync → rescue → materialize → history flush)
is the deterministic, testable unit; `start()` adds the core engine's longpoll
pull and materializes remote changes as they arrive. On a fresh replica the
pass pulls **first** (D5 is scoped to an empty database — re-attach repairs
the cursor instead of reseeding). Passes serialize behind a per-shell async
mutex (concurrent reconcile requests coalesce). Echo loops are prevented by
the persisted `last_synced` cursor, which also records each path's replica
revision — the parent a racing edit branches from and the skip key that keeps
unchanged winners undecrypted. Wire ids are one-way HMACs, so the shell keeps
an id→path index (rebuilt from the cursor) to map tombstones back to files.

## Binary

Compiled to `tools/entropyd/entropyd` (gitignored), like the finance
CLI:

```
cd packages/entropy_daemon && dart compile exe bin/entropyd.dart \
  -o ../../tools/entropyd/entropyd
```

## Verify

```
dart pub get && dart analyze && dart test
```

The Couch emulator lives in `entropy_sync` (`lib/testing.dart`) and
serves real HTTP, so the real transport is exercised end-to-end. Live-CouchDB
verification against the VPS is manual (Appendix A).

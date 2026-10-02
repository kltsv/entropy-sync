---
tests: vault_daemon
---

# Vault sync daemon — test-spec

Agnostic test cases for the `vault_daemon` module, in strict Arrange / Act /
Assert form. Terms:

- **daemon** — a running daemon instance over a **fake server** (in-memory CouchDB
  double) and a real temp **vault folder** on disk.
- **secret store** — a fake OS secret store keyed by (vault, key).
- **init(vault, profile, passphrase)** — the daemon's `init` verb: store the
  profile, place secrets, establish `meta`, run the first scan.
- **connect(vault, profile)** — register an already-initialized vault with a
  running daemon.
- **settle** — let the daemon process pending file events / sync passes to
  quiescence.
- **control(cmd)** — issue a control command over the local channel presenting the
  daemon's token, unless stated otherwise.
- **last_synced** — the daemon's per-path record of what it last pushed or
  materialized (hash + mtime + size).

## Composing the modules (RV1)

### the replica and the server hold only wire documents; plaintext exists only as files

- **Arrange:** a connected vault with `secret.md` containing a distinctive
  plaintext marker string.
- **Act:** `settle`; then inspect the sync module's replica store and the fake
  server's stored documents.
- **Assert:** the marker appears nowhere in the replica or on the server — both
  hold wire (encrypted) documents only; the sole plaintext copy is the real file
  in the vault folder. Encryption sits between the folder and the sync core, not
  inside the sync layer.

## Init (D5, RV3, RV10)

### init on an empty database stores the profile, places secrets, and writes `meta`

- **Arrange:** a temp vault, an empty fake server database, an empty secret
  store.
- **Act:** `init` with a profile (endpoint, database, server credentials, writer
  name) and a passphrase.
- **Assert:** the profile lands in the daemon's per-vault state directory
  **outside** the vault; the passphrase and server password land in the secret
  store keyed by the vault — never inside the vault, never on the server; a
  single plaintext `meta` document (salt, KDF parameters, passphrase check
  value) is written to the empty database; the first scan runs.

### init on a populated database verifies the passphrase and refuses to overwrite `meta`

- **Arrange:** a database already carrying `meta` and synced documents (the
  "second machine" scenario).
- **Act:** `init` with the **correct** passphrase; `settle`.
- **Assert:** the passphrase is verified against `meta`'s check value **before
  any sync**; the existing `meta` is left untouched (`init` never overwrites
  it); replication then proceeds and the vault materializes.

### a wrong passphrase surfaces as the vault's error state and no sync runs

- **Arrange:** a database carrying `meta` written under a different passphrase.
- **Act:** `init` (or start the vault) with a typo'd passphrase; `settle`.
- **Assert:** the `meta` check fails; the vault enters the error state ("bad
  passphrase"), visible in status; **nothing is pulled, nothing is scanned,
  nothing is pushed**.

### a corrupt remote `meta` falls back to the valid cached copy

- **Arrange:** a provisioned device holding a verified cached `meta`; the
  server's `meta` is then mangled (check value corrupted).
- **Act:** resolve the key material with the correct passphrase; then again
  with a wrong passphrase.
- **Assert:** the correct passphrase resolves from the **cache** with a
  logged warning — the untrusted server cannot brick a provisioned device or
  fake a "wrong passphrase"; the genuinely wrong passphrase still fails as a
  crypto error (it fails against the cache too).

## First scan and folder ownership

### first scan is the initial sync: a clean replica pushes every file (D5, N8)

- **Arrange:** a temp vault with `a.md`, `notes/b.md`, and `img/c.png`; an empty
  fake server; no prior replica.
- **Act:** `connect` the vault and `settle`.
- **Assert:** the replica holds one wire document per file and the server
  receives all three as initial encrypted revisions — no migration step, no
  pre-existing database consulted; history begins now (no versions predate the
  scan).

### re-attaching a restored vault to a populated database repairs, not reseeds (D5 scope)

- **Arrange:** a populated database (another device pushed `same.md` and a
  multi-revision `edited.md`); a machine with the vault **files** but a fresh
  state directory: `same.md` identical to the server, `edited.md` carrying an
  offline edit, `new.md` unknown to the server.
- **Act:** `connect` and `settle`.
- **Assert:** the first reconcile pulls before scanning. `same.md` repairs
  the cursor — **no** revision minted, no same-content conflict, no
  notification. `new.md` pushes as a **real local edit**, recorded to history
  by this machine. `edited.md` meets the pulled winner in the conflict
  machinery: the offline edit is recorded to history, both versions survive,
  and every replica converges on one deterministic winner.

### the first scan into an empty database still seeds (D5)

- **Arrange:** a temp vault with `a.md`; an empty database; no prior replica.
- **Act:** `connect` and `settle`; then edit `a.md` and `settle`.
- **Assert:** the first scan pushes `a.md` as a single initial revision with
  a **baseline-only** history seed (no version recorded); the first real edit
  then anchors history as usual.

### an external file write becomes a pushed revision and a history record (S2, RV6)

- **Arrange:** a connected, settled vault with debounce set low; no front-end
  attached; the "editor" is not the daemon.
- **Act:** write `notes/todo.md` directly on disk (as the CLI/agent would) and
  `settle`.
- **Assert:** the daemon reads and hashes the file, sees it differs from
  `last_synced`, encrypts and `put`s a new wire revision (the server receives
  ciphertext), and calls `localState(notes/todo.md, content)` — a version
  appears under `.hist/notes/todo.md/` recorded by this machine.

### deleting a file pushes a delete and records absence (RV6)

- **Arrange:** a connected, settled vault with `a.md` synced.
- **Act:** delete `a.md` on disk; `settle`.
- **Assert:** the daemon issues a delete for the document (tombstone on the
  wire) and calls `localState(a.md, absent)` — history records the deletion.

## Local change detection (R10, RV4)

### rapid successive writes coalesce through the per-path debounce

- **Arrange:** a connected vault with the per-path debounce at its ~1–2 s
  default (set testably low).
- **Act:** write `foo.md` five times in quick succession within one debounce
  window; also write `bar.md` once during the same interval; `settle`.
- **Assert:** `foo.md` yields **one** pushed revision carrying the final
  content — not five; `bar.md` debounces independently (the window is per path,
  not global).

### unchanged files are skipped by the mtime+size fast path

- **Arrange:** a connected, settled vault with an observable content hasher.
- **Act:** trigger a full rescan with no file modified.
- **Assert:** no file content is read or hashed (mtime + size match
  `last_synced` for every path) and nothing is pushed.

### a touched-but-identical file is hashed once and not pushed

- **Arrange:** a settled vault; bump `a.md`'s mtime without changing its bytes.
- **Act:** `settle`.
- **Assert:** the changed mtime forces one content hash; the hash equals
  `last_synced`, so no revision is pushed and no history version is written.

### the startup scan catches edits made while the daemon was down

- **Arrange:** a connected, settled vault; stop the daemon; edit `a.md` and
  create `new.md` on disk.
- **Act:** start the daemon; `settle`.
- **Assert:** both disk ≠ `last_synced` differences are treated as local edits:
  encrypted, pushed, and recorded to history via `localState`.

### the periodic rescan catches events the watcher missed

- **Arrange:** a running vault whose watcher is suppressed (simulating a missed
  filesystem event); the rescan period set low.
- **Act:** write `b.md` directly on disk; wait past a rescan period; `settle`.
- **Assert:** the rescan detects disk ≠ `last_synced` and ingests the edit
  exactly as if the watcher had fired — pushed and history-recorded.

### a paused vault neither ingests nor pushes; resume catches up both ways

- **Arrange:** a running vault; pause it.
- **Act:** write a file and flush the watcher path; also call the ingest seam
  directly; land a remote change on the server; then resume and `settle`.
- **Assert:** while paused nothing was ingested and nothing reached the
  server; after resume one reconcile pushes the local edit **and**
  materializes the remote change that was skipped while paused.

### overlapping reconcile requests serialize and coalesce

- **Arrange:** a connected vault with one pending local edit.
- **Act:** request several reconciles concurrently; `settle`.
- **Assert:** a request issued while one is queued joins it (same pass); the
  passes never interleave — exactly **one** revision is minted for the edit
  and exactly one history version is recorded.

### a file above the inline threshold streams through ingestion

- **Arrange:** a connected vault with the inline threshold set small; a
  binary file larger than the threshold.
- **Act:** `settle`.
- **Assert:** the file is hashed and encrypted from a stream (the whole-bytes
  path is never fed the large content), rides as an encrypted attachment,
  round-trips byte-for-byte to a second device, and the cursor records its
  true content hash.

## Materializing remote changes (RV4)

### a remote change is materialized atomically with metadata and baseline updated

- **Arrange:** a connected, settled vault; a new revision of `x.md` lands on the
  fake server (from "another device").
- **Act:** `settle`.
- **Assert:** the file is written via a temp file in the same directory plus
  rename — an observer of the final path sees either the old or the complete new
  content, never a partial write; the file's mtime is set from the logical
  document; `last_synced` is updated; `remoteApplied(x.md, content)` is called
  on history — which records **no** version (receivers never record synced
  changes, RV6).

### a pulled revision does not echo back as a new edit

- **Arrange:** two daemons D1, D2 over the same fake server on two separate
  vault folders.
- **Act:** create `x.md` in D1's folder, `settle` both.
- **Assert:** `x.md` appears on disk in D2's folder with the same content; D2
  updated `last_synced` before its own write became visible, so the
  materialization does **not** enqueue a spurious push back to the server (no
  echo loop, no new revision minted for the pulled content).

### a local edit racing a pull is ingested first; the daemon never merges (R9)

- **Arrange:** a connected vault with a remote revision of `foo.md` pending;
  before materialization the on-disk `foo.md` is edited locally (disk hash ≠
  `last_synced` at materialization time).
- **Act:** `settle`.
- **Assert:** the local edit is ingested first — encrypted, pushed, and recorded
  via `localState` — and the two revisions meet in the server's conflict
  machinery; the daemon performs no content merge and the local edit is not
  lost.

### a remote winner never overwrites a cursor-less local file

- **Arrange:** two devices create the **same** path concurrently; on the
  second device the creation has not been ingested yet (no `last_synced`
  entry) when the first device's revision arrives.
- **Act:** the remote change materializes; `settle` both.
- **Assert:** the cursor-less file is treated as a racing local creation: its
  bytes are never overwritten, it is ingested and pushed, both contents
  survive (each in its author's history), and all replicas converge. The same
  guard holds for a remote **tombstone**: a cursor-less or locally-edited
  file is ingested, never trashed.

### an edit based on stale disk content becomes a sibling branch, not a fast-forward

- **Arrange:** a synced binary file; a remote edit is grafted as the new
  winner while a different local save has not flushed (continuous-mode
  ordering: graft first, then materialize).
- **Act:** the change materializes; `settle`.
- **Assert:** the local edit is ingested **parented on the cursor's recorded
  revision** — a sibling of the grafted winner, a real conflict — not a child
  of the fresh remote winner; the losing binary's bytes are rescued into
  history and the owner is notified. Neither edit is lost anywhere.

### an unchanged vault decrypts nothing on reconcile

- **Arrange:** a connected, settled vault (text and binary files) with an
  observable content hasher.
- **Act:** run a reconcile with nothing changed locally or remotely.
- **Assert:** the scan's mtime+size fast path reads no content and the
  materialize pass skips every document by its recorded winner revision — no
  content is hashed or decrypted.

### a remote deletion moves the file to the system trash

- **Arrange:** a connected vault with `gone.md` synced; the document is deleted
  on the fake server by "another device".
- **Act:** `settle`.
- **Assert:** `gone.md` leaves the vault into the **system trash** (recoverable,
  never irreversibly unlinked) and `remoteApplied(gone.md, absent)` is called;
  this daemon records no history version for the deletion.

## What is not synced (RV8)

### exclusion defaults are skipped by scan, watch, and history alike

- **Arrange:** a temp vault containing `.DS_Store`, `.trash/x.md`, `.git/HEAD`,
  `_workspace/notes.md`, `.obsidian/workspace.json`,
  `.obsidian/workspace-mobile.json`, a LiveSync plugin folder, and a
  Remotely-Save plugin folder — plus a real `note.md` and `.obsidian/app.json`.
- **Act:** `connect` and `settle`; then modify one excluded file and `settle`
  again.
- **Assert:** only `note.md` and `.obsidian/app.json` become synced documents
  (the default excludes `.obsidian/workspace*.json`, not all of `.obsidian/`);
  no excluded path is pushed, the later modification of an excluded file
  produces no push (not watched), and no excluded path gains history.

### `.hist/` is synced but never history-tracked

- **Arrange:** a vault whose `.hist/notes/a.md/` already holds version
  files.
- **Act:** `connect` and `settle`; then edit `notes/a.md` and wait past the
  debounce so the daemon writes a new history version.
- **Assert:** the `.hist/` files replicate to the server as ordinary
  encrypted documents (they ride the same layer); but **no** history is
  recorded *about* `.hist/` paths — no `.hist/.hist/…` entries and no
  `localState` calls for any path under `.hist/` (no history-of-history).

## Rename detection with marker linking (R16, RV7)

### a content-hash match within the window is a rename: wire tombstone + create, history marker pair

- **Arrange:** a connected vault with `notes/a.md` and existing versions under
  `.hist/notes/a.md/`.
- **Act:** within the debounce window, remove `notes/a.md` and create
  `notes/b.md` with the **same content**; `settle`.
- **Assert:** on the wire the old id is tombstoned and a new document is
  created (ids are path-derived; there is no "move" operation); in history,
  `.hist/notes/a.md/` gains a `deleted` marker carrying
  `renamed_to: notes/b.md` and `.hist/notes/b.md/` gains a `snapshot`
  carrying `renamed_from: notes/a.md`; **no history folder is moved or
  renamed** — the old folder keeps all its prior versions in place.

### no match degrades to delete + create without losing old history

- **Arrange:** a connected vault with `notes/a.md` (history present).
- **Act:** remove `notes/a.md`; later (outside the window, or with very
  different content) create `notes/b.md`; `settle`.
- **Assert:** `notes/a.md` is tombstoned and `.hist/notes/a.md/` is
  **preserved** in place (append-only); `notes/b.md` starts a fresh history
  root; no rename markers are written and no old history is lost.

### empty and ambiguous matches are never rename-paired

- **Arrange:** (a) an empty synced note is deleted while an unrelated empty
  note appears in the same window; (b) two identical synced notes are deleted
  while one file with the same content appears.
- **Act:** `settle` each case.
- **Assert:** both degrade to plain delete + create — no `renamed_to`/
  `renamed_from` markers anywhere: empty files are never paired, and a hash
  matching more than one candidate is never guessed at (a wrong marker pair
  would link unrelated files in append-only history forever).

## Conflicts (R9, RV9)

### a text conflict leaves the winner untouched and the daemon records nothing for the loser

- **Arrange:** two daemons over one server, both editing `plan.md` from a shared
  base while "offline" — each author's daemon recorded its own edit via
  `localState` before reconnecting.
- **Act:** reconnect and `settle` both.
- **Assert:** both vaults converge on the same deterministic (LWW) winner with
  the winner's bytes untouched — no auto-merge; **neither daemon writes a new
  history entry for the losing text** — the loser is already present as its
  author's recorded branch; no `.conflict` file exists in either vault.

### a binary conflict loser is rescued whole into history

- **Arrange:** the same two-daemon setup with a binary `img/logo.png` edited on
  both sides while offline.
- **Act:** reconnect and `settle` both.
- **Assert:** the winner's bytes stand; the losing binary's **full bytes** are
  written into `.hist/img/logo.png/` as a `conflict` rescue file (otherwise
  they would be gone forever); no `*.conflict` file appears in either vault.

### resolution is idempotent and the owner is notified

- **Arrange:** a conflict already handled once; the sync module replays the same
  `conflict(id, winner, losers)` event.
- **Act:** `settle`.
- **Assert:** the replay is a no-op — `resolve(id, loserRevs)` tolerates
  repetition and no duplicate rescue file is written; the daemon log carries a
  line recording the conflict and its resolution; an OS notification was
  emitted to the owner (once per conflict, not per replay).

### a transient rescue failure holds resolution and retries

- **Arrange:** a binary conflict whose losing revision's attachment bytes are
  unavailable (blob missing / IO failure).
- **Act:** the conflict is handled; then the bytes become available and it is
  handled again.
- **Assert:** the first attempt resolves **nothing** — no rescue file, no
  notification, the conflict stays live (resolving would tombstone bytes that
  were never saved); the retry rescues the full losing bytes into history,
  resolves, and notifies once.

### resolved conflicts drop off the status conflict list

- **Arrange:** a vault that hit a conflict which was rescued and resolved.
- **Act:** run the next reconcile; read status.
- **Assert:** the conflict list reflects the store's **current** conflicts —
  the resolved entry is gone (no unbounded accumulation for the life of the
  process).

## Multi-vault (R23)

### one daemon serves multiple vaults, isolated from each other

- **Arrange:** one daemon with two vaults V1, V2, each with its own profile and
  fake server DB.
- **Act:** edit a file in V1; pause V2; `settle`.
- **Assert:** V1's edit syncs to its own server DB; V2 does not sync while
  paused; neither vault's documents leak into the other's database; a fault or
  pause on one never stops the other.

### a second vault targeting the same (endpoint, database) is refused unless acknowledged

- **Arrange:** a daemon already serving vault V1 at some (endpoint, database).
- **Act:** add a *different* vault V2 whose profile targets the **same** endpoint
  and database, **without** the shared-database acknowledgement.
- **Assert:** registration is **rejected** with a clear error naming the
  conflict; V2 is not added and V1 keeps running unchanged. Adding V1 again
  (same vault) is still the idempotent attach, not a conflict, and needs no
  acknowledgement.

### an acknowledged shared database registers both vaults

- **Arrange:** a daemon already serving vault V1 at some (endpoint, database);
  V2 rooted at a **different, non-overlapping** folder.
- **Act:** add V2 targeting the **same** endpoint and database, **with** the
  shared-database acknowledgement.
- **Assert:** V2 is registered and served alongside V1; both run independently
  and neither is stopped or re-registered by the other. The two replicas carry
  **different replica ids**, so neither overwrites the other's checkpoint.

### a folder collision is refused even when the shared database is acknowledged

- **Arrange:** a daemon serving vault V1 at some (endpoint, database) and root.
- **Act:** add V2 targeting the same endpoint and database **and** rooted at
  V1's folder, **with** the shared-database acknowledgement.
- **Assert:** registration is still **rejected**, naming the *folder* conflict —
  the acknowledgement covers the database rule only and never the folder rule;
  nothing is registered and V1 is untouched.

### the database conflict is reported before the folder conflict

- **Arrange:** a daemon serving vault V1.
- **Act:** add V2 colliding on **both** the (endpoint, database) and the folder,
  with no acknowledgement.
- **Assert:** the error reported is the **database** conflict — the one the
  owner can act on — not the folder conflict.

## Control channel (R18, R19, R20)

### a front-end presenting the token reads status and issues commands

- **Arrange:** a running daemon with a token file readable only by the owner.
- **Act:** `control(status)` and `control(pause)` presenting the token.
- **Assert:** status is returned (per-vault running/paused/offline, last-sync
  time, un-synced count, error state, conflict list), and pause takes effect.

### an unauthenticated caller is refused

- **Arrange:** a running daemon.
- **Act:** call the control channel **without** the token.
- **Assert:** the call is rejected; it can neither read status nor
  start/stop/pause; the channel is bound to localhost only.

### two controllers see the same authoritative state

- **Arrange:** a running daemon with two attached controllers C1, C2.
- **Act:** C1 issues `pause`; then C2 reads status.
- **Assert:** C2 observes the paused state — the daemon is the single source of
  truth and a control action from one controller is reflected to the other.

### add-vault over the channel registers and serves without a restart (D10, R23)

- **Arrange:** a running daemon serving V1; a front-end has already placed a new
  vault V2's secrets in the secret store.
- **Act:** `control(add-vault)` with V2's **non-secret** profile; then edit a
  file in V2's folder and `settle`.
- **Assert:** the daemon registers V2 and starts serving it immediately — no
  daemon restart — and V2's edit syncs. Re-sending the same profile is the
  idempotent attach (no duplicate registration, no error), and an edit-vault
  command updates V2's profile in place.

### editing a vault replaces its whole runtime — no stale watcher survives

- **Arrange:** a served vault in continuous mode: shell + watcher + periodic
  rescan, owned by the daemon as one runtime.
- **Act:** edit the vault's profile over the control channel; then drive the
  **old** runtime's watcher flush and the **new** one.
- **Assert:** the old runtime was disposed — its flush is inert, nothing
  rides through the stale shell (which would encrypt with the old profile) —
  and the new runtime, wired to the new shell with a fresh watcher, ingests
  and pushes. A vault registered while the daemon runs gets a watcher and
  rescan the same way.

### the control channel carries no vault plaintext (C3)

- **Arrange:** a running daemon syncing an encrypted vault.
- **Act:** capture everything the control channel returns for status and
  commands.
- **Assert:** the payloads contain only control/status fields (states, counts,
  times, ids/paths for the conflict list as configured) — never document bodies
  or the passphrase; E2EE is not weakened by the channel.

### a second start attaches to the running daemon rather than duplicating it

- **Arrange:** a daemon already running for a vault.
- **Act:** request "start/bootstrap" again for the same vault.
- **Assert:** the existing instance is attached to (idempotent); no second
  daemon process is spawned and its status is unchanged/authoritative.

### the daemon keeps syncing with no controller attached

- **Arrange:** a running daemon, then detach all controllers.
- **Act:** write a file on disk and `settle`.
- **Assert:** the change still syncs to the server — the daemon runs
  independently of any front-end.

## Status and CLI (R17, RV10)

### status reports the real count of un-synced local changes

- **Arrange:** a connected vault whose fake server is unreachable (offline).
- **Act:** write three files; `settle` locally; read status; then restore
  connectivity and `settle`.
- **Assert:** while offline, status shows the vault offline with an un-synced
  count of **3** — the actual pending local changes, not a placeholder; after
  reconnect the count returns to 0 and the last-sync time updates.

### `status` is a one-shot control-channel client

- **Arrange:** a running daemon serving a vault.
- **Act:** run the `status` CLI verb.
- **Assert:** it authenticates with the token, prints the per-vault status
  (state, last-sync time, un-synced count, error state), and exits; the daemon
  keeps running. With no daemon running it reports that clearly instead of
  hanging.

### a stale discovery file reports cleanly instead of crashing

- **Arrange:** a discovery file advertising a port nothing listens on (the
  daemon died uncleanly).
- **Act:** run the `status` CLI verb.
- **Assert:** a clear "daemon not reachable" message and a non-zero exit —
  never a raw stack trace.

### `init` hands off to a running daemon instead of opening its live replica

- **Arrange:** a running daemon advertising its control endpoint; a new vault
  to configure under the same state root.
- **Act:** run the `init` CLI verb.
- **Assert:** the vault is registered **through the control channel** — the
  daemon stores the secrets, persists the profile, and starts serving — and
  the CLI process never opens a second replica store over the daemon's state
  (two write-through processes would corrupt it). With a stale advertisement
  (nothing answers), `init` falls back to the direct path.

### `inspect` decrypts the database client-side for the owner (RV2)

- **Arrange:** a synced vault where `notes/a.md` = "hello"; the fake server
  holds only wire documents.
- **Act:** run `inspect notes/a.md`.
- **Assert:** the owner sees the decrypted logical document (path, content,
  metadata) — inspection is client-side; the server-side bytes alone reveal
  nothing.

### `hist` runs the history command line over a served vault

- **Arrange:** a registered vault where `notes/a.md` has accumulated several
  history versions under `.hist/notes/a.md/`.
- **Act:** run `hist log notes/a.md`; `hist show notes/a.md <rev>`; `hist
  diff notes/a.md`; and `hist restore notes/a.md <rev>`.
- **Assert:** the log names the file's versions with the live one marked;
  show prints the chosen version's content; diff renders the last edit as a
  unified diff; restore materializes the chosen version into the live
  `notes/a.md`, and the restored content syncs. The folder and writer name
  came from the vault's profile — no `--folder` was given.

## Module hosting (`daemon-modules` R1, R2, R3, R8)

### a vault with history only serves with no connection and no passphrase

- **Arrange:** a vault registered with the module set `{history}` and no
  endpoint, database, credentials or passphrase; a fake server that records
  every request it receives.
- **Act:** create and edit files in the folder; reconcile several times.
- **Assert:** `.hist/` gains versions for the edits, written under the
  vault's writer name; the server received **no** request; the secret store
  holds **nothing** for the vault; status reports the vault running with
  modules `[history]`, an un-synced count of zero and no error.

### a vault with sync only replicates and creates no .hist/

- **Arrange:** a vault registered with the module set `{sync}`.
- **Act:** create and edit files; reconcile; bring a second device up on the
  same database and reconcile it.
- **Assert:** the content converges on the second device, and **no**
  `.hist/` directory exists on either — nothing was recorded.

### a failing module is isolated, and status names it

- **Arrange:** a vault with both modules where history's store is rigged to
  fail on **every** write; a second device on the same database.
- **Act:** edit files; reconcile both devices.
- **Assert:** replication keeps converging — the edits reach the second
  device — while history records nothing; status reports the vault running
  with **degraded** naming `history` and the write error; the un-synced
  count is zero. No other vault served by the daemon is affected.

### the persisted profile is shaped per module, and nothing else loads

- **Arrange:** a registry holding one entry written per module with every
  field set; then one entry in another shape (connection keys at the top
  level, no module list).
- **Act:** load the registry; register a connection over the served profile;
  patch one history field; then load the other entry.
- **Assert:** the per-module entry loads with exactly the modules it names
  and every field intact, and round-trips byte for byte; a connection
  arriving flat changes the connection and keeps every field it omits; a
  patch names blocks; the other entry is **refused** with an error naming
  the vault — nothing is guessed. A history-only entry carries no
  connection block and loads without reading any secret.

## Changing a module's configuration (`daemon-modules` R9, R10)

### a history setting changes in place, without stopping replication, and survives a restart

- **Arrange:** a served vault with both modules, tracking `.md` only; a
  second device on the same database.
- **Act:** over the control channel, send a configuration change naming
  only the history block's tracked extensions (`.md,.txt`); then edit a
  `.txt` file and reconcile; then read the configuration back; then restart
  the daemon from its registry.
- **Assert:** no secret was presented or returned; the sync module is the
  **same instance** before and after and the edit still reaches the second
  device; the `.txt` file now gains history; the writer name and idle window
  are unchanged (omitted means unchanged); the configuration read back shows
  the new extensions and no secret; after the restart the vault still tracks
  `.txt`.

### enabling and disabling history changes the module set alone

- **Arrange:** a served vault with sync only.
- **Act:** enable history over the channel; edit a file and reconcile;
  then disable it and edit again.
- **Assert:** after enabling, `.hist/` gains a version for the edit and
  status lists both modules, with replication untouched throughout; after
  disabling, the next edit syncs but records nothing, and status lists sync
  alone.

### enabling sync needs a connection, and an unknown vault is refused

- **Arrange:** a served vault with history only, no connection.
- **Act:** ask to enable sync through the configuration command; then send
  a change for a vault id the daemon does not serve.
- **Assert:** both are refused with a clear error — the first says a
  connection is needed and names setup as the way — and nothing changed.

### the config verb reads and writes through the running daemon

- **Arrange:** a running daemon serving a vault, advertised for discovery.
- **Act:** run `config <vault-id>`; then `config <vault-id>
  --history-extensions .md,.json`; then `config <vault-id>` again.
- **Assert:** the first prints the per-module configuration with no secret
  in it; the second reports the change applied through the daemon and the
  served vault tracks `.json` from then on without a restart; the third
  shows the new value.

## Noticing a divergence (history-surface R16–R18)

### a divergent line raises the count on every device, and a marker settles it everywhere

- **Arrange:** three devices synced on `plan.md = A`, created on the third;
  the other two edit it concurrently (`C` on one, `D` on the other) and all
  reconcile until the history files have converged, so one edit won LWW and
  the loser's line — written by a device the primary line does not carry —
  is a divergent branch on **every** device.
- **Act:** read each daemon's status; then on one device record a `merged`
  marker naming the losing leaf and the live version (the history surface's
  "leave mine as it is"); reconcile all again.
- **Assert:** before the marker, every status carries a divergence count of
  **one** — a count of files, derived from the graph, nothing stored, and
  carried over the wire; after the marker has synced, every count is
  **zero** without any other device having been told anything locally — the
  marker propagated. The un-synced count is untouched by any of this.

## Ignore files (RV8)

### .syncignore patterns exclude paths from sync in every supported form

- **Arrange:** a served vault whose root contains `.syncignore` with one
  pattern of each supported form: a bare basename (`draft.md`), an anchored
  path (`/inbox/scratch.md`), a directory (`cache/`), a within-segment glob
  (`*.tmp`), and a cross-segment glob (`assets/**/raw.bin`); plus matching
  files on disk and one non-matching control file; a comment line and a blank
  line in the file.
- **Act:** reconcile.
- **Assert:** none of the matching paths produce a document in the replica or
  reach the server; the control file syncs; the comment/blank lines change
  nothing; an unsupported `!negation` line is ignored as if a comment.

### newly ignoring an already-synced path stops sync without deleting anything

- **Arrange:** a synced vault where `notes/big.md` exists on disk, in the
  replica, and on the server; a second device also has it.
- **Act:** append `notes/big.md` to `.syncignore`; reconcile; then edit the
  file locally and reconcile again; finally remove the pattern and reconcile
  once more.
- **Assert:** while ignored — the path is never tombstoned on the server, the
  local file stays on disk, its cursor entry is dropped, and the local edit is
  neither pushed nor recorded to history; after un-ignoring — content
  differing from the replica winner is ingested as an ordinary local edit
  (identical content would only repair the cursor, minting no revision).

### the ignore file itself syncs, so rules are shared across devices

- **Arrange:** device A and device B synced on one database.
- **Act:** on A, create `.syncignore` containing `secret/`; sync both; then on
  B create `secret/x.md` and reconcile B.
- **Assert:** `.syncignore` materializes on B as an ordinary file, and B's
  shell honors it — `secret/x.md` never enters B's replica or the server.

### a remote change for an ignored path is not materialized

- **Arrange:** device A ignores `notes/skip.md` via `.syncignore` (the rule
  file not yet propagated to B); B edits `notes/skip.md` and pushes.
- **Act:** A pulls and reconciles.
- **Assert:** the document is grafted into A's replica (replication is
  document-level) but no file is written into A's vault for the ignored path;
  A's cursor holds no entry for it.

### nested ignore files anchor to their directory and travel with the vault

- **Arrange:** device A with `notes/.syncignore` containing `/drafts/` and
  `notes/.histignore` containing `scratch.md`; files `notes/drafts/a.md`,
  `drafts/b.md`, `notes/scratch.md`, `deep/scratch.md`, `notes/keep.md`.
- **Act:** reconcile A; bring up device B on the same database and reconcile
  it; edit `notes/scratch.md` and `deep/scratch.md` on B past the history
  idle interval.
- **Assert:** `notes/drafts/a.md` never reaches the server while `drafts/b.md`
  does — the anchored pattern binds to `notes/`; both nested ignore files
  materialize on B as ordinary files; on B, `notes/scratch.md` gains no
  history while `deep/scratch.md` does — the basename pattern reaches only
  beneath `notes/`; and `.hist-state/` on either device never produces a
  document.

### .histignore excludes from history tracking but not from sync

- **Arrange:** a vault with `.histignore` containing `journal/`; a tracked
  file `journal/day.md` and a control file `notes/a.md`.
- **Act:** edit both; reconcile past the history idle interval.
- **Assert:** both files sync to the server; `notes/a.md` gains history under
  `.hist/notes/a.md/`; `journal/day.md` gains **no** history folder; a losing
  **binary** conflict on a hist-ignored path is still rescued as a `.conflict`
  copy (rescue bypasses the filter — RV9 is data-safety).

### setup-uri emits a pasteable connection string without the passphrase

- **Arrange:** a registered vault whose profile holds an endpoint, database,
  server user, and server password (secrets in the store).
- **Act:** run `setup-uri` for the vault without `--transfer-secret`; then
  decode the printed URI with the printed transfer secret using the
  front-ends' decoder; also attempt decoding with a wrong secret.
- **Assert:** the output contains an `entropy-sync://setup#…` string and a
  generated transfer secret; decoding recovers exactly the endpoint,
  database, server user, and server password; the E2EE passphrase appears
  **nowhere** in the output; the wrong secret is rejected rather than
  yielding garbage; passing an explicit `--transfer-secret` uses it verbatim.

### setup-uri also encodes a connection given explicitly, with no vault registered

- **Arrange:** a state root with **no** vaults registered (a freshly
  provisioned server, before any device is set up).
- **Act:** run `setup-uri` passing the endpoint, database, server user and
  server password as arguments.
- **Assert:** a URI and a transfer secret are printed without touching the
  registry or the secret store; decoding with that secret recovers exactly the
  four values given; the command fails with a clear usage message when only
  some of them are supplied; the registered-vault form keeps working unchanged.

### `init` refuses a shared database without the flag and accepts it with one

- **Arrange:** a state root with one vault already registered at some
  (endpoint, database).
- **Act:** run `init` for a second vault at a non-overlapping folder targeting
  that same endpoint and database — first without the shared-database flag,
  then with it.
- **Assert:** without the flag the command fails with a clear error naming the
  vault already using that database and registers nothing; with the flag the
  vault is registered. Both outcomes are identical whether `init` hands over to
  a running daemon or takes the direct path with none running.

### a vault whose folder collides with a served one is refused

- **Arrange:** a daemon serving a vault rooted at a folder.
- **Act:** register a second vault (different id, different database) rooted at
  the same folder; then one rooted at a subfolder of it; then one whose root
  contains it.
- **Assert:** each is refused with a clear error naming the vault it collides
  with; nothing is registered and the served vault is untouched; re-registering
  the original vault at its own root is still the idempotent attach.

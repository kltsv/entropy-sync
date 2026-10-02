---
name: vault_daemon
description: The always-on desktop daemon (entropyd) that owns each vault folder and hosts independent modules over it — sync (watch → encrypt → replicate, atomic materialization of remote winners, conflict rescue with notification) and history (this machine's edits recorded to multi-writer history), any subset per vault, each configurable alone and isolated in failure — with content-hash rename detection and marker linking, multi-vault, a CLI (init/run/status/config/inspect/hist/setup-uri/hub), and an authenticated localhost control channel shared by interchangeable front-ends.
status: draft
---

# Vault sync daemon

## Purpose

On desktop the sync engine runs **out of process** so it keeps working with no
GUI open — the CLI/agent and Obsidian edit plain files and the daemon captures
those edits whether or not any app is running (R10, C10). This module is that
daemon: a headless, always-on service that **owns each vault folder** and is a
**thin shell over the three independent modules** — it composes `vault_crypto`
between the folder and `vault_sync`, drives replication both ways, and feeds
`vault_hist` with the path-state changes of **this machine's own edits**
(RV1, RV6). All logic lives in the modules; the daemon only glues (RV1).

It also exposes an **authenticated, local-only control channel** that
front-ends (the entropy app and the Obsidian plugin) attach to as
interchangeable, simultaneous controllers (R18–R20). Obsidian and the CLI run
**no** sync of their own; they are plain file consumers of the folder the
daemon maintains (R10, N3).

## Inputs

- **Per-vault connection profiles** (from a front-end via the control channel
  or the vault's config in the daemon's state directory): vault root path,
  server endpoint, database name, server credentials, writer name, exclusion
  list, history extension list, debounce intervals, rescan period, inline
  threshold. **Secrets** (E2EE passphrase, server password) are read from the
  OS secret store keyed by vault — never from inside the vault or the server
  (R23, C11, RV10).
- **The vault folder's files** — read, written, and watched for external
  changes made by any client (R10).
- **The server**, over the sync module's transport.
- **Control commands** from front-ends: status queries, pause / resume /
  sync-now, and **registering or editing a vault profile** (R18, R20, D10).

## Outputs

- **A converged vault folder** — the winning revision of every document
  materialized as a plain file; deletions removed (to the system trash); the
  folder kept in step with the server both ways.
- **History records** under `.hist/` for every change made **on this
  machine** (by any tool), via `vault_hist`'s writer (RV6).
- **Authoritative daemon status** to every attached front-end: per vault
  running / paused / offline, last-sync time, count of un-synced local
  changes, error state (hub unreachable / bad passphrase), the current
  conflict list (R17, R18, R20), the **divergence count** — how many files
  have a divergent history line (history-surface R16), carried as data
  beside the conflict list; rendering it is the front-ends' later concern —
  and the vault's **enabled modules** with any module that is **degraded**
  and why (`daemon-modules` R3).
- **Conflict rescues**: losing binaries copied into history; the owner
  notified (RV9).
- **A log** in the daemon's state directory recording sync activity, conflicts
  and their resolutions, and errors (RV10).

## Behavior

### Owning the folder; the daemon is the only sync engine (R10, C10)

- The daemon **owns** each configured vault folder: it maps the folder to the
  server database through crypto + sync, in both directions. Obsidian and the
  CLI/agent read and write ordinary files with no sync awareness; Obsidian
  picks up the daemon's writes on its own. Neither runs replication (N3).
- The daemon runs **out of process and always-on**: installed once, it keeps
  syncing after every front-end closes (R17, R18).

### Composing the modules (RV1)

- The sync module's replica holds **wire documents** (ciphertext); plaintext
  exists only as the real files in the vault folder. On a local change the
  daemon reads the file, builds the logical document, `encrypt`s it via
  `vault_crypto`, and `put`s the wire document into `vault_sync`. On a remote
  change it `decrypt`s the pulled wire document and materializes the file.
- History, sync, and crypto never call each other — every arrow goes through
  the daemon (RV1).
- The **folder itself** belongs to `vault_folder`: the daemon neither watches
  nor writes into the vault directly. That service settles raw editor events
  into states, hashes each once, performs every write, and reports each state
  **attributed** — a local edit, or a materialization the daemon asked for.
  Routing on that attribution is what keeps the daemon's own writes from
  returning as edits, and what lets the capabilities below be enabled
  independently (`daemon-modules` R4, R5).

### Module hosting (`daemon-modules` R1, R2, R3, R8)

The daemon is **one process hosting independent modules** over the folder
service. Today there are two, **sync** (replication) and **history**; a
vault enables an explicit set of them, and any subset works.

- **A vault enables an explicit set of modules (R1).** Its configuration
  names which are on; an unnamed module is off. A vault with **history
  only** runs no replication, never contacts a server, and needs neither
  connection nor passphrase — history over a plain folder, the local
  git-lite. A vault with **sync only** creates no `.hist/`. A vault with
  both behaves exactly as the daemon always has. Enabling a module later
  starts it without reconfiguring the others; disabling one stops it and
  leaves the rest running. A vault whose configuration predates modules
  has both — nothing changes for it (R11).
- **Modules never reference each other (R2).** Each consumes the folder
  service's attributed stream and nothing else: history commits `local`
  states and adopts `materialized` ones; sync pushes `local` states and
  materializes what arrives. Every arrow between them goes through the
  host: when sync learns a state was not an edit but agreement with the
  replica, or a losing binary needs rescuing, or a rename was detected, it
  tells the **host**, and the host tells whichever module is there. Removing
  a module from the build leaves the other compiling and its tests passing;
  a module's tests run with no other module present.
- **A failing module is isolated (R3).** A module that cannot start, or
  fails while running, does not stop the other module of that vault or any
  other vault: the host catches each module's failure, records it against
  that module, and keeps driving the rest. With history unable to write (a
  full disk), replication keeps converging; status reports the vault as
  **degraded**, naming the failing module and its error, beside the sync
  state it always carried.
- **Each module has its own configuration block and its own secrets (R8).**
  The persisted profile is shaped per module — the connection under `sync`,
  the writer name, tracked extensions and idle window under `history`,
  folder-level tuning (exclusions, debounce, rescan, inline threshold) under
  `folder` — so changing a history setting requires no credential and
  leaves the connection untouched, and a vault with history only stores no
  secret at all. That is the registry's only shape: an entry in any other is
  refused with a clear error naming the vault, never guessed at.

### Changing a module's configuration (`daemon-modules` R9, R10)

- One module's settings can be read and changed **without re-registering
  the vault**: a control-channel command and the CLI's `config` verb take a
  **partial** configuration — any of the per-module blocks, the folder
  block, or the module set — and present **no secrets**; the daemon already
  holds them.
- **Omitted means unchanged (R10).** A field the request does not mention
  keeps its value; a block not mentioned is untouched. A front-end that
  knows nothing about a setting cannot destroy it by editing a neighbouring
  one.
- **A history setting takes effect in place.** The history module is
  rebuilt over the same folder service with the new writer name, tracked
  extensions or idle window — its pending edits committed first — while
  replication is **never stopped**: the sync module is the very same
  instance before and after. Enabling history on a vault that had none
  starts it the same way; disabling it stops recording. A changed exclusion
  list is applied to the folder live.
- A change that reaches the runtime — the connection, the debounce or
  rescan intervals, the inline threshold, enabling sync — replaces the
  vault's runtime, the same path a re-registration takes. Enabling **sync**
  needs a connection the module set alone cannot supply, and is refused
  saying so: the front-ends' setup (or `init`) is how sync is added.
- Every change is **persisted**, so it survives a restart.

### Continuity and naming (`daemon-modules` R11, R12)

- **No upgrade path (R11, withdrawn).** Nothing was ever released before the
  module split, so the daemon reads no earlier registry shape and primes no
  folder record from a replication checkpoint: a vault is registered once,
  in the current shape, and served from there.
- **The name describes the daemon (R12).** The binary is **`entropyd`** and
  its service registration is `com.entropy.daemon` (launchd) or `entropyd`
  (systemd) — it hosts more than replication, and its name no longer says
  otherwise. The state root (`~/.entropy-sync`), the discovery file, the
  registry and the secret store are **unchanged**. No earlier name is looked
  for or retired: nothing was released under one, and a development machine
  that ran the daemon under its old name removes that service by hand.

### First scan populates a clean replica; init (D5, RV3, RV10)

- `init` for a vault: store the profile, put secrets into the OS secret
  store, ensure the database exists, and run `vault_crypto.init` — on an
  empty database this generates the salt and writes the plaintext `meta`
  document; on an existing one it verifies the passphrase against `meta`'s
  check value and **refuses to overwrite** it (RV3). A wrong passphrase
  surfaces as the vault's error state and **no sync runs** (RV3).
- The first run walks the vault (skipping exclusions), writes each file as an
  initial encrypted revision, and pushes — **the first scan is the initial
  sync**; there is no LiveSync migration (N8, D5). History accrues from this
  moment. The D5 rule is scoped to an **empty database**: a fresh replica
  first **pulls** and materializes, and only when the database turns out to
  hold no content does the scan seed.
- **Re-attaching a fresh replica to a populated database** (restored backup,
  wiped state directory) is therefore not an initial sync: after the first
  pull, on-disk files identical to the pulled winners just repair the
  reconciliation cursor — no revisions minted, no per-file conflicts — while
  files that differ or are new are ingested as **real local edits** (recorded
  to history; where they collide with a pulled winner they meet it in the
  conflict machinery rather than silently losing).
- Subsequent runs reuse the persisted replica and reconcile changes since.

### Local change detection (R10, RV4)

**The daemon owns when an edit is recorded** — `vault_hist` has no timers and
no debounce of its own; it records exactly what it is committed (D7). Two
things follow, and both are the daemon's job:

- Raw events are **coalesced into one settled state per edit** before any
  commit. Editors save by writing a temporary file and renaming it, or by
  deleting and recreating; forwarding those verbatim would record a deletion
  and a brand-new life for every ordinary save.
- A local edit racing an incoming one is **committed before the arrival is
  applied**, so it records from the base it was really made on. Ordering is
  something only the caller can guarantee, which is exactly why the timing
  lives here.

- A filesystem watcher covers the vault; events debounce **per path**
  (~1–2 s) and are settled by the folder service, which reports a state only
  when the content actually differs from what it last saw. A **local** state
  is a local edit: encrypt → `put` **parented on the recorded revision**, and
  `commit(path, content, writer)` to history. An absent one → `delete` +
  `commit(path, absent, writer)` (RV6). Parenting on the recorded revision is
  what turns an edit based on stale disk content (a pull grafted a newer
  winner while the edit raced) into a **sibling branch** — a real conflict —
  instead of a silent fast-forward over the fresh remote winner.
- **Two records, two jobs.** Detecting change is the folder service's own
  record (hash + mtime + size), so it works with any set of capabilities
  enabled; `last_synced` is the daemon's **replication checkpoint** — the
  replica revision each path's on-disk content corresponds to, which is what
  the parenting above and the materialization skip below key on.
- The mtime+size pair is the fast path; content is hashed only when they
  changed. A **periodic full rescan** (configurable, minutes) and a **startup
  scan** catch anything the watcher missed: anything differing from what the
  folder service last saw is treated as a local edit made while the daemon
  wasn't looking (R10). Files above the inline threshold are hashed and
  encrypted **from a stream** — never held whole in memory.
- Writes the daemon itself just performed come back from the folder service
  as **materializations**, matched by content, so they are never re-ingested
  as local edits (no echo loop); the checkpoint records the revision they
  correspond to.
- **Pause gates ingestion**: a paused vault neither ingests nor pushes —
  watcher flushes included — and resume runs a reconcile that catches up in
  both directions.
- Reconcile, ingest, and materialize passes **serialize** per vault: an
  overlapping request never interleaves with a running pass; a reconcile
  requested while one runs coalesces into a single follow-up pass. One
  unreadable or vanished file skips (with a log line) — it never aborts the
  pass or crashes the daemon; no error escaping a timer, watcher, or stream
  handler may take the process down.

### Materializing remote changes (RV4)

- A remote change event → `decrypt` → the folder service writes the file
  **atomically** (temp file in the same directory + rename) with its mtime
  from the logical document, and reports it back as a **materialization**.
  The checkpoint records the revision it corresponds to, and history records
  **nothing**: the change was recorded by the writer that made it, and
  re-recording it here would mint a second edge for one edit and attribute it
  to the wrong device (RV6).
- Before writing, ask the folder service to settle the path: if the file
  changed locally while the pull was in flight, first ingest that local edit
  (as above) and let the server's conflict machinery reconcile — the daemon
  never merges (R9). **A file the folder service has no record of IS a local
  change** (a creation the watcher has not flushed yet): it is ingested,
  never overwritten. Settling also emits the racing edit **before** the write
  lands, so history records it from the base it was really made on. The check
  is repeated after the decrypt awaits, immediately before the write, so a
  save landing mid-materialization is ingested too.
- A remote deletion moves the file to the **system trash** (never
  irreversible) and records nothing in history — the deleting writer already
  did. The same guard applies: a file the folder service has no record of, or
  one edited locally, is ingested, never trashed.
- A reconcile pass skips documents whose winning revision equals the
  recorded materialized revision **without decrypting them** — an unchanged
  vault decrypts nothing.

### What is not synced (RV8)

Three sources of exclusion, unioned:

1. **The per-vault profile list** (non-vault configuration); defaults:
   `.DS_Store`, `.trash/`, `.git/`, `_workspace/`,
   `.obsidian/workspace*.json`, the LiveSync and Remotely-Save plugin
   folders, and the daemon's own state (which lives outside the vault
   anyway).
2. **`.syncignore`** — an owner-editable ignore file at the vault root:
   patterns for paths excluded from sync. The file is an ordinary vault file,
   so it **syncs itself** and the rules are shared by every device (each
   shell — daemon and mobile app alike — honors it).
3. **`.histignore`** — same place, same syntax: paths that **do sync** but
   are excluded from history *tracking* only (on top of the tracked-extension
   filter). Conflict rescue copies bypass it — a losing binary is rescued
   regardless (RV9 is data-safety, not tracking).

**Ignore-file syntax** (a documented gitignore subset): one pattern per line;
blank lines and `#` comments ignored; a pattern **without** `/` matches a
basename at any depth beneath the directory the file sits in; a pattern
**with** `/` is anchored at that directory — the vault root for the root
file; `*` matches within one path segment, `**` across segments; a trailing
`/` matches the directory and everything under it. Unsupported forms (e.g.
`!` negation) are ignored as if comments.

**Ignore files nest.** `.syncignore` and `.histignore` may sit in **any**
directory, not only the vault root; each applies to its own directory and
everything under it, with patterns relative to it. Nesting is additive — a
path is excluded if **any** applicable file excludes it — and that rule is
safe precisely because negation is unsupported. Nested files are ordinary
vault files and sync like the root one, so every device honours the same set
(`vault_folder`).

Beside these, the folder service has a **built-in** exclusion no
configuration can remove: `.hist-state/`, this machine's history working
state, per-machine and disposable — never synced, never tracked
(`vault_folder`).

**Effect and timing.** The shell re-reads the ignore files on every scan
(cheaply, by mtime). A path that becomes ignored **stops syncing but is not
deleted anywhere**: it is *not* tombstoned on the server, its local file
stays, and its cursor entry is dropped — exclusion is never mistaken for
deletion. Remote changes for an ignored path are not materialized. Un-ignoring
re-admits the path on the next scan (content identical to the replica winner
repairs the cursor without minting a revision; differing content is an
ordinary local edit).

**`.hist/` IS synced** — it is ordinary files riding the same encrypted layer
— but is excluded from history *tracking* (no history-of-history) (RV8).
Exclusions apply to watching, scanning, and history alike; sync-excluded
paths are never history-tracked.

### Rename detection with marker linking (R16, RV7)

- Within the debounce window the daemon correlates a **removed** and an
  **appeared** file by **content hash**. A match is a rename. On the wire it
  is what it always is — tombstone the old id, create the new one (the HMAC
  id is path-derived, so there is no "move"; a binary's attachment re-uploads,
  accepted). For **history** the daemon records the marker pair via
  `vault_hist`: `deleted` + `renamed_to` in the old folder, `snapshot` +
  `renamed_from` in the new — **no folder is ever moved** (RV7).
- Only **unambiguous, non-empty** matches pair: empty files are never
  rename-paired (every empty file shares one hash), and a hash shared by
  several removed or several appeared files degrades to delete + create
  instead of guessing — a wrong marker pair would link unrelated files in
  append-only history forever.
- No match within the window → plain delete + create; the old history stays
  intact under the old name (R16).

### Conflicts (R9, RV9)

On `conflict(id, winner, losers)` from the sync module, the daemon decrypts
the parties. The winner is already materialized (LWW; winner data untouched;
no auto-merge). Losers:

- **text** — nothing to store: the loser's author already recorded it in
  history; it is visible as a branch (RV6, RV9);
- **binary** — its full bytes are written to history as a `conflict` rescue
  file (otherwise the losing binary is gone forever) (RV9).

Then `resolve(id, loserRevs)` (idempotent), a line in the daemon log, and an
**OS notification** to the owner. `*.conflict` files never appear in the
vault (N7, D2).

A loser counts as handled only **after** its rescue actually succeeded: a
transient failure (attachment bytes not yet fetched, IO error) holds the
resolution and the next pass retries — resolving first would tombstone bytes
that were never saved. The conflict list surfaced in status reflects the
store's **current** conflicts (rebuilt each reconcile); resolved conflicts
drop off instead of accumulating for the life of the process.

### Noticing a divergence (history-surface R16–R18)

- The daemon **derives** the divergence count from the history graphs —
  nothing new is stored — and keeps it **incrementally**: it already
  observes every history write, both its own commits and `.hist/` files
  **arriving through sync**, which is how a divergence appears in the first
  place; each such write recounts the one path it belongs to. A full
  recount runs on the periodic reconcile pass, as the backstop for anything
  missed.
- Clearing the count is an honest act (R17): a divergence leaves it only by
  being **settled** — a `merged` marker naming its leaf, whoever wrote it,
  wherever it was written. Because the marker is an ordinary synced file it
  **propagates**: settled on one device, every other device stops counting
  once the marker arrives. There is no local-only mute.
- The count is per **file** (R13), reported in status beside the un-synced
  count and the conflict list, and printed by `status`.

### Multi-vault (R23)

- One daemon serves **multiple vaults concurrently**, each with its own
  profile, replica, watcher, history writer, and state. Vaults are isolated:
  a fault or pause on one never stops the others.
- The daemon **owns each served vault's continuous runtime** — the engine's
  longpoll loop, the watcher subscription, and the periodic-rescan timer —
  as one unit: created when the vault starts continuous mode (including
  vaults registered later over the control channel) and disposed when the
  vault stops or is re-registered. Editing a vault's profile replaces its
  runtime; no stale watcher or timer ever keeps driving a stopped shell.
- **Isolation is by database, but the owner may override it**: by default the
  daemon refuses to register a second vault targeting the same (server
  endpoint, database) as one it already serves — aimed at two *different*
  vaults, that would merge them into one. The refusal is a **policy** guard,
  not a technical limit: replica ids are per (vault, device) and checkpoints
  are local-only (`vault_sync` RV4), so a second replica of one vault is
  exactly as safe as a second physical device. The daemon therefore accepts
  the registration when it **explicitly acknowledges the shared database** —
  a flag on the add/edit-vault command and on `init` — and refuses only when
  it does not. Unacknowledged is the default so that nothing merges two
  vaults by accident; the acknowledgement is what a front-end sends after the
  owner confirms the warning (`vault_sync_control`). Re-registering the *same*
  vault is the idempotent attach of R20 — never a conflict, and it needs no
  acknowledgement.
- **Registering a known vault preserves the tuning it was not asked to
  change.** A registration carries the *connection*; the serving parameters —
  writer name, exclusions, tracked history extensions, intervals, thresholds —
  belong to the vault, and a field the request omits keeps the value the
  daemon already holds. Only a new vault falls back to defaults.
- This is not a convenience: without it any front-end action that
  re-registers a vault (editing a connection, re-entering a passphrase)
  silently resets every setting it happens not to model, and the owner is
  never told — sync keeps working, just not the way they configured it. A
  front-end owns the connection; it must not have to know every tuning field
  in existence to avoid destroying them.
- Vaults sharing a database **converge to one content set**: each replica
  pushes its own files and pulls the other's, so both folders end up holding
  the union; same-path differing files become ordinary conflicts with both
  versions kept (R9). They must also share the **same E2EE passphrase** — the
  documents are ciphertext under it, so a second vault configured with a
  different passphrase cannot read what the first wrote.
- **Isolation is also by folder, and that one has no override**: a vault whose
  root is the same directory as an already-served vault's — or **nested**
  either way (one root inside the other) — is refused outright, with no flag
  to acknowledge it. Unlike the database rule this is a technical limit, not a
  policy: two shells over one directory would each read the other's
  materializations as local edits and mint revisions forever; nesting makes
  the outer vault swallow the inner one's files and its `.hist/`. Re-registering
  the same vault at its own root remains the idempotent attach, not a conflict.
- When a candidate vault collides on **both**, the **database check reports
  first** — it is the one the owner can act on.
- Any number of databases with any credentials: profiles are fully
  independent — different servers, different accounts, different passphrases
  (R23).

### Configuration, state, CLI (RV10)

- Config and state live **outside every vault**, in a per-vault directory
  under the daemon's state root: the profile, the replica state store, the
  attachment blob store, and logs. Secrets stay in the OS secret store
  (Keychain on macOS), keyed by vault; a plain-file fallback readable only by
  the user exists for headless setups, never inside a vault (C11, RV10).
- CLI verbs (RV10):
  - `init` — configure a vault (profile, secrets, `meta`, first scan). When a
    running daemon is discoverable, `init` hands the vault over through the
    control channel instead of opening the daemon's live state files itself
    (two processes over one replica would corrupt it); the direct path runs
    only when no daemon actually answers. It carries the **shared-database
    acknowledgement** as an opt-in flag, so a headless setup can do
    deliberately what a front-end does after a confirmation; without the flag
    a colliding database is refused, and both paths — handover and direct —
    enforce it identically. `--modules` names the enabled set: `history`
    alone needs no connection and no passphrase, and asks for none;
  - `config <vault-id> [changes…]` — read one vault's per-module
    configuration (no secrets in it), or change a part of it: the history
    block's writer name, tracked extensions and idle window, the folder's
    exclusions and rescan interval, and the module set (`--enable`,
    `--disable`). Through the running daemon when one answers, so the
    change takes effect at once; into the registry otherwise, for the next
    start;
  - `run` — serve all registered vaults;
  - `status` — one-shot status of the running daemon (a client of the control
    channel). A discovery file left behind by an unclean death reports as a
    clear "daemon not reachable" message with a non-zero exit — never a raw
    stack trace;
  - `inspect [path]` — decrypt and display the database's documents for the
    owner's eyes — inspection moved client-side, since the server sees only
    ciphertext (RV2);
  - `hist [--vault-id <id>] <verb> …` — the history
    command line (`vault_hist_cli`) over a served vault: the **same verbs
    as the standalone tool** (`commit`, `log`, `show`, `restore`, `diff`,
    `blame`, `merge`, `status`), through the same library — never a second
    implementation. The daemon supplies what only it has: the vault's folder,
    writer name and tracked extensions from its profile, so the owner names
    the vault rather than the folder;
  - `setup-uri` — emit the copyable setup-URI (`vault_sync_control` D9): the
    non-secret connection (endpoint, database, server credentials) encrypted
    under a transfer secret — supplied with `--transfer-secret` or freshly
    generated and printed alongside. It works two ways: for a **registered
    vault**, whose connection is read from the daemon's own registry and
    secret store; or for a connection given **explicitly** (endpoint,
    database, server user and password as arguments), which needs no
    registered vault and no daemon state at all — that is how a freshly
    provisioned server hands the owner a pasteable string **before any device
    is configured**. The E2EE passphrase is **never** inside the URI; the
    receiving device asks for it separately. The encoding is byte-compatible
    with the front-ends' decoder, so the printed string pastes straight into
    the app's or the Obsidian plugin's setup form.

### The local control channel (R18, R19, R20)

- A **local-only channel bound to localhost**; carries **only** status and
  control — never vault plaintext, so it cannot weaken E2EE (R18, C3).
  Commands: status, pause / resume / sync-now, **add/edit a vault profile**
  (the front-end hands over the non-secret profile; secrets go to the OS
  secret store) (R23, D10), and **read / change one vault's per-module
  configuration** without secrets and without re-registering
  (`daemon-modules` R9).
- **Authentication**: a local shared secret (a token file readable only by
  the user); an unauthenticated local process can neither read status nor
  issue commands (R19).
- **Multiple controllers attach at once** and see the same authoritative
  state; any control action is reflected to every attached front-end. A newly
  opened front-end discovers the running daemon and attaches without re-setup
  (R18, R20). The daemon runs and syncs with zero front-ends attached.
- Exactly one daemon instance is authoritative; bootstrapping is idempotent —
  an already-running daemon is attached to, never duplicated (R20, R21).

## Non-goals

- **Not the replication protocol / document model / conflict math** — that is
  `vault_sync`; the daemon drives it.
- **Not the crypto** — `vault_crypto` transforms; the daemon only composes it
  (RV1).
- **Not the history algorithm/layout** — `vault_hist`; the daemon is one
  of its writers (for this machine's edits), not its owner (RV6).
- **Not the installer or any UI** — install/bootstrap, setup input, and
  status display are `vault_sync_control`; the daemon serves status and
  accepts commands, it does not present them.
- **No mobile daemon** — the sandbox forbids it; on mobile the same modules
  run in-process inside the app (R11).
- **No sync engine inside Obsidian, ever** (N3).
- **Does not store secrets itself** beyond the OS secret store / user-only
  fallback; the passphrase never enters the vault or the server (C11).

## Examples

### Agent edit with Obsidian closed propagates and is recorded (S2)

Obsidian is shut. The CLI/agent writes `notes/todo.md`. The watcher flushes
after the per-path debounce; the daemon hashes the file, sees it differs from
`last_synced`, encrypts and `put`s it, and commits the settled state to
history. History has the version and, within seconds, the hub has the
ciphertext (RV6).

### First scan is the initial sync (D5)

A vault is connected with `init`: the profile is stored, secrets go to the
Keychain, `meta` is written to the empty database, and the full scan pushes
every file as an initial encrypted revision. No LiveSync migration. History
starts here.

### Re-attach to a populated database is not an initial sync (D5 scope)

A vault folder restored from backup is connected to its existing database
with a fresh state directory. The first reconcile pulls before scanning:
files identical to the server's winners repair the cursor silently — no new
revisions, no conflict per file, no notification storm. One file edited
offline differs: it is ingested as a real local edit (recorded to history by
this machine) and meets the server's winner in the conflict machinery — the
losing side survives as a branch or rescue, never a silent loss.

### Wrong passphrase on a second machine (RV3)

A second desktop runs `init` against the populated database with a typo'd
passphrase. `vault_crypto` fails the `meta` check; the vault lands in the
error state ("bad passphrase"), nothing is pulled, nothing is scanned, and
the front-ends display the error.

### Rename links history without moving it (S6, RV7)

`notes/a.md` disappears and `notes/b.md` appears with the same content hash
within the window. On the wire: tombstone + create. In history:
`.hist/notes/a.md/` gains `deleted` (`renamed_to: notes/b.md`),
`.hist/notes/b.md/` gains `snapshot` (`renamed_from: notes/a.md`). Both
folders remain append-only forever.

### Binary conflict loser is rescued, text loser is not (RV9)

`img/logo.png` and `notes/plan.md` both conflict during a reconnect. The
losing `plan.md` revision was recorded by its author's device and shows as a
branch — the daemon stores nothing extra. The losing `logo.png` bytes are
written as a `conflict` file in history. Both resolutions push tombstones,
the log records them, and a system notification fires. The vault contains no
`*.conflict` file.

### Two front-ends, one daemon (R20)

The entropy app and the Obsidian plugin are attached. "Pause" pressed in the
app flips the plugin's badge within seconds; "sync now" in the plugin updates
the app's last-sync time. Closing both changes nothing about sync.

### A second vault on its own server (R23)

The owner registers `~/vaults/work` against `couch.example.org/db-work` with
different credentials and a different passphrase. The daemon serves both
vaults independently; pausing one leaves the other syncing. Registering a
third vault that targets `db-work` again is refused with a clear error —
unless it acknowledges the shared database, which is how the owner puts one
vault in two folders on purpose (the two folders then converge to one content
set, so the same passphrase is required).

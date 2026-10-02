---
tests: vault_sync_control
---

# Vault sync control — test-spec

Agnostic test cases for the `vault_sync_control` module, in strict Arrange / Act /
Assert form. The cases target the **behaviour** both front-ends share (setup-URI,
secret placement, setup handover, idempotent bootstrap decision, autostart, status
model, the control-channel client, conflict surfacing, engine placement) using
fakes for the OS secret store, the daemon control channel, the installer, and the
in-process engine. Terms:

- **secret store** — a fake OS secret store keyed by (vault, key).
- **channel** — a fake daemon control channel (authoritative state + token),
  accepting status/control commands including add/edit-vault.
- **setup-URI** — the copyable connection string encoding endpoint + database +
  server credentials under a transfer secret.
- **engine** — a fake in-process sync engine (the mobile counterpart of the
  daemon).

## Per-vault setup and secret placement (R23, D9)

### a setup-URI plus passphrase yields a per-vault profile with secrets stored locally

- **Arrange:** a setup-URI encoding `endpoint`, `database`, server user/password
  under a transfer secret; a passphrase; an empty secret store, keyed to vault `V`.
- **Act:** run first-run setup for vault `V` with the URI and passphrase.
- **Assert:** a connection profile for `V` holds the non-secret endpoint + database;
  the **passphrase** and **server password** are written to the secret store keyed
  by `V`; the profile is bound to `V` (a different vault would have its own).

### secrets are never written into the vault or synced

- **Arrange:** the setup from the previous case, with a vault folder on disk.
- **Act:** complete setup.
- **Assert:** no file inside the vault folder contains the passphrase or the server
  password, and neither is placed in any document handed to the sync layer — secrets
  live only in the secret store (C11).

### a malformed or wrong-secret setup-URI is rejected without storing anything

- **Arrange:** a corrupt setup-URI (or the wrong transfer secret).
- **Act:** run setup.
- **Assert:** setup fails with a clear error; the secret store and profile list are
  unchanged (nothing partial is stored).

### opening a different vault uses that vault's own profile (R23)

- **Arrange:** profiles configured for vaults `V1` and `V2` with different
  endpoints.
- **Act:** open `V2`.
- **Assert:** the active profile is `V2`'s (its endpoint/database and its secrets),
  not `V1`'s.

### a setup-URI colliding with an existing vault's target warns before proceeding

- **Arrange:** vault `V1` already configured against some (endpoint, database),
  its target claimed in the shared registry; an empty secret store for `V2`.
- **Act:** configure a *different* vault `V2` from a setup-URI decoding to the
  **same** endpoint and database.
- **Assert:** setup does not store anything before asking: the owner is warned
  with a message naming `V1` and stating that both folders become one vault
  converging to the same content set and that the same E2EE passphrase is
  required. Re-configuring `V1` to its own target succeeds with **no** warning
  (a vault does not collide with itself). A target claimed via one front-end is
  visible to the other (shared registry).

### declining the shared-database warning stores nothing

- **Arrange:** as above, with `V1`'s target claimed.
- **Act:** configure `V2` against the same endpoint and database and **decline**
  the confirmation.
- **Assert:** **nothing is stored** for `V2` — no secrets, no claim, no profile
  handed to the daemon — and `V1` is untouched.

### confirming the warning registers with the shared-database acknowledgement

- **Arrange:** as above; `V2` rooted at a folder that does not overlap `V1`'s.
- **Act:** configure `V2` against the same endpoint and database and **confirm**.
- **Assert:** `V2`'s secrets and claim are stored and its profile reaches the
  daemon carrying the **shared-database acknowledgement**, so registration is
  accepted rather than refused.

### a folder colliding with a configured vault is refused with no confirmation offered

- **Arrange:** vault `V1` configured and rooted at a folder.
- **Act:** configure `V2` with a root that is `V1`'s folder; then one nested
  inside it; then one that contains it.
- **Assert:** each is **rejected** with a clear error naming `V1`, **nothing is
  stored**, and **no confirmation is offered** — the folder rule admits no
  override even when the database is acknowledged. The rejection happens in the
  front-end, without needing the daemon to refuse it.

### removing a vault releases its target claim

- **Arrange:** vault `V1` configured, its target claimed in the shared registry.
- **Act:** remove (disconnect) `V1`; then configure a *different* vault `V2`
  against that same endpoint and database.
- **Assert:** `V1`'s claim is gone from the registry after removal, and `V2`'s
  setup proceeds with **no** shared-database warning — a removed vault never
  leaves its database looking occupied. The release is visible to the other
  front-end too (shared registry).

## An error is actionable in place (R17, D10)

### a vault whose passphrase fails verification is fixed by re-entering it

- **Arrange:** a configured vault the daemon reports in the **bad passphrase**
  error state — the shape of a daemon restart that read a wrong passphrase
  from the secret store, days after a setup that worked.
- **Act:** re-enter the correct passphrase on that vault, and nothing else.
- **Assert:** the stored passphrase is replaced, the vault is handed back to
  the daemon and leaves the error state. The vault's folder, its profile, its
  claim and its history are **untouched** — nothing was removed or
  re-created, and the owner was never asked for the connection again.

### re-entering a wrong passphrase changes nothing but the message

- **Arrange:** the same vault in the bad-passphrase state.
- **Act:** re-enter a passphrase that is still wrong.
- **Assert:** the vault stays in the error state and the surface says so; the
  vault is not removed and the previous data is not touched. Trying again is
  free, which is what makes the action safe to offer.

## Setup ends with a syncing vault (R21, R23)

### completing desktop setup hands the profile to the daemon over the channel

- **Arrange:** a running daemon behind a fake channel that accepts the
  add/edit-vault command; a valid setup-URI + passphrase for vault `V`.
- **Act:** complete first-run setup for `V` on desktop.
- **Assert:** the front-end sends **add-vault** over the control channel with the
  **non-secret** profile (secrets went to the secret store, not over the
  channel); the daemon registers `V` and starts serving it with **no restart**;
  setup ends with a syncing vault, not a stored form — no further user action is
  needed for the first sync to begin.

### re-running the same desktop setup is the idempotent attach (R20)

- **Arrange:** vault `V` already registered with the daemon via a completed
  setup.
- **Act:** run setup for `V` again with the same URI and passphrase.
- **Assert:** the same profile is re-sent and the daemon treats it as an attach —
  no duplicate vault registration, no error, and `V` keeps syncing undisturbed.

### completing mobile setup configures the in-process engine directly (R11)

- **Arrange:** the mobile host (no daemon, no channel); a valid setup-URI +
  passphrase.
- **Act:** complete first-run setup on mobile.
- **Assert:** the decoded profile configures the in-process **engine** directly —
  no daemon install, no control channel — and the first sync can begin as soon as
  setup completes; secrets sit in the device's secret store keyed by the vault.

## Idempotent bootstrap decision (R21)

### BRAT installs the release's daemon without manual checksum setup

- **Arrange:** the three BRAT plugin assets, embedded release metadata with
  daemon version and platform digests, and a fake download server.
- **Act:** install on supported OS/CPU pairs; return corrupt bytes, fail the
  request, or select an unsupported platform.
- **Assert:** the matching immutable release asset is selected without owner
  URL/checksum input; only verified bytes replace the binary atomically;
  corruption/failure keeps any existing binary intact and errors are explicit.

### with no daemon present, bootstrap installs and starts

- **Arrange:** a bootstrap planner that sees no installed and no running daemon.
- **Act:** decide the bootstrap action.
- **Assert:** the decision is install-then-start (from the front-end's install
  source), ending at "installed at correct version, autostart registered, running".

### an already-running daemon is attached to, never duplicated

- **Arrange:** a planner that discovers a daemon already running at the correct
  version.
- **Act:** decide the bootstrap action.
- **Assert:** the decision is **attach** (no install, no second process); the result
  is a single running daemon.

### an out-of-date installed daemon is upgraded, not duplicated

- **Arrange:** a planner that sees an installed daemon at an older version.
- **Act:** decide the bootstrap action.
- **Assert:** the decision is **upgrade** in place (still one daemon), then start —
  not a parallel second install.

### install source differs by front-end (D11)

- **Arrange:** the same "no daemon" state, once for the app front-end and once for
  the Obsidian front-end.
- **Act:** decide the install source.
- **Assert:** the **app** uses its **bundled** binary (no download); the **Obsidian**
  plugin **downloads** the matching OS/arch binary and **verifies integrity** before
  installing.

## Autostart registration (R17, R21)

"Registrar" means the front-end component that writes and loads the OS service
definition; the actual service-manager calls (launchctl / systemctl) are made
through an injectable runner a test can observe.

### registering autostart writes a persistent OS service that runs the daemon

- **Arrange:** a registrar targeting **macOS** with a daemon binary path, a vault
  config path and a data dir; an observable service-manager runner.
- **Act:** register autostart.
- **Assert:** a launchd LaunchAgent definition is written under the user's
  `LaunchAgents` directory; it names the **daemon binary** and passes the
  **config** and **data dir**; it is set to run at load and to relaunch; and the
  runner was asked to **load** that service.

### the Linux registrar writes a systemd user service

- **Arrange:** a registrar targeting **Linux** with the same inputs.
- **Act:** register autostart.
- **Assert:** a systemd **user** unit is written under the user's systemd config
  directory whose `ExecStart` runs the daemon binary with the config and data
  dir, and whose install target is the user default; the runner was asked to
  enable-and-start it.

### re-registering is idempotent (replaces, never duplicates)

- **Arrange:** a registrar with autostart already registered once.
- **Act:** register again with the same inputs.
- **Assert:** the single service definition is replaced (not a second one added),
  and no duplicate service is left behind — matching the idempotent bootstrap
  guarantee (R21).

### autostart can be unregistered

- **Arrange:** a registrar with autostart registered.
- **Act:** unregister.
- **Assert:** the service definition is removed and the runner was asked to
  unload / disable it, so the daemon no longer starts on login.

## Control-channel client and status model (R17, R18, R19, R20)

### the client presents the token to read status and issue commands

- **Arrange:** a fake channel requiring the daemon token; a front-end that has read
  the token.
- **Act:** request status and issue `sync-now`.
- **Assert:** the client presents the token, status is returned, and `sync-now` is
  forwarded; without the token the client cannot read status or command (R19).

### the status model exposes the required fields (R17)

- **Arrange:** a channel reporting a vault as running, last-sync at time `T`, 3
  un-synced changes, no error.
- **Act:** read the status model.
- **Assert:** it exposes at least: state ∈ {running, paused, offline}, last-sync
  time `T`, un-synced count `3`, and an error slot (here empty). An error state
  (hub unreachable / bad passphrase) is representable.

### opening a front-end attaches to an already-running daemon without re-setup (R20)

- **Arrange:** a channel already reporting a running daemon for vault `V` that is
  already configured.
- **Act:** open the front-end for `V`.
- **Assert:** it shows the live running state immediately, performing no reinstall
  and no reconfiguration.

### a control action is reflected across attached front-ends (R20)

- **Arrange:** two front-end clients on the same authoritative channel.
- **Act:** client 1 issues `pause`; client 2 refreshes status.
- **Assert:** client 2 sees paused — the single authoritative state is shared.

## Conflict surfacing (R9 at the surface)

### a reported conflict is surfaced, never merged and never a .conflict file

- **Arrange:** a channel reporting a conflict for `notes/plan.md` (winner chosen,
  loser rescued to history).
- **Act:** read the conflict surface.
- **Assert:** `notes/plan.md` appears in a conflict list with a restore-from-history
  affordance; the front-end offers **no** merge UI in the conflict path and shows
  **no** `.conflict` file (there is none). Reconciling the divergent line is the
  history surface's separate, deliberate act, never proposed here; the status
  carries the divergence count as data beside the conflict list, and nothing in
  this module renders it.

## Mobile in-process engine (R11, RV1, RV6) — Flutter target

### the plaintext cache is a sandbox vault folder that app features read and write

- **Arrange:** the mobile host with the embedded engine over a fake server
  holding synced documents (`finance/ledger.csv`, `notes/n.md`).
- **Act:** launch the app and let the engine sync.
- **Assert:** the engine materializes the logical documents as **real files** in
  a vault **folder** inside the app's sandbox — decrypt on the way in, exactly
  as the daemon materializes a desktop vault; app features (finance first) read
  and write **that folder** through their normal file paths; there is no second
  plaintext copy elsewhere; no separate daemon process is involved, and the
  engine runs only while the app runs.

### every in-app save is reported to the engine; the launch rescan is the backstop

- **Arrange:** the mobile host with the engine running and a note materialized in
  the sandbox vault.
- **Act:** an app feature saves a change to a file; separately, make a file in
  the sandbox vault differ from the engine's baseline while the engine is not
  running (a missed save), then relaunch.
- **Assert:** the in-app save is reported to the engine, which encrypts and
  pushes it — no filesystem watcher exists on mobile; the **rescan on launch**
  catches the missed change and ingests it as a local edit.

### the app writes history for its own edits and stores received history uninterpreted (RV6, RV8)

- **Arrange:** the mobile host with the engine running.
- **Act:** save an in-app edit to `notes/n.md`; apply a pulled remote change to
  `notes/m.md`; receive synced `.hist/` documents from the server.
- **Assert:** the in-app save feeds `localState(notes/n.md, content)` — the
  phone records its own edit once, and the version reaches desktops as ordinary
  synced `.hist/` files; the applied remote change feeds
  `remoteApplied(notes/m.md, content)` — recording nothing but rebasing the
  baseline; received `.hist/` documents are materialized as ordinary files,
  **uninterpreted** — the app has no history viewer.

### desktop exposes lifecycle controls; mobile shows the same status without them (R17)

- **Arrange:** the control surface instantiated once for **desktop** (daemon
  present) and once for **mobile** (in-process engine).
- **Act:** enumerate the status fields and available controls in each.
- **Assert:** both expose the **same status fields** (running / paused / offline,
  last-sync time, un-synced count, error state, conflict list); desktop offers
  install + start/stop/pause + sync-now; **mobile** offers **no**
  start/stop/pause (the engine is the app) — sync-now/status only.

## Obsidian control plane parity (R22)

### the Obsidian plane offers the same surface for the open vault, running no sync

- **Arrange:** the Obsidian control plane for the currently open vault.
- **Act:** enumerate its capabilities.
- **Assert:** it can install/bootstrap the daemon, enter the vault's connection
  parameters, start it, and show/adjust status and controls — for the open vault —
  and it runs **no** replication of its own (the daemon syncs).

## Bundled install and first-device setup (R21, D9)

### manual connection entry ends in the identical setup as a URI paste

- **Arrange:** the setup surface on a first device (no setup-URI exists yet);
  a reachable daemon.
- **Act:** enter the endpoint, database, server user, server password, and the
  passphrase manually; submit.
- **Assert:** the resulting non-secret profile and secret-store contents are
  identical to what a setup-URI paste of the same connection would produce;
  the vault is handed to the daemon and syncs — the URI is only a transfer
  format between devices, not a required input.

### the surface emits a setup-URI the other front-ends can decode

- **Arrange:** a configured vault (profile + secrets present).
- **Act:** ask the surface for a setup-URI for the next device.
- **Assert:** the output is an `entropy-sync://setup#…` string plus a freshly
  generated transfer secret; decoding with that secret (any front-end's
  decoder) recovers exactly the endpoint, database, server user, and server
  password; the E2EE passphrase appears nowhere; a wrong secret is rejected.

### install-from-bundle registers autostart and starts the daemon

- **Arrange:** the entropy app on desktop with the daemon binary bundled in
  its package; no daemon running (no discovery advertisement); a recording
  process runner.
- **Act:** trigger the sync surface's single install action.
- **Assert:** the bundled binary is copied to the install location and made
  executable; the autostart service definition is written and loaded with
  `run --state-root <state root>`; the surface then polls discovery and
  attaches; re-triggering with a daemon already running attaches without a
  second install (R21 idempotence).

## The standalone sync console (desktop)

### the console lists every vault the daemon serves, not one active vault

- **Arrange:** a running daemon serving two vaults with different states (one
  healthy, one paused with a conflict); the console attached to it.
- **Act:** read the console's vault list; pause the healthy one from the
  console; run sync-now on the other.
- **Assert:** both vaults appear with their state, last-sync time, un-synced
  count, error slot and conflict paths; the control actions take effect on the
  daemon (its authoritative status reflects them) and are visible to any other
  attached front-end; the console never resolves a conflict itself.

### adding a vault names its folder and ends with a syncing vault

- **Arrange:** the console attached to a running daemon; a vault folder on disk
  that the daemon does not serve yet.
- **Act:** add a vault: choose that folder, accept the folder name as the vault
  id, supply the connection (setup-URI paste or manual entry) and the
  passphrase, submit.
- **Assert:** secrets land in the OS secret store keyed by vault, the
  non-secret profile is persisted, the profile is handed to the daemon over the
  control channel, and the daemon serves the vault with no restart; a second
  vault pointed at the same (endpoint, database) is refused with a clear error
  and nothing is stored.

### the console shows the daemon's log and its install state

- **Arrange:** a machine with neither the entropy app nor Obsidian, the console
  installed, no daemon running.
- **Act:** open the console; trigger install-and-start; then open the log view.
- **Assert:** before the action the console reports the daemon as not running
  and offers exactly one install action; after it, the console attaches to the
  now-running daemon (bundled binary installed, autostart registered); the log
  view shows the tail of the daemon's log file from its state directory, and
  reports plainly when no log exists yet.

### a folder added without a connection is listed as unconfigured and persists

- **Arrange:** the console (with or without a running daemon) and a vault
  folder on disk.
- **Act:** add the folder alone — no setup-URI, no manual connection, no
  passphrase; then restart the console.
- **Assert:** the vault is listed as **not configured**, showing its folder and
  no sync status; nothing was sent to the daemon (its own vault list is
  unchanged) and no secret was stored; the entry survives the restart; adding
  it required no running daemon.

### configuring a pending folder later ends with a syncing vault

- **Arrange:** the console attached to a running daemon, with an unconfigured
  folder entry added earlier.
- **Act:** supply that entry's connection (setup-URI paste or manual entry)
  plus the passphrase.
- **Assert:** the outcome is identical to configuring at add-time — secrets in
  the OS secret store, non-secret profile persisted, profile handed to the
  daemon, vault served with no restart — and the entry is no longer listed as
  unconfigured, because the daemon now reports it.

### an entry the daemon already serves is dropped; removing one touches nothing

- **Arrange:** an unconfigured entry for a vault id that another front-end then
  configures on the daemon; plus a second unconfigured entry.
- **Act:** refresh the console; then remove the second entry from the list.
- **Assert:** the first entry disappears from the unconfigured list (no
  duplicate beside the daemon's own row for that vault); removing the second
  deletes no file in its folder and no document on the server, and leaves the
  daemon's vault list untouched.

### one pasted string carries its own transfer secret, and the split form still works

- **Arrange:** a configured vault whose setup-URI the surface emits.
- **Act:** emit the string; paste it, alone, on another front-end; then emit the
  **split** form (URI without the embedded secret, secret separately) and paste
  those two.
- **Assert:** the single string configures the vault with no second field
  needed; the split pair configures it identically; a string whose secret was
  stripped is refused until the secret is supplied; a wrong secret is refused in
  both forms; the E2EE passphrase is in neither form and is always asked for
  separately.

### setup asks for the passphrase twice only when it creates the vault

- **Arrange:** two connections — one to a database with no `meta`, one to a
  database that already holds a vault.
- **Act:** run setup against each.
- **Assert:** against the empty database the surface reports that the vault is
  being created and refuses to proceed until the passphrase is entered twice
  and both entries match; against the populated one a single entry proceeds,
  and a wrong passphrase is refused by the check value rather than by a
  confirmation field.

### attaching a folder that already has files states how many

- **Arrange:** a database that already holds a vault; a folder with several
  files in it; and, separately, an empty folder.
- **Act:** run setup for each folder.
- **Assert:** the non-empty one reports the number of files that will become
  the vault's content and proceeds on confirmation — it is never refused; the
  empty one proceeds with no such step.

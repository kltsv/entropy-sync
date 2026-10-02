---
name: vault_sync_control
description: The target-agnostic control-plane and installer behaviour for sync — first-run per-vault setup, daemon install/bootstrap, lifecycle controls and live status, conflict surfacing, and (Flutter only) the mobile in-process engine. Realized by both the entropy app and the Obsidian plugin as interchangeable control planes over one shared daemon.
status: draft
---

# Vault sync control

## Purpose

Sync needs a **control surface**: something that sets a vault up, installs and
drives the daemon, and shows the owner what sync is doing. This module is that
surface — **target-agnostic behaviour** realized by **three** front-ends that are
**interchangeable control planes over the same daemon**: the entropy Flutter app,
the Obsidian desktop plugin, and the **standalone sync console** — a small
desktop app that is *only* this surface, for owners who want to run and watch
the daemon without opening any editor or the entropy app (each declares
`implements: vault_sync_control`; R7, R22). Neither front-end runs replication of
its own on desktop — they control the external daemon (`vault_daemon`),
which does the syncing (N3).

It also covers the **one platform exception**: on **mobile** there is no daemon
(the sandbox forbids one), so the Flutter app **embeds all three modules**
(`vault_sync`, `vault_crypto`, `vault_hist`) and runs the engine
**in-process** while the app is open (R11, RV6). That in-process wiring is
Flutter-only; the Obsidian plugin is desktop-only.

The behaviour here is: **install/bootstrap** the daemon, **configure** a vault
(minimal, per-vault), **control** it (start/stop/pause/sync-now), **show** live
status, and **surface conflicts** — the same surface on every platform, differing
only in engine placement (out-of-process daemon on desktop, in-process on mobile)
and in the daemon's install *source* (R17, R21).

## Inputs

- **First-run setup input** from the owner, per vault: a **setup-URI** — one
  copyable connection string carrying the non-secret connection (endpoint +
  database + server credentials) encrypted under a transfer secret that, by
  default, **travels inside the same string** — **plus the E2EE passphrase**;
  and the vault selection (the folder on desktop; on mobile the app *is* the
  vault client). This is the minimal parameter set (R23, D9).
- **The daemon binary source** (desktop): the entropy app has the binary
  **bundled** in-package; the Obsidian plugin **downloads** the matching
  OS/architecture binary from a public release channel (R21, D11).
- **The running daemon's state** (desktop): read from the daemon's local control
  channel (`vault_daemon`, R18) — status, un-synced count, conflicts.
- **The control token** (desktop): the daemon's local shared secret, read from the
  user's account, to authenticate to the channel (R19).
- **The device's OS secret store**: where this module writes and reads a vault's
  secrets (passphrase, server password), keyed by vault (R23, C11).

## Outputs

- **A configured vault**: a per-vault connection profile handed to the daemon (or,
  on mobile, to the in-process engine), with **secrets stored locally** in the OS
  secret store keyed by vault and **never** written into the vault or synced (R23).
- **An installed, registered, running daemon** (desktop) — at the correct version,
  set to autostart, reached over the control channel (R21).
- **A live status display**: at least running / paused / offline, last-sync time,
  count of un-synced changes, and an error state (hub unreachable / bad
  passphrase); plus the conflict list (R17).
- **Control effects**: start / stop / pause / sync-now / edit-connection applied to
  the daemon (desktop) or the in-process engine (mobile), reflected across every
  attached front-end (R20).

## Behavior

### Per-vault setup, minimal parameters, secrets local (R23, D9)

- Configuration is **bound to a specific vault**, not a single global setting; a
  different vault uses its **own** profile, and the daemon can serve many vaults
  concurrently (R23).
- Setup asks for the **minimal** set: paste one **setup-URI** plus the passphrase
  (D9). The URI carries endpoint + database + server credentials encrypted under
  a transfer secret. **The secret is part of the string by default** — one paste,
  one field: splitting it into two inputs only pretends to protect anything when
  both halves travel together, which is what actually happens between one owner's
  devices. What it does buy, for free, is that a string found *without* its
  secret is useless, so a front-end must **also accept the two apart**: a URI with
  no embedded secret plus the secret supplied separately (the split form is what
  a spoken or scanned second channel would use). The front-end decodes either
  form, stores the **passphrase and server password in the OS secret store keyed
  by vault**, and keeps the non-secret connection with the profile. The connection config is **not** stored inside the vault (the
  passphrase cannot live in the vault it encrypts) and secrets are **never** synced
  to the server (R23, C11).
- **The very first device has no URI yet**, so the setup surface also accepts
  the connection **entered manually** (endpoint, database, server user, server
  password) — the setup-URI is the *transfer format between devices*, not the
  only input. Both modes end in the identical profile + secret placement.
- **Setup tells the two situations apart before it commits.** With the
  connection in hand the surface checks whether the database already holds a
  vault (its `meta` document):
  - **it does not** — this device *defines* the vault, and its passphrase
    becomes the vault's key with nothing to check it against. A typo here is
    only discovered on the next device and is unfixable afterwards, so the
    surface **asks for the passphrase twice** and proceeds only when both
    entries match. This is the one place a confirmation is warranted; when the
    vault already exists the check value catches a typo immediately, so a
    single field is enough.
  - **it does** — this device *attaches*. If its folder already holds files
    (a restored backup, a reinstall, a folder copied by hand — all first-class
    scenarios, never refused), the surface states **how many files** are about
    to become this vault's content and proceeds on confirmation: the merge
    itself is safe (identical files only repair the cursor, differing ones are
    ordinary local edits, collisions become conflicts with both versions kept),
    but the count is what catches the wrong folder before it is uploaded.
  Either way the daemon's own re-attach rules do the work; the surface only
  makes visible which of the two is happening.
- **The surface emits a setup-URI for the next device**: for a configured
  vault it produces **one copyable string** with a freshly generated transfer
  secret inside it, byte-compatible with every front-end's decoder and with the
  daemon CLI's `setup-uri` verb (which can also emit the two apart). The E2EE
  passphrase is **never** embedded — the receiving device asks for it
  separately (D9).
- **Setup ends with a syncing vault, not a stored form.** On desktop the
  front-end **hands the profile to the daemon** over the control channel (the
  add/edit-vault command, `vault_daemon`): the running daemon registers
  the vault and starts serving it without a restart, and the registration is
  idempotent (re-sending the same vault attaches, R20). On mobile the profile
  configures the in-process engine directly. Either way, completing setup is
  sufficient for the first sync to begin (R21, R23).
- Opening a different vault uses that vault's own profile (R23).
- **Setup warns about a shared target, and lets the owner proceed.** Before
  storing anything, setup checks the decoded (server endpoint, database)
  against the targets already claimed by other configured vaults. If a
  **different** vault already uses that same endpoint and database, setup does
  **not** store anything yet: it states the consequence — both folders become
  **one vault** and converge to the same content set (each side pushes its own
  files and pulls the other's; same-path differing files become ordinary
  conflicts with both versions kept), and the **same E2EE passphrase** is
  required or the new folder cannot read what the other wrote — and names the
  vault already using that database. It proceeds only on confirmation, and
  then registers with the daemon's **shared-database acknowledgement**
  (`vault_daemon`). Declining stores nothing. This mirrors the non-empty-
  folder case above: the hazard is aiming two *different* vaults at one
  database by mistake, so the surface makes the merge visible rather than
  forbidding it — putting one vault in two folders is the owner's to choose.
  Re-configuring the **same** vault to its own target is neither a collision
  nor a prompt.
- **Setup refuses a colliding folder outright.** A chosen root that is the
  same directory as another configured vault's — or **nested** either way — is
  **rejected with a clear error and nothing is stored**, with no confirmation
  offered. Unlike a shared database this cannot be made safe by consenting to
  it (`vault_daemon` explains why), so the surface catches it at the
  point the folder is chosen rather than letting setup travel to the daemon to
  fail there.
- **Claims are held for exactly as long as the vault is configured.** On
  success the vault **claims** its target so a later setup can detect the
  collision, and **removing or disconnecting a vault releases its claim** —
  a vault that no longer exists must never make its database look occupied.
  The claim list is non-secret and kept outside every vault, shared across
  front-ends so a target claimed via the app is seen by the Obsidian plugin
  and vice-versa.

### Daemon install / bootstrap — idempotent; source is front-end-specific (R21)

- From a **single user action** the daemon ends up **installed at the correct
  version, registered for autostart, and running** — **idempotently**: an already-
  installed or already-running daemon is **attached to or upgraded, never
  duplicated** (R21).
- The **install source differs by front-end**: the **entropy app installs the
  bundled binary** with no download; the **Obsidian plugin downloads** the matching
  OS/architecture binary from a public release channel and **verifies its
  integrity** (checksum/signature) before installing (R21, D11).
- **The Obsidian release is installable through BRAT.** Manifest, script and
  styles are individual release assets. The plugin carries the exact daemon
  version and per-OS/CPU binary digests generated by that release's build;
  bootstrap fetches that immutable version's matching asset, never a moving
  latest asset. The owner enters neither a release URL nor a checksum. Invalid
  metadata or bytes fail before replacing an installed binary; verified
  installation is atomic and an unsupported platform is reported explicitly.
- **The app carries the daemon inside its own package** (macOS: inside the
  `.app` bundle) and, when no running daemon is discovered, its sync surface
  offers the single install action: copy the bundled binary into the daemon's
  install location, register the autostart service, start it, and attach —
  after which the same surface proceeds to per-vault setup. When a daemon is
  already running, the action is an attach, never a second install (R21).
- The only user input to bootstrap is the minimal connection parameters (R23).
- Autostart is **on by default**; there is no autostart toggle in the v1 UI (D10).
- **The service carries the daemon's name** (`daemon-modules` R12): the
  daemon is `entropyd`, registered as `com.entropy.daemon` (launchd) or
  `entropyd` (systemd). No other name is looked for or retired — nothing was
  ever released under one.
- **Autostart is a persistent OS service** the front-end writes and loads: a
  launchd LaunchAgent on macOS, a systemd *user* service on Linux — a definition
  that runs the installed daemon binary with the vault config and relaunches it,
  so the daemon starts on login and keeps running after any front-end closes
  (R17). Registration is **idempotent**: re-registering replaces the existing
  service definition rather than adding a second one, and it can be **unregistered**
  (the service definition removed and unloaded).

### Attach to a shared, authoritative daemon (R18, R20)

- On opening, a front-end **discovers** whether a daemon is already running and, if
  so, **attaches without re-setup**, immediately showing its live state (R18, R20).
- **Multiple front-ends attach at once** and all see the **same authoritative
  state**; a control action from any one takes effect on the daemon and is
  **reflected in every other** connected front-end within seconds (R20).
- Closing a front-end **does not stop** the daemon; sync continues headless (R17,
  R18).

### Authenticate to the control channel (R19)

- To read status or issue commands (desktop), the front-end **presents the
  daemon's local token** (read from the user's account). The channel is local-only
  and carries only control/status — never vault plaintext (R19, C3).

### Status display and lifecycle controls (R17, D10)

- The front-end shows, per vault, at least: **running / paused / offline**,
  **last-sync time**, **count of un-synced changes**, and an **error state** (hub
  unreachable / bad passphrase).
- The **v1 control set** (per vault): enable/disable sync, status, **sync-now**,
  conflict list, connection setup/edit (D10). Deferred: a separate pause-vs-disable,
  restart-daemon, log/health access, per-file "N versions", an autostart toggle.
- **A reported error must be actionable, in place.** Showing an error whose
  only remedy is removing the vault and adding it again is not a surface, it
  is a dead end — and the vault's local folder and its history are exactly
  what the owner cannot afford to gamble with. Specifically, a vault whose
  **passphrase fails verification** offers **re-entering the passphrase** on
  the vault itself, and re-entering it is enough to bring the vault back.
  Nothing about the vault is deleted, re-created or re-configured to do it.
- This case is not hypothetical and is not confined to setup: the passphrase
  is read from the secret store **when a vault starts**, so a wrong or lost
  one surfaces on the next daemon restart — days after setup, on a vault that
  has been syncing happily the whole time, because until then the running
  engine held its key in memory. A surface that only offers passphrase entry
  during first-run setup cannot reach that vault at all.
- **Desktop:** the front-end performs first-time install/registration and can start
  / stop / pause the daemon; the daemon keeps running independently once installed
  (R17). **Mobile:** the app shows the **same status** for its in-process engine
  but has **no lifecycle controls** — the engine *is* the app; it runs while the
  app runs (R11, R17).

### Conflict surfacing (R9 at the surface)

- When the daemon (or the in-process engine) reports a conflict — a deterministic
  winner chosen and the loser rescued into history — the front-end **surfaces it**
  in the status/conflict list and notifies the owner. The front-end never resolves
  conflicts itself and never shows `*.conflict` files (there are none); it only
  presents what the layer decided (R9, R17).
- **What R9 means, and what it does not forbid.** Sync never merges content
  *automatically*, and no merge is offered *in the conflict path*: the
  winner is chosen by LWW at sync time, a losing text version is already a
  branch in history, and leaving it there forever is a valid outcome. **Deliberate
  reconciliation of divergent history lineages is a different act** — later,
  when the owner chooses; on a divergent line, which needs no conflict to
  exist; decided by the owner, not by a rule; producing an ordinary new
  version plus a `merged` marker (`vault_hist`). It belongs to the **history
  surface** — today the history command line (`vault_hist_cli`), later
  whatever renders history — and never to a prompt at conflict time. The
  conflict list stays exactly what it is.
- **The divergence count is carried as data.** Beside the un-synced count
  and the conflict list, the daemon's status carries how many **files** have
  a divergent line (`vault_daemon`). Whether and how a front-end shows
  it — a badge on the vault card, something in a history view — is the
  later presentation effort; this module only says the number is there.
- **Modules are carried as data too** (`daemon-modules` R1, R3): each
  vault's status names the modules it enables and any module that is
  **degraded** with its error — a vault whose history cannot write keeps
  syncing, and a front-end can say so instead of showing an error state
  that is not one. The console shows both; the other front-ends may.

### Mobile in-process engine (R11, RV6) — Flutter only

- On mobile there is **no daemon**. The Flutter app **embeds all three modules**
  and runs the same shell logic **in-process**, **only while the app runs** —
  acceptable because mobile has no shared folder and no CLI/Obsidian writers,
  so the phone is just another client (R11).
- **The app's plaintext cache is a vault folder in its sandbox.** The in-process
  engine materializes logical documents as real files there and syncs that
  folder exactly as the daemon syncs a desktop vault (same shared shell logic —
  encrypt on the way out, decrypt and materialize on the way in, conflicts
  handled identically). App features (finance first) read and write **that
  folder** through their normal file paths, and every in-app save is reported
  to the engine — no watcher is needed because all mobile edits go through the
  app itself, with a rescan on launch as the backstop (RV1).
- **The app writes history for its own edits** (RV6): each in-app save is
  committed to history once it has settled, and an applied remote change is
  **not** committed at all — it was recorded by the writer that made it. A
  phone edit is therefore recorded once, on the phone, and reaches every
  desktop as ordinary synced `.hist/` files. The app needs **no history viewer**; `.hist/`
  documents it receives are stored uninterpreted like any other files (RV8).
- The mobile surface presents the **same status fields** as desktop and omits the
  daemon lifecycle controls (there is no separate process to start/stop). This
  wiring is realized only by the Flutter target; the Obsidian plugin does not
  implement it.

### The Obsidian plugin as a control/installer plane (R22)

- The Obsidian desktop plugin offers the **same surface** as the entropy app —
  install/bootstrap the daemon (R21), enter a vault's connection parameters (R23),
  start it, show/adjust status and controls (R17/R18) — **for the vault Obsidian
  currently has open**. It runs **no** replication of its own (N3). Installing the
  plugin and pressing one button yields a running daemon for that vault (R22).

### The standalone sync console (desktop)

The console is the same surface with **nothing else in it** — no editor, no
notes, no finance. Because it is not anchored to "the vault this app/editor
currently has open", it presents the daemon's **whole set of vaults** rather
than one:

- **A vault list** built from the daemon's authoritative status (R18, R20):
  every served vault with its state, last-sync time, un-synced count, error and
  conflicts, refreshed on a short interval; per vault the v1 controls
  (pause/resume, sync-now) and the setup-URI emitter (D9).
- **Adding a vault names its folder**: the owner picks the vault directory on
  disk (there is no "currently open vault" to infer), the vault id defaults to
  that folder's name, and the connection comes from a setup-URI paste **or**
  manual entry — after which the profile is handed to the daemon exactly as any
  other front-end does, so setup ends with a syncing vault (R21, R23).
- **A folder may be added before it is configured.** The console accepts a
  vault by **folder alone** — simply leaving the connection blank is what makes
  it unconfigured; there is no separate "add without setup" mode to choose
  first — (id still defaulting to the folder's name) and
  keeps it as its own **unconfigured entry** — the daemon is told nothing,
  because a vault without a connection is not something it can serve. The
  entry is listed beside the served vaults, plainly marked as not configured
  and carrying no status of its own, with the action to supply the connection
  later — identical setup, identical handoff, so configuring it then is what
  ends with a syncing vault. Removing such an entry is a list-only act: it
  touches nothing on disk and nothing on the server. Unconfigured entries are
  the one thing the console keeps for itself; everything else it shows is the
  daemon's. Consequently, as soon as the daemon serves a vault with that id —
  configured here or from any other front-end — the local entry disappears:
  the daemon's list is authoritative and the same vault is never listed twice.
  Adding a folder needs no running daemon (configuring one does), so the
  owner can collect folders first and connect them afterwards.
- **The daemon's own lifecycle is the console's main subject**: whether it is
  installed and running, the single install-and-start action (R21), and a view
  of the daemon's **log** (the state directory's log file, RV10) — the one
  surface where reading it is on-topic rather than clutter.
- It **carries the daemon binary** in its own package like the entropy app
  (D11), so installing the console is enough to get a running daemon on a
  machine that has neither the app nor Obsidian.
- It is a **peer control plane, not an owner**: it attaches to an
  already-running daemon without re-setup, its actions are reflected in every
  other attached front-end, and closing it never stops sync (R18, R20).

## Non-goals

- **Not the sync engine, protocol, or conflict math** (`vault_sync`), and **not the
  daemon's server-side behaviour** (`vault_daemon`) — this module is the
  control/installer/status *surface* and, on mobile only, the host that embeds the
  core.
- **Not the history algorithm or the history viewer.** The Obsidian history viewer
  is a separate adapter (a fork of an edit-history plugin), not this spec. The
  Flutter app *writes* history for its own edits (RV6, via the shared shell) but
  presents no history UI.
- **No replication inside a control plane on desktop** — the daemon syncs; front-
  ends only control it (N3, R22).
- **No global (non-per-vault) configuration**, and **no secrets in the vault or on
  the server** (R23, C11).
- **No deferred controls** in v1 (pause-vs-disable split, restart, logs, per-file
  version count, autostart toggle — D10).
- **Does not define visual chrome** — layout/styling is each target's own; this
  spec fixes the behaviour and the fields shown, not the pixels.

## Examples

### One paste sets up a vault (D9, R23)

The owner pastes a setup-URI and types the passphrase. The front-end decodes the
URI (endpoint + database + server credentials under the transfer secret), stores
the passphrase and server password in the OS secret store keyed by this vault, and
hands the daemon a per-vault profile. Nothing secret is written into the vault or
sent to the server.

### One button yields a running daemon (R21, R22)

In the Obsidian plugin the owner presses "Install & start". The plugin downloads
the matching OS/arch `entropyd` binary from the public release channel,
verifies its checksum, installs and registers it for autostart, and starts it for
the currently open vault — idempotently: if a daemon is already running it attaches
instead of installing a second one. In the entropy app the same button uses the
**bundled** binary with no download.

### Two front-ends see one state (R20)

The app and the plugin are both open on the same desktop. The owner presses
"sync-now" in the plugin; the app's "last-sync time" updates within seconds because
both read the same authoritative daemon status. Pressing "pause" in the app flips
the plugin's badge to paused. Closing the app leaves sync running.

### Mobile shows status, no lifecycle controls (R11, R17)

On the phone the app runs the in-process engine. The sync screen shows running /
offline, last-sync time, and un-synced count — but no start/stop/pause, because the
engine is the app. Editing a note and returning online syncs its content through
the same layer as the desktop daemon.

### A conflict is surfaced, not merged (R9)

The daemon reports that `notes/plan.md` had a conflict: a winner was chosen and the
loser saved to history. Both front-ends show `notes/plan.md` in a conflict list
with a "restore previous version from history" affordance. Neither offers a merge
UI in the conflict path and neither shows a `.conflict` file — there is none. If
the owner later wants to reconcile the two lines, that is the history surface's
deliberate act (`hist merge notes/plan.md …`), never something the conflict list
proposes.

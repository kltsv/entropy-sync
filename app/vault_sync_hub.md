---
name: vault_sync_hub
description: The sync hub as a managed object — provision a bare VPS into a CouchDB+TLS hub over SSH, then create the databases that host vaults and grant per-device access to them, each grant its own CouchDB user and its own labelled setup-URI, revocable alone. Realized by the standalone console and the daemon CLI; never by the Obsidian plugin.
status: draft
---

# Vault sync hub

## Purpose

Today the owner reaches a working hub by running a shell script and pasting its
output into a form. That is two skills too many. This module makes the **hub
itself a managed object**, so the whole path collapses to two acts:

- **"I bought a VPS, here is how to reach it"** — the surface provisions it.
- **"Here is a folder, use that hub"** — the surface picks the database and
  mints this device's access itself.

It is the *server* half of what `vault_sync_control` does for the *client*
half. A configured hub removes the copy-paste step from setup entirely: with
one on hand, attaching a folder is a choice from a list, not a pasted string.

The unit of access is a **grant**: one device, one CouchDB user, one labelled
setup-URI. That is what makes "рабочий мак" an object that can be revoked
alone, rather than a note-to-self beside a shared password.

## Inputs

- **A hub to add**: a label, an **SSH target** (`user@host`), the **domain**
  whose DNS points at it, and an **email** for the certificate. Nothing else —
  in particular no passwords the owner has to invent.
- **SSH authentication supplied by the environment**, never by this module: the
  agent, or the target's entry in the user's SSH config. The module runs the
  system `ssh` client and inherits whatever that resolves. It **never** stores,
  reads, or prompts for a private key or an SSH password (C1).
- **Operations**: provision a hub; list its databases; create or delete one;
  list, create or revoke a database's grants; emit a grant's setup-URI.
- **The hub's own state, read at use time**: the CouchDB admin credentials the
  provisioning generated, which live in the hub's environment file on the hub
  itself (C2).

## Outputs

- **A provisioned hub**: CouchDB 3 behind automatic TLS, the server settings
  the sync layer needs, reachable at the domain given.
- **An inventory**: the hub's databases, and per database the grants on it with
  their labels — enough for a surface to render the hub without asking the
  owner anything.
- **A grant**: a CouchDB user of its own restricted to one database, plus the
  **setup-URI and transfer secret** that carry it (byte-compatible with
  `vault_sync_control` D9, so a grant minted here pastes into any front-end).
- **Nothing secret at rest locally** (C1, C2).

## Behavior

### The hub record holds no credentials (C1)

- A hub is a **label, an SSH target, a domain and an ACME email** — all
  non-secret, all safe in an ordinary config file beside the vault profiles.
- Authentication is **delegated to the system SSH client**, so the key stays
  wherever the owner already keeps it. A hub the agent cannot authenticate
  simply reports that, with the target named, and no operation runs.
- The consequence is deliberate: a stolen laptop whose agent holds no key
  yields **no** access to the hub — not the server, and not the databases on
  it. Storing a private key would trade that away for convenience on an
  operation performed roughly once per server.

### Administration never crosses the public internet (C2)

- Every administrative call — listing databases, creating one, creating or
  revoking a grant — runs **through SSH against the hub's loopback CouchDB**,
  never against the public endpoint. The public endpoint stays what it is for
  clients: a TLS front door that only ever sees a device user.
- The **CouchDB admin password is read from the hub's own environment file at
  use time and discarded**. It is never copied to a device, never stored in a
  local secret store, and never travels anywhere but the loopback interface it
  came from. Nothing about the hub survives locally that an attacker could use.
- The admin password is therefore **shown to the owner exactly once**, when
  provisioning generates it, for their own records (server maintenance is
  outside this module). Losing it costs nothing: it can be read back from the
  hub over SSH at any time.

### Provisioning is idempotent, and says what it is waiting for

- Provisioning turns a bare Debian/Ubuntu host into the hub: install the
  container runtime if absent, write the hub's files, start CouchDB and the TLS
  proxy, apply the settings the sync layer needs (every request authenticated,
  a request cap generous enough for streamed attachments, a document cap, the
  revision limit left at its default — it is the offline-merge engine).
- **Re-running is safe**: existing data, users and databases are left alone. A
  hub that already runs is *attached to*, not rebuilt — the same idempotence
  `vault_sync_control` requires of the daemon install.
- The two things that commonly are not ready yet — **DNS not yet pointing at
  the host**, and **ports 80/443 closed** — are reported as themselves, naming
  what to fix, and are recoverable by re-running once fixed. Neither leaves a
  half-built hub.
- A host that is **already serving something else** on those ports is reported
  before anything is changed. Provisioning never takes a port from a running
  service, and never deletes data it did not create.

### One database per vault; deleting one is destructive and says so

- Databases are the unit that hosts a vault, one each — the isolation
  `vault_daemon` enforces on the client side, stated here on the server
  side. Creating one applies the same restriction the provisioning does: only
  its own grants may read or write it.
- **Deleting a database destroys the vault's server copy.** The surface states
  what is being destroyed — the database, its grants, and the fact that devices
  still holding a local copy will stop syncing — and proceeds only on explicit
  confirmation. It is never offered as a tidy-up of something merely unused.

### A grant is one device: its own user, its own URI, revocable alone (R1)

- Creating a grant **generates a password, creates a CouchDB user of its own,
  adds it to that database's members, and emits the setup-URI and transfer
  secret** carrying it. The grant's **label** is what the owner types —
  "домашний мак", "рабочий мак" — and it is the user's identity on the hub, not
  a local annotation.
- Any number of grants may exist on one database; that is how a vault reaches
  many devices. Each carries **different** server credentials, so the labels
  mean what they look like they mean.
- **Revoking a grant deletes its user and drops it from the database's
  members.** That device stops syncing; every other device is untouched and
  needs no reconfiguration. This is the whole reason grants exist rather than
  one shared password with notes beside it.
- A grant's password is **not recoverable** once emitted — CouchDB cannot
  reveal it. Re-emitting a URI for the *same* grant is therefore not offered;
  a device that lost its string gets a **new grant**, and the old one is
  revoked. This keeps "a URI is spent once redeemed" true rather than aspirational.

### With a hub on hand, attaching a folder has nothing to paste (R2)

- When a hub is configured, setup offers **its databases as a list**. The owner
  picks a folder and a database; the surface **mints a grant for this device
  automatically**, labelling it after the device, and configures the vault from
  it. No URI is ever displayed, copied, or pasted.
- Pasting a setup-URI stays fully supported and unchanged — it is how a device
  with **no** hub configured joins, which is every device but the owner's own
  administrative one (`vault_sync_control`).
- Creating a vault on a hub that has **no** database for it yet is one act:
  the surface creates the database and the grant together.

### The passphrase is the one thing that is never automated

- The **E2EE passphrase is never generated, stored, transmitted or inferred**
  here. The hub cannot know it — it holds ciphertext only (`vault_crypto`) —
  so "pick a folder and a hub, and the rest is automatic" is true of everything
  *except* this, and the surface says so rather than implying otherwise.
- On a database that already holds a vault the passphrase must be **the same
  one**, or the device cannot read what the others wrote. Where the surface
  knows it is attaching rather than creating, it says which of the two is
  happening — the same distinction `vault_sync_control` already draws.

### Where this lives (C3)

- Realized by the **standalone console** and by the **daemon CLI**, which are
  the same capability at two surfaces: everything the console can do to a hub
  is available headless, so a hub can be provisioned and granted from a script
  or over SSH from another machine.
- **Not realized by the Obsidian plugin.** Administering a server is not an
  editor's business, and the separation is structural rather than a convention
  to remember: the plugin does not link the code this module lives in.

## Non-goals

- **Not buying or destroying the VPS**: the provider, the billing and the
  machine's existence are outside this module. It configures a host it is
  handed.
- **Not backups, not monitoring, not fleet management.** One owner, a handful
  of personal hubs.
- **Not server-side inspection of vault content** — the hub holds ciphertext
  only, so there is nothing to look at there. Inspection is client-side
  (`vault_daemon`).
- **Not a second sync path.** This module configures the hub that
  `vault_sync` replicates against; it never moves vault data itself.
- **Not general SSH administration**: no shell, no arbitrary commands, no
  package management beyond what provisioning needs.
- **Not the client half** — folders, profiles, daemon lifecycle and status all
  stay in `vault_sync_control`.

## Examples

### A bare VPS becomes a working hub (R1)

The owner adds a hub: label "home", target `root@203.0.113.10`, domain
`sync.example.com`, an email. The surface checks it can reach the host and that
the domain resolves to it, provisions, and reports a hub with no databases yet.
The admin password is shown once. Nothing secret is kept locally.

### A folder starts syncing with nothing typed but a passphrase (R2)

The owner picks a folder and the "home" hub, and a database from its list. The
surface mints a grant labelled after this device, configures the vault, and
sync begins. The only thing typed is the E2EE passphrase — twice, because this
database is empty and the vault is being created.

### A laptop is lost (R1)

The owner opens the hub, sees the grants on the vault's database — "домашний
мак", "рабочий мак", "телефон" — and revokes "рабочий мак". That device stops
syncing at its next attempt. The other two never notice, and no passphrase or
connection changes anywhere.

### DNS has not propagated yet

Provisioning reports that `sync.example.com` does not yet resolve to the host,
names both values, and changes nothing. An hour later the same action runs
again and completes — the run is idempotent, so the first attempt cost nothing.

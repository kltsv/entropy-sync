---
tests: vault_sync_hub
---

# Vault sync hub — test-spec

Framework-agnostic cases for `vault_sync_hub`. Two seams make them runnable
without a VPS: the **command runner** (production: the system SSH client) and
the **admin transport** (production: CouchDB over SSH on the hub's loopback).
Tests drive a real CouchDB through the second seam, so the admin logic is
exercised against a real server rather than a mock of one.

## The hub record holds no credentials (C1)

### a hub is stored as label, target, domain and email — nothing secret

- **Arrange:** an empty state root.
- **Act:** add a hub with a label, an SSH target, a domain and an email; read
  the persisted record back.
- **Assert:** all four values round-trip. The stored form contains **no**
  private key, no SSH password and no CouchDB password — a search of the whole
  record for any secret-shaped field finds nothing. Adding the same label again
  updates that hub rather than creating a second one.

### an unreachable hub reports its target and runs nothing

- **Arrange:** a hub whose runner fails authentication (as the system client
  does when the agent holds no key).
- **Act:** provision it, then list its databases.
- **Assert:** both report that the hub cannot be reached, naming the SSH
  target; **no** administrative call is attempted, and the stored record is
  unchanged.

## Administration never crosses the public internet (C2)

### every admin call goes to the hub's loopback, never the public endpoint

- **Arrange:** a hub with a domain, and a runner that records every command.
- **Act:** list databases, create one, create a grant, revoke it.
- **Assert:** every recorded command targets the **loopback** CouchDB on the
  hub; none of them mentions the public domain. The domain appears only in the
  emitted setup-URI, which is for clients.

### the admin password is read from the hub at use time and not kept

- **Arrange:** a provisioned hub whose environment file holds the admin
  credentials.
- **Act:** perform an admin operation, then inspect everything stored locally.
- **Assert:** the operation succeeds, and the admin password appears **nowhere**
  in the local state — not in the hub record, not in the secret store. Changing
  the password on the hub and repeating the operation still succeeds, because
  it is read fresh each time.

## Provisioning (R1)

### provisioning is idempotent

- **Arrange:** a host that provisioning has already turned into a hub, holding
  a database with documents in it.
- **Act:** provision the same hub again.
- **Assert:** it succeeds; the existing database, its documents and its users
  are **unchanged**; no port is taken from anything already running.

### DNS not yet pointing at the host is reported, and nothing is changed

- **Arrange:** a hub whose domain resolves to a different address.
- **Act:** provision.
- **Assert:** the failure names both the domain and the address it resolves to,
  the host is left untouched, and a later run after DNS is fixed completes.

### a port already in use is reported before anything is changed

- **Arrange:** a host already serving something on the hub's ports.
- **Act:** provision.
- **Assert:** the conflict is reported naming the port; nothing was installed,
  started or deleted, and the pre-existing service is still running.

## Databases

### creating a database restricts it to its own grants

- **Arrange:** a provisioned hub.
- **Act:** create a database, then read its security settings.
- **Assert:** it exists, has no members yet, and is not readable by an
  arbitrary authenticated user; it appears in the hub's database list.

### deleting a database is refused without explicit confirmation

- **Arrange:** a hub with a database holding documents and two grants.
- **Act:** delete it without confirmation; then with it.
- **Assert:** the first attempt changes nothing — database, documents and
  grants all survive. The second removes the database **and** its grants' users,
  leaving no orphan user behind.

## Grants: one device, one user, one URI (R1)

### a grant creates its own user and emits a working setup-URI

- **Arrange:** a hub with an empty database.
- **Act:** create a grant labelled "рабочий мак".
- **Assert:** a CouchDB user of its own exists and is a member of that
  database; the emitted setup-URI decodes with its transfer secret to exactly
  that endpoint, database, user and password; and those credentials **can read
  the database** while an unauthenticated request cannot.

### two grants on one database carry different credentials

- **Arrange:** a database with one grant.
- **Act:** create a second grant with a different label.
- **Assert:** both are listed with their labels; their users differ and their
  passwords differ; **both** can read the database. The setup-URIs are not
  interchangeable — each decodes to its own user.

### revoking one grant leaves the others syncing

- **Arrange:** a database with three grants, all able to read it.
- **Act:** revoke the middle one.
- **Assert:** its user is gone from the database's members **and** from the
  server's users; its credentials no longer authenticate. The other two still
  read the database with the credentials they already had — no reconfiguration,
  no passphrase change. Revoking it again is a no-op, not an error.

### a grant's password is never recoverable, so re-emission is not offered

- **Arrange:** a database with one grant, whose URI was already emitted.
- **Act:** attempt to emit that same grant's URI a second time.
- **Assert:** it is refused with a clear explanation, pointing at creating a
  new grant and revoking the old one. No stored copy of the grant's password
  exists to emit from.

## Attaching a folder with a hub on hand (R2)

### picking a hub and a database configures a vault with nothing pasted

- **Arrange:** a configured hub with one database, and a local folder.
- **Act:** attach the folder to that database, supplying only the passphrase.
- **Assert:** a grant is minted automatically and labelled after this device;
  the vault is configured from it and reaches the daemon; **no setup-URI is
  shown or required** anywhere in the flow. The grant appears in the database's
  grant list.

### creating a vault on a hub with no database yet is one act

- **Arrange:** a configured hub with no databases, and a local folder.
- **Act:** attach the folder, naming a new database.
- **Assert:** the database and the grant are created together and the vault is
  configured; the surface reports that the vault is being **created** (so the
  passphrase is confirmed twice), not attached.

### pasting a setup-URI still works with no hub configured

- **Arrange:** no hubs configured; a setup-URI and its transfer secret.
- **Act:** attach a folder by pasting them.
- **Assert:** the vault is configured exactly as before — the hub feature adds
  a path, it does not replace the one every other device uses.

## Headless parity (C3)

### everything the console does to a hub is available from the CLI

- **Arrange:** a state root with a hub.
- **Act:** through the CLI alone — provision, create a database, create a grant,
  list grants, revoke one.
- **Assert:** each verb performs the same operation with the same outcome as
  the console's, against the same state root, and prints values a person can
  act on. A hub created by the CLI is visible to the console and vice-versa.

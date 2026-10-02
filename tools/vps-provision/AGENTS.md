# tools/vps-provision

Turns a bare Debian/Ubuntu VPS into the vault-sync hub and hands the owner the
values the app's setup form asks for. Driven by the `provision-sync-vps` skill —
read that for the owner-facing procedure; this file is the tool's surface.

## Files

- `provision.sh` — **run this, from your machine.** Checks SSH and DNS,
  generates the passwords, ships `remote-setup.sh` to the server and runs it,
  waits for the public endpoint, then mints the **setup-URI + transfer secret**
  with the local `entropyd` binary (repo `tools/`, `~/.entropy-sync/bin`,
  or either app bundle — `$ENTROPY_SYNCD` overrides) and prints everything.
  Secrets are printed once, never written to disk here.
- `remote-setup.sh` — the server side (runs there): Docker if missing, CouchDB 3
  + Caddy with automatic TLS under `/opt/entropy-sync`, the server settings the
  sync layer needs, one database, its own non-admin user, `_security` limited to
  that user, and a verification pass as that user.

```
tools/vps-provision/provision.sh --host root@IP --domain sync.example.com \
    --email you@example.com [--db vault] [--sync-password <existing>]
```

## Decisions worth keeping

- **One database per vault** (the daemon refuses two vaults on one database), so
  a second vault is another run with `--db`. The same non-admin user can be a
  member of several databases.
- **`_revs_limit` is left at 1000** — the revision tree *is* the offline-merge
  engine (`vault_sync` C7), not bloat.
- **`max_http_request_size` 4 GB / `max_document_size` 50 MB** — attachments
  stream whole (R7); bodies stay ~1.4 MB.
- **Idempotent, and honest about the one thing it cannot do**: CouchDB never
  reveals an existing user's password, so a re-run either takes
  `--sync-password` or rotates explicitly (`ROTATE_SYNC_PASSWORD=1`), which
  forces every configured device through setup again.
- **No `compressible_types` change**: gzip-encoded attachments are rejected by
  the client on purpose, and the default list excludes `application/octet-stream`.

## Verify

There is no VPS in CI, so the server-side script is exercised against a local
CouchDB instead — that covers everything except the Docker/Caddy install:

```bash
podman run -d --name couch-test -p 127.0.0.1:5985:5984 \
  -e COUCHDB_USER=admin -e COUCHDB_PASSWORD=provpw docker.io/library/couchdb:3
SKIP_DOCKER=1 COUCH_URL=http://127.0.0.1:5985 COUCH_ADMIN_PASS=provpw \
  SYNC_USER_PASS=syncpw123 DATABASE=vault-test bash remote-setup.sh
```

Checked that way: a fresh run, a re-run with the right password, the clear
refusal on a re-run with a new one, explicit rotation, and a second database for
the same user.

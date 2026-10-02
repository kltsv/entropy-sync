---
name: vault_sync
description: The document-opaque CouchDB replication client — an offline-first local replica with a revision tree over injected storage, the full replication protocol (longpoll changes with all leaves, revs-diff, bulk-get/bulk-docs, multipart attachments, local-only checkpoints), deterministic conflict detection with host-driven resolution, and a continuous engine with live change/conflict/status streams.
status: draft
---

# Vault sync

## Purpose

The vault is synchronized through a CouchDB hub. This module is the **client
side of that replication, written once in Dart** and reused verbatim by both
shells — the desktop daemon (`vault_daemon`) and the Flutter app
(`vault_sync_control`) (R1, R8, G4).

The module replicates **abstract documents** — it does not know they are files,
does not see plaintext paths or content, and never touches encryption (RV1).
What crosses it is whatever the shell hands it; in production that is the
**wire document** produced by `vault_crypto`, and in tests it is any opaque
payload. This opacity is a load-bearing property: the sync core is tested
without crypto and without history, on bare documents (RV1).

Concretely the module owns four things:

1. an **opaque document model** — id, body, at most one attachment, tombstone;
2. an **offline-first local replica** with a full **revision tree** per
   document, over storage the host injects (R3, R4);
3. the **standard CouchDB replication protocol** in both directions —
   longpoll change feed, revision-diff negotiation, bulk transfer, streamed
   multipart attachments, resumable local checkpoints (R6, R8, RV4);
4. **deterministic conflict detection** with **host-driven, idempotent
   resolution** (R9) and a **continuous engine** exposing change, conflict,
   and status streams (RV4).

We write this client ourselves because no turnkey Dart engine exists: PouchDB
is JS-only, Couchbase Lite does not replicate against Apache CouchDB directly,
and Dart `couchdb` packages are HTTP clients without a local replica,
revision tree, or checkpoints (C2).

## Inputs

- **Injected durable storage** for the replica's structured state (revision
  trees, leaf bodies, checkpoints, queues). The interface is key-value-shaped
  and host-supplied: the daemon backs it with a database file in its state
  directory, the app with its sandbox storage, tests with memory. The replica
  is created and owned by this module; the host only supplies durability.
- **An injected blob store** for attachment bytes, keyed by content digest —
  attachments stream through the module and rest in the blob store; they are
  never held whole in memory or inside the structured state (RV4).
- **An injected HTTP transport** — the module speaks the CouchDB REST protocol
  over HTTPS with basic-auth, but the socket layer is supplied by the host, so
  the same protocol code drives a real server or an in-process emulator in
  tests.
- **Local writes** from the shell: `put(id, body, attachment-bytes?)`,
  `delete(id)`. Bodies and attachments are opaque.
- **A replica identity**: an id unique per (vault, device), so two devices
  syncing one database never share checkpoints or collide.
- **Engine lifecycle calls**: `start()` / `stop()`, and an on-demand
  `syncNow()` single pass (used by tests and the shells' "sync now").

## Outputs

- **A converged local replica**: after replication, replica and server agree
  on every non-conflicting document, each carrying the revision tree needed to
  reconcile again later.
- **A change stream**: one event per document reaching a new winning revision —
  `{id, doc, deleted, origin}` where `origin` is `local` (created here) or
  `remote` (arrived from the server). The shells materialize files and drive
  history from exactly this stream; nothing polls (R6).
- **A conflict stream**: `{id, winner, losers}` whenever a document has more
  than one live leaf, with each loser's full document (body and attachment)
  available so the shell can rescue it (R9).
- **A status stream**: `{online, pendingPush, lastSeq, error?}` — live health
  for the control surfaces (R17): whether the hub is reachable, how many local
  revisions await push, the current pull checkpoint, and the latest error
  (unreachable hub, auth failure) if any.
- **Replication results** per discrete pass: documents transferred, new
  checkpoint, error if any.

## Behavior

### The opaque document model (RV1)

A document is `{id, body, attachment?, deleted}`:

- **`id`** — an opaque string. The module never parses it. (In production it is
  the HMAC id minted by `vault_crypto`; in tests it is anything.)
- **`body`** — an opaque JSON object. The module stores and transfers it
  verbatim.
- **`attachment`** — at most one, under the fixed name `data`, a byte stream.
  Attachment bytes live in the blob store keyed by digest; documents reference
  the digest. Attachments are never chunked into multiple documents and never
  base64-inflated into the body (R7, N5).
- **`deleted`** — a tombstone flag. Deletion is a revision with `deleted: true`
  and no content; the id survives and the deletion replicates (R15). `_purge`
  is never used — a purged document can resurrect from another replica (C7).

### Revisions and the revision tree (R3, RV4)

- Every write produces a revision `N-<hash>`: `N` is the parent's generation
  plus one; the hash is **32 lowercase hex characters, randomly generated**
  (RV4). Revision ids are minted locally and carry no content-derived
  information — nothing about a revision's plaintext can be inferred from its
  id (RV2's leakage budget).
- `put` creates the new revision as a child of the current winner and marks it
  `pending_push`; `delete` does the same with the tombstone flag. A `put`
  whose body and attachment are identical to the current winner's records
  nothing (write dedup).
- A `put` may name an **explicit parent revision** instead: the new revision
  is minted as that revision's child even when it is no longer the winner,
  creating a live branch — a **real conflict** for the conflict machinery.
  This is how a shell records a local edit that raced a pull: parented on the
  revision the edit was actually based on, so the concurrently-arrived remote
  revision stays a live leaf instead of being silently superseded (RV4).
  Dedup applies only to winner-parented writes.
- The replica stores, per document, the **tree of revision ids** — every known
  path `N-<hash>` back to a root (ids only, no ancestor bodies), the set of
  leaves, and each leaf's tombstone flag. **Bodies and attachment references
  are kept for every live leaf** — required to serve losers when a conflict is
  rescued — and for no other revision.
- The tree is what makes offline multi-master merge work: `revs-diff` compares
  trees to find what each side is missing, and the common ancestor
  distinguishes a fast-forward from a real conflict (C7).
- **Stemming**: each document's stored revision paths are capped at the
  replica's revision limit. The limit **mirrors the server's `_revs_limit`**
  (read once at engine start; default 1000). The client never lowers the
  server's `_revs_limit` — too short a history breaks common-ancestor finding
  and manufactures false conflicts (C7, §4.6 of the design).

### The local change log (R6)

Every accepted revision advances a monotonic `local_seq`. The replica exposes
an ordered feed of `{seq, id, changes}` rows from any starting sequence — the
same shape as the server's `_changes` — which is what push replication reads
and what the engine's change stream is built on.

### Pull — continuous longpoll (RV4)

Pull runs as a loop against the server:

1. `GET /{db}/_changes?feed=longpoll&since={last_seq}&style=all_docs&heartbeat=30000&limit=200`.
   **`style=all_docs` is mandatory** — without it conflicting leaves are
   invisible and conflicts silently never surface. `heartbeat` keeps the
   connection alive through proxies; the longpoll cycle **is** the realtime
   subscription (N10 satisfied without extra machinery).
2. For each change row, compare **all** listed leaf revisions against the
   local tree → the list of missing `(id, rev)` pairs.
3. Fetch missing revisions **with their revision branch** (`revs=true`), so
   they graft into the local tree rather than appearing unrelated:
   documents without attachments in batches via `POST /{db}/_bulk_get?revs=true`;
   documents with attachments one at a time via
   `GET /{db}/{id}?rev={rev}&revs=true&attachments=true` with
   `Accept: multipart/related`, the attachment **streamed into the blob
   store**, never buffered whole (RV4).
4. Insert the fetched revisions into the local tree with `new_edits=false`
   semantics, recompute each document's winner, emit change events
   (`origin: remote`) for documents whose winner changed, and conflict events
   for documents left with more than one live leaf.
5. Persist the row's `last_seq` **locally**. The sequence is an **opaque
   string** (CouchDB 3 sequences are not numbers). **No server-side `_local/`
   checkpoint documents are written — the local checkpoint is sufficient**
   (RV4).

The loop is **catch-up, then park**: on (re)connection it drains pending
changes with normal pulls, then parks a longpoll — so a reconnect ships and
receives the backlog before waiting. On real CouchDB a longpoll with a
heartbeat never times out on its own, so the parked request is **abortable**:
`stop()` cancels it, and a pass that outlives its engine generation (stopped
or restarted meanwhile) discards its results without grafting or writing
checkpoints (RV4). Disconnections reconnect with **exponential backoff**; the
`online` status flag reflects this loop's health.

### Push (RV4)

1. Take the revisions marked `pending_push` (local writes not yet confirmed
   by the server). The pending set is durable — a restart resumes it.
2. `POST /{db}/_revs_diff` with those revisions → the subset the server lacks.
3. Transfer: documents **without** attachments via `POST /{db}/_bulk_docs`
   with `new_edits: false`, each carrying `_revisions` (the full known ancestor
   path, capped at the revision limit) — **chunked** by document count and an
   approximate byte budget, with the pending set and push checkpoint advanced
   per successful chunk, so a first push of a large vault neither buffers the
   whole backlog nor exceeds a proxy's request-size cap; an HTTP 413 splits
   the chunk and retries smaller (a single document that still exceeds the cap
   surfaces as a clear protocol error). Documents **with** attachments via
   `PUT /{db}/{id}?new_edits=false` with a `multipart/related` body — the
   document JSON with `_attachments: {data: {follows: true, …}}` plus the
   attachment bytes streamed from the blob store — exactly as CouchDB's own
   replicator does. **A separate `PUT /{db}/{id}/data` is never used**: it
   would mint a server-side revision that does not exist in the local tree
   (RV4).
4. On success, clear `pending_push` for the confirmed revisions and advance
   the push checkpoint (a `local_seq` value, persisted locally).

Local writes **debounce push by ~2 s** (configurable), so a burst of rapid
saves ships as one batch.

### Conflict detection and resolution (R9)

A conflict is a document with more than one **live** (non-deleted) leaf.

- **The winner is a pure function of the tree**, identical on every replica
  and on the server — CouchDB's own algorithm, reimplemented locally so the
  local winner always matches the server's: a live leaf beats a deleted one;
  among live leaves the higher generation `N` wins; ties break to the
  lexicographically greater revision hash. No negotiation, no coordination.
- The module **never resolves conflicts itself** — it detects them and emits
  `conflict(id, winner, losers)`, each loser carried with its content. The
  shell does what it must (rescue per `vault_daemon` / `vault_hist`)
  and then calls **`resolve(id, loserRevs)`**: the module writes a deleted
  child revision onto each named losing leaf and pushes.
- Resolution is **idempotent**: resolving an already-resolved leaf (e.g. two
  clients resolved the same conflict concurrently) is a no-op that breaks
  nothing.
- **No line-level auto-merge, ever**; no `*.conflict` artifacts at this layer
  or any other (N7, D2).

### Offline-first (R3, R4)

- The local replica is complete and authoritative for its client: every read
  and write works with no network; writes queue as `pending_push`.
- Reconnecting reconciles both directions from the checkpoints; a week-long
  divergence merges the same way a one-second one does (S1). Only missing
  revisions transfer — an interrupted sync resumes from the checkpoint rather
  than restarting (R8).

### Every request is bounded in time (R4, RV4)

**A network that goes away silently must not be able to park a pass forever.**
Losing a network is not the same as being told so: a laptop that sleeps,
switches Wi-Fi or drops a VPN leaves TCP connections that are established on
this side and dead on the other. Reads on them never fail and never return.

So **every request carries a deadline**, and exceeding it fails the request as
`unreachable` — the same outcome as any other broken connection, which the
engine already knows how to retry:

- **connecting** is bounded on its own, so an unroutable host fails promptly
  rather than waiting out the operating system;
- an **ordinary request** is bounded from send to response headers;
- a **longpoll** cannot be bounded that way: it is *supposed* to park, and on
  a real CouchDB the heartbeat overrides any timeout, so a healthy one stays
  open for as long as the vault is quiet. What distinguishes it from a dead
  socket is precisely the **heartbeat** — so it is bounded by *silence*
  instead: if nothing at all arrives for appreciably longer than the
  heartbeat interval it asked for, the connection is dead and the request
  fails. A quiet vault keeps ticking; an unplugged one stops.

This matters more than a lost pass, because a pass that never returns holds
the serialization its shell relies on: every later `sync-now` queues behind it
and never returns either, so the surface shows an operation in flight forever
while status keeps reporting the vault healthy. A bounded request turns that
into an ordinary error the owner can see and the engine retries.

### The engine (RV4)

`start()` brings up the continuous loops (longpoll pull, debounced push) and
the streams; `stop()` quiesces them. `syncNow()` runs one discrete
pull-then-push pass and reports its result — the building block for tests,
`sync-now` controls, and hosts that prefer explicit scheduling. Status
transitions (`online` flips, `pendingPush` counts, errors) emit on the status
stream as they happen.

## Non-goals

- **Not a server-side sync engine** — the hard multi-master reconciliation is
  CouchDB's; this is the client protocol over it (N1). No server
  configuration, no database creation policy beyond what a shell asks for.
- **No knowledge of files, paths, or plaintext.** Turning files into documents
  and back is the shells' job; encrypting them is `vault_crypto` (RV1). This
  module never sees a vault path and never holds a key.
- **No encryption of its own** — it replicates what it is given. (In
  production everything it touches is ciphertext; the module neither knows nor
  cares.)
- **No history** — `vault_hist` rides above as ordinary documents.
- **No chunking, ever** (N5). One document per logical unit; the single
  attachment streams whole.
- **No auto-merge, no `_purge`, no server `_local` checkpoints** (N7, C7,
  RV4).
- **No file watching, no UI, no control channel** — shells and control planes
  own those.

## Examples

### Opaque round-trip

The shell puts `{id: "a1b2…64hex", body: {v: 1, n: "…", c: "…"}}`. The module
mints revision `1-3f9c…` (random hex), marks it pending, and pushes it via
`_bulk_docs` with `new_edits: false`. Another replica pulls the change, grafts
`1-3f9c…`, and emits `{id: "a1b2…", origin: remote}`. Neither replica ever
interprets the body.

### Longpoll delivers within seconds (R6, N10)

Replica B's longpoll is parked on the server with `since=42-xyz`. Replica A
pushes a revision; the server completes B's longpoll with the change row. B
grafts the revision, emits the change event, persists the new opaque
`last_seq`, and immediately re-issues the longpoll. Seconds, not polling.

### Conflict → deterministic winner + host rescue (S3, R9)

A and B both extend `3-x` offline: A mints `4-8a01…`, B mints `4-c37f…`.
After both sync, the document has two live leaves everywhere. Every replica
independently picks `4-c37f…` (higher hash). The module emits
`conflict(id, winner: 4-c37f…, losers: [4-8a01…])`; the shell rescues the
loser (per its rules) and calls `resolve(id, ["4-8a01…"])`; the module writes
a deleted child on the losing branch and pushes. If A and B both resolved
concurrently — same outcome, no error.

### Attachment streams, never buffers (R7, RV4)

An 8 MB encrypted blob is pushed as one `multipart/related` `PUT … ?new_edits=false`,
streamed from the blob store. Pulling it on another replica streams the
attachment body straight into that replica's blob store; peak memory is one
chunk, not 8 MB.

### Interrupted sync resumes (R8)

A pull of 500 changes dies after 300. The local checkpoint holds the last
processed row's sequence. The next pull asks the server for changes since that
sequence and transfers only the remaining ~200.

### Checkpoints are local-only (RV4)

Two devices sync the same database with different replica ids. Neither writes
`_local/` documents to the server; each persists its own pull `last_seq` and
push `local_seq` in its replica state. Wiping one device's state re-pulls from
zero without disturbing the other device or the server.

---
tests: vault_sync
---

# Vault sync — test-spec

Agnostic test cases for the `vault_sync` module, in strict Arrange / Act /
Assert form. The module is exercised on **bare opaque documents** — no crypto,
no history, no files (RV1). Terms used below:

- **replica** — one instance of the module: an offline-first local store with
  a revision tree per document, constructed over an injected in-memory durable
  store, an injected digest-keyed blob store, and an injected transport; each
  replica carries its own replica id.
- **server** — an in-process CouchDB double reached only through the injected
  transport; it implements `_changes` (longpoll, `style=all_docs`, heartbeat),
  `_revs_diff`, `_bulk_docs` (`new_edits=false`), `_bulk_get`,
  `multipart/related` GET and PUT, and `_revs_limit`, and records every
  request it receives for inspection.
- **put(replica, id, body, attachment?)** / **delete(replica, id)** — the
  module's local writes; ids, bodies, and attachments are opaque.
- **syncNow(replica)** — one discrete pull-then-push pass.
- **start / stop** — the continuous engine (longpoll pull loop, debounced
  push, streams).

## The opaque document model (RV1)

### a local write stores the opaque body verbatim

- **Arrange:** an empty replica.
- **Act:** `put(replica, "a1b2…" (any opaque string), body)` where the body is
  a JSON object with nested structures and fields that would be meaningful to
  a file layer (e.g. `{v: 1, n: "…", c: "…"}`).
- **Assert:** the replica holds exactly one document with that exact id and a
  byte-identical body, at revision `1-<hash>`; no field of the body was
  parsed, normalized, or rewritten.

### opaque round-trip: the body crosses replica → server → replica untouched

- **Arrange:** replicas A and B on one shared server database, with different
  replica ids.
- **Act:** put an opaque document on A; `syncNow(A)`; `syncNow(B)`.
- **Assert:** B emits one change event `{id, doc, deleted: false,
  origin: remote}` whose body is byte-identical to what A wrote; B holds the
  document at the **same** revision id A minted (grafted, not re-minted); the
  server stored the body verbatim.

### deletion is a tombstone revision, not removal (R15, C7)

- **Arrange:** replicas A and B synced on document `d` at `1-x`.
- **Act:** `delete(A, "d")`; `syncNow(A)`; `syncNow(B)`.
- **Assert:** on both replicas and the server, `d` exists as revision
  `2-<hash>` with `deleted: true` and no content; B emitted
  `{id: "d", deleted: true, origin: remote}`; the id was never purged from
  any store.

### the single attachment rests in the blob store, referenced by digest (R7, N5)

- **Arrange:** an empty replica.
- **Act:** `put(replica, id, body, <some bytes>)`.
- **Assert:** the attachment bytes live in the injected blob store keyed by
  their content digest; the document references that digest under the fixed
  name `data`; the body does not contain the bytes (no base64 inflation) and
  no additional documents were created (no chunking).

## Revision ids and the tree (RV4)

### a put mints revision N-<32 random lowercase hex> with parent linkage

- **Arrange:** an empty replica.
- **Act:** put a document, then put it again with a different body.
- **Assert:** the revisions are `1-<h1>` then `2-<h2>`; each hash is exactly
  32 lowercase hex characters; `2-<h2>`'s parent in the tree is `1-<h1>`; the
  two hashes differ.

### identical content on two replicas mints two distinct revisions — a same-content conflict with a picked winner

- **Arrange:** empty replicas A and B on one shared server.
- **Act:** put the identical `(id, body)` on A and on B independently;
  `syncNow(A)`; `syncNow(B)`; `syncNow(A)`.
- **Assert:** A and B each minted `1-<hash>` with **different** hashes (the
  hash is random, not content-derived — nothing about content can be inferred
  from a revision id); after sync every store holds **both** leaves; a
  conflict event is emitted; both replicas independently pick the same winner
  (the lexicographically greater hash). Identical content is a real conflict
  resolved deterministically, never deduped by revision hashing.

### write dedup: a put identical to the current winner records nothing

- **Arrange:** a replica whose document `d` has winner body `B` and
  attachment bytes `X`.
- **Act:** `put(replica, "d", B, X)` again — byte-identical body and
  attachment.
- **Assert:** no new revision exists (the winner and its rev are unchanged),
  no change event is emitted, and nothing was added to `pending_push`.

### pulled revisions graft into the tree with new_edits=false semantics

- **Arrange:** replica A holding `d` with tree `1-r → 2-a`; replica B synced
  only up to `1-r`; a shared server.
- **Act:** `syncNow(A)` (push), then `syncNow(B)` (pull).
- **Assert:** B's tree for `d` links `2-a` as a child of `1-r` — the exact
  revision id A minted, grafted via its transferred ancestor path
  (`_revisions`), not re-minted; B has a single leaf `2-a` (a fast-forward,
  no conflict).

### re-grafting a known revision is a no-op

- **Arrange:** replica B holding `d` at `2-a` from the previous case.
- **Act:** wipe only B's pull checkpoint and pull again from sequence zero.
- **Assert:** grafting `2-a` again changes nothing — no duplicate leaf, no
  new revision, no change event.

## The winner algorithm (R9)

### a live leaf beats a deleted leaf of higher generation

- **Arrange:** a document whose tree has a live leaf `4-aaaa…` and a deleted
  leaf `7-ffff…`.
- **Act:** compute the winner.
- **Assert:** `4-aaaa…` wins — deletedness dominates generation.

### among live leaves, the higher generation wins

- **Arrange:** a document with live leaves `5-aaaa…` and `4-ffff…`.
- **Act:** compute the winner.
- **Assert:** the generation-5 leaf wins even though its hash is
  lexicographically lower.

### an equal-generation tie breaks to the lexicographically greater hash

- **Arrange:** a document with live leaves `4-00aa…` and `4-00ab…` (equal
  generation).
- **Act:** compute the winner.
- **Assert:** `4-00ab…` wins — the tie-break is lexicographic comparison of
  the revision hashes.

### the winner is identical on every replica regardless of arrival order

- **Arrange:** three replicas that each received the same three leaves of one
  document, delivered in three different orders.
- **Act:** compute the winner on each replica.
- **Assert:** all three name the same revision — the winner is a pure
  function of the tree, needs no coordination, and matches the winner the
  server reports for the same tree.

## Pull (RV4)

### the changes request is longpoll with style=all_docs, heartbeat, and the stored checkpoint

- **Arrange:** a replica whose persisted pull checkpoint is the string
  `"42-xyz"`; a request-recording server.
- **Act:** run one pull pass.
- **Assert:** the `_changes` request carries `feed=longpoll`,
  `style=all_docs`, a heartbeat, and `since=42-xyz` exactly as stored.

### style=all_docs surfaces conflicting leaves — a two-leaf change row fetches both

- **Arrange:** the server holds document `d` with two live leaves `4-a` and
  `4-b`; a fresh replica.
- **Act:** run one pull.
- **Assert:** the change row for `d` lists both leaves; the replica fetches
  **both** revisions, holds both in its tree, and emits one change event for
  the winner plus one conflict event naming the loser. (Without
  `style=all_docs` the second leaf would be invisible and the conflict would
  silently never surface — this case is the guard.)

### attachment-less documents batch through _bulk_get

- **Arrange:** the server holds five new attachment-less documents the
  replica lacks; a request-recording server.
- **Act:** run one pull.
- **Assert:** the missing revisions are fetched via `POST /{db}/_bulk_get`
  with `revs=true` — batched, not five individual document GETs — and each is
  grafted with its ancestor path.

### an attachment document is pulled as multipart/related and streamed into the blob store

- **Arrange:** the server holds a document with a multi-megabyte attachment,
  served over the transport in small chunks; the replica's blob store is
  instrumented to record when and in what pieces it is written.
- **Act:** run one pull.
- **Assert:** the fetch is `GET /{db}/{id}?rev=…&revs=true&attachments=true`
  with `Accept: multipart/related`; the blob store receives the attachment as
  a stream of chunks under the content digest — the first chunks are written
  **before** the transport has finished serving the last (no whole-file
  buffering is observable anywhere); the grafted document references that
  digest.

### checkpoints are local-only and sequences are opaque strings

- **Arrange:** a server whose change sequences are non-numeric opaque strings
  (e.g. `"3-g1AAAA…"`); a request-recording server; a fresh replica.
- **Act:** run one pull processing several rows, then run a second pull.
- **Assert:** the second pull's `since=` equals the last processed row's
  sequence string **verbatim** (stored and replayed opaquely, never parsed or
  compared as a number); across both passes the server received **no**
  request touching any `_local/` path — no server-side checkpoint documents
  exist.

### an interrupted pull resumes from the locally persisted last_seq (R8)

- **Arrange:** the server has 500 changes the replica lacks; the transport is
  rigged to fail after the replica has processed and checkpointed 300 of
  them.
- **Act:** run a pull (it dies partway); run a pull again.
- **Assert:** the second pull asks for changes since the 300th row's
  sequence and transfers only the remaining ~200 documents; the replica ends
  with all 500; nothing restarts from sequence zero.

### longpoll delivers a remote change within seconds and re-issues (R6, N10)

- **Arrange:** replicas A and B on one server; B's engine is started and its
  longpoll is parked on the server (no pending changes).
- **Act:** A puts a document and pushes it.
- **Assert:** the server completes B's parked longpoll with the change row; B
  grafts the revision and emits `{origin: remote}` promptly — without any
  polling interval elapsing — persists the new `last_seq`, and immediately
  issues a fresh longpoll.

### a broken connection reconnects with exponential backoff and flips the online flag

- **Arrange:** B's engine running; the transport is rigged to fail every
  changes request for a while, then recover.
- **Act:** let the loop run through the outage.
- **Assert:** the status stream emits `online: false` after the first
  failure; the retry attempts are spaced with increasing delays (each gap at
  least the previous); once the transport recovers the loop resumes from the
  same checkpoint and `online: true` is emitted.

## Push (RV4)

### revs-diff transfers only what the server lacks

- **Arrange:** replica A and the server synced on a 100-document set; A edits
  exactly one document.
- **Act:** `syncNow(A)`.
- **Assert:** A posts `_revs_diff` with its pending revisions, and exactly
  one document body crosses in the transfer; the 99 unchanged documents are
  not re-sent.

### attachment-less push uses _bulk_docs with new_edits:false and the full ancestor path

- **Arrange:** replica A with document `d` at `2-a` (tree `1-r → 2-a`) that
  the server lacks entirely; a request-recording server.
- **Act:** push.
- **Assert:** the request is `POST /{db}/_bulk_docs` with
  `new_edits: false`, the document carrying `_revisions` that lists the path
  `[a, r]`; the server ends with the identical revision id `2-a` and the same
  tree — no server-minted revision.

### an attachment push is one multipart PUT with ?new_edits=false — never a separate attachment PUT

- **Arrange:** replica A with a document carrying an attachment in its blob
  store; a request-recording server.
- **Act:** push.
- **Assert:** the transfer is a single `PUT /{db}/{id}?new_edits=false` with
  a `multipart/related` body — the document JSON with
  `_attachments: {data: {follows: true, …}}` plus the attachment bytes
  streamed from the blob store; the server never receives a
  `PUT /{db}/{id}/data` (which would mint a server-side revision absent from
  the local tree).

### pending_push survives a restart

- **Arrange:** a replica over a durable store, its server unreachable; put
  two documents (both marked `pending_push`); tear the replica instance down
  and construct a fresh instance over the same store.
- **Act:** restore connectivity; `syncNow`.
- **Assert:** both revisions are pushed — the pending set was durable state,
  not in-process memory; after server confirmation `pending_push` is cleared
  and the status stream's `pendingPush` returns to 0.

### a burst of local writes debounces into one push batch (~2 s)

- **Arrange:** the engine started with the push debounce at its default
  (~2 s, configurable); a request-recording server.
- **Act:** perform five puts in rapid succession, all inside one debounce
  window; wait past the window.
- **Assert:** the server receives **one** push batch covering all five (one
  `_revs_diff`, one transfer), not five separate pushes; a later put after
  the window opens a new batch.

## Conflicts and resolution (R9)

### a conflict event carries each loser's full content and attachment

- **Arrange:** a document `d` conflicted between winner `4-w` (body only) and
  loser `4-l` whose revision has body `Bl` and an attachment `Xl`.
- **Act:** read the emitted conflict event.
- **Assert:** the event is `{id: "d", winner: 4-w, losers: [4-l]}`, and the
  loser's body `Bl` and attachment bytes `Xl` are retrievable through it —
  bodies and attachment references are kept for every live leaf precisely so
  a shell can rescue losers; nothing was purged.

### resolve writes a deleted child on each named loser and pushes it

- **Arrange:** the conflict above, with connectivity up.
- **Act:** `resolve("d", ["4-l"])`; `syncNow`.
- **Assert:** the losing branch now ends in a deleted `5-<hash>` child of
  `4-l`; `d` has exactly one live leaf (the winner); the tombstone reached
  the server, so the server agrees on the single live leaf; the winning
  branch's content was not touched (no merge).

### resolving twice is harmless

- **Arrange:** the document just resolved.
- **Act:** `resolve("d", ["4-l"])` again.
- **Assert:** a no-op — no new revision, no event, no error (the named leaf
  is already deleted).

### concurrent resolution from two replicas converges

- **Arrange:** replicas A and B both holding the same conflict on `d`
  (winner `4-w`, loser `4-l`), both online.
- **Act:** A and B each call `resolve("d", ["4-l"])` before either syncs;
  then sync both, twice each.
- **Assert:** both replicas converge with `4-w` as the single live leaf; the
  two independently minted tombstones on the losing branch coexist without
  error, without resurrecting the loser, and without any new conflict event
  (deleted leaves are not conflicts).

## Revision limit and stemming (C7, RV4)

### the replica mirrors the server's _revs_limit and never lowers it

- **Arrange:** a server with `_revs_limit` set to 50; a request-recording
  server; a fresh replica.
- **Act:** start the engine.
- **Assert:** the replica read the server's `_revs_limit` once at start and
  adopted 50 as its own cap; the server received no write to `_revs_limit`
  (the client never changes the server's setting).

### stemming caps stored revision paths at the limit and keeps bodies only for live leaves

- **Arrange:** a replica whose mirrored revision limit is 50.
- **Act:** edit one document 60 times; inspect the stored tree.
- **Assert:** the stored revision path holds the 50 most recent ids (the
  oldest 10 stemmed away); bodies and attachment references exist **only**
  for the live leaf (for every live leaf, if conflicted) — no ancestor
  bodies are retained.

## Offline-first and the engine (R3, R4, RV4)

### a week-long divergence converges by transferring only missing revisions, both ways (S1)

- **Arrange:** replicas A and B synced with the server on a 50-document set;
  connectivity cut. Offline, A edits 10 documents (some repeatedly) and
  creates 2 new ones; B edits 5 **different** documents and deletes 1.
- **Act:** reconnect; `syncNow(A)`; `syncNow(B)`; `syncNow(A)`.
- **Assert:** A and B converge to the identical document set — every edit,
  creation, and deletion present on both; counting bodies on the wire, only
  revisions absent from the receiving side were transferred (the untouched
  documents never crossed in either direction); no conflict is reported
  (the edits were disjoint).

### the status stream reports {online, pendingPush, lastSeq, error}

- **Arrange:** a replica whose server starts unreachable; a subscription to
  the status stream.
- **Act:** put two documents; restore connectivity and start the engine; let
  it sync; then rig the server to answer `401 Unauthorized`.
- **Assert:** every status event carries all four fields, and the observed
  sequence includes: `online: false` with `pendingPush: 2` while cut off;
  after recovery `online: true`, `pendingPush` falling to 0, and `lastSeq`
  advancing to the server's current sequence; once the 401 begins, `error`
  carries the auth failure and `online` flips back to false.

## Every request is bounded in time (R4, RV4)

### a connection that never answers fails as unreachable, it does not hang

- **Arrange:** a transport whose executor accepts the request and then never
  responds — the shape of a TCP connection established before a sleep, a
  Wi-Fi switch or a VPN drop, dead on the peer's side and silent on this one.
- **Act:** run one pull pass, with a deadline configured.
- **Assert:** the pass **completes** within roughly that deadline and fails
  with `SyncException(unreachable)` — the same outcome as any other broken
  connection. It does not wait indefinitely, and the checkpoint is unchanged
  so the next attempt resumes from where it left off.

### a parked longpoll is bounded by silence, not by elapsed time

- **Arrange:** a transport whose longpoll parks well past any ordinary
  deadline. Two runs: one where the server keeps sending **heartbeats** and
  eventually answers, another where nothing arrives at all after the
  connection is made.
- **Act:** run the pull in each.
- **Assert:** the heartbeating longpoll returns its rows untouched however
  long it parked — a quiet vault is not a broken one, and elapsed time alone
  never cuts it short. The silent one fails as `unreachable` once the gap
  exceeds its heartbeat interval by a clear margin.

### a deadline failure is an ordinary unreachable, not a new error kind

- **Arrange:** a transport pointed at an address where nothing listens, with a
  short deadline.
- **Act:** run a request.
- **Assert:** it fails as `SyncException(unreachable)` — the same kind every
  other broken connection produces, so the engine retries it with no special
  case and a shell that serializes its passes releases the serialization
  normally. This is what keeps a stuck pass from wedging the ones behind it:
  every pass terminates, so nothing queues forever behind one that never
  returns.

## Review-hardening cases (RV4)

### an explicitly parented put creates a real conflict branch

- **Arrange:** replicas A and B synced on a document at revision `1-x`. A
  pulls B's edit `2-b`, so A's winner is now `2-b`; A's shell holds a local
  edit that was made **on top of `1-x`**.
- **Act:** put the local edit with the explicit parent revision `1-x`; sync
  both replicas.
- **Assert:** the put mints a child of `1-x` (a live branch), not of `2-b`;
  the document reports a conflict with two live leaves on both replicas; the
  deterministic winner is identical on both; neither version's content was
  silently superseded. A winner-parented put with identical content still
  dedups; an explicitly parented put never dedups; naming an unknown parent
  revision is rejected.

### stop() aborts a parked longpoll and a stale pass writes nothing

- **Arrange:** a running engine whose longpoll (with heartbeat) is parked on
  an idle server — per real CouchDB semantics the heartbeat means the request
  never times out on its own.
- **Act:** call `stop()` while parked; then push a change from another replica;
  restart the engine.
- **Assert:** `stop()` returns promptly (the parked request is aborted); no
  graft and no checkpoint write happens after `stop()` even if the abandoned
  request later completes (the pass detects its stale generation and discards
  results); the restarted engine pulls the change normally.

### reconnection catches up before parking

- **Arrange:** an engine cut off from the server; local writes queue as
  pending; the server also accumulates remote changes.
- **Act:** restore connectivity; let the engine's loop run.
- **Assert:** the backlog transfers in both directions via catch-up pulls and
  a push **before** the loop parks a longpoll — pending writes do not wait for
  the next remote change to unpark the loop.

### the push backlog is chunked and a 413 splits, never wedges

- **Arrange:** a replica with a large pending backlog (many attachment-less
  documents); a server (or proxy) with a maximum request body size smaller
  than the whole backlog.
- **Act:** push.
- **Assert:** `_bulk_docs` uploads go out in bounded chunks (by count and
  approximate bytes), the pending set and push checkpoint advance per
  successful chunk, an HTTP 413 causes the chunk to split and retry smaller,
  and the push completes; a single document that alone exceeds the cap
  surfaces a clear protocol error naming it while the rest of the backlog
  still ships. A mid-push failure keeps already-confirmed chunks confirmed.

### an attachment download failing mid-stream is a typed error, not a crash

- **Arrange:** a running engine pulling a document whose attachment stream is
  cut by the server partway through the body.
- **Act:** let the pull consume the attachment.
- **Assert:** the failure surfaces as a typed sync error (unreachable /
  protocol), the engine's status shows the error and the loop backs off and
  recovers — no unhandled error escapes the engine's background futures; a
  gzip-`encoding` attachment stub is likewise rejected loudly as a protocol
  error rather than stored corrupted.

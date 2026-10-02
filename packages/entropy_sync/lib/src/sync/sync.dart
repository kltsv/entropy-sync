/// Public API of the `vault_sync` module — the document-opaque CouchDB
/// replication client (RV1, RV4): the opaque document model, an
/// offline-first local replica with a full revision tree over injected
/// storage, the standard replication protocol in both directions (longpoll
/// `_changes` with `style=all_docs`, `_revs_diff`, `_bulk_get` /
/// `_bulk_docs` `new_edits:false`, `multipart/related` streamed attachments,
/// local-only checkpoints), deterministic conflict detection with
/// host-driven idempotent resolution (R9), and the continuous [SyncEngine]
/// with change / conflict / status streams.
///
/// The module replicates **abstract documents** — it never sees plaintext,
/// paths, or keys; in production everything through it is ciphertext minted
/// by `vault_crypto`, and it neither knows nor cares (RV1).
library;

export 'engine/sync_engine.dart';
export 'model/events.dart';
export 'model/revisions.dart';
export 'model/sync_doc.dart';
export 'replication/replicator.dart';
export 'store/blob_store.dart';
export 'store/local_store.dart';
export 'store/storage_backend.dart';
export 'transport/couch_transport.dart';
export 'transport/http_exec.dart';
export 'transport/sync_exception.dart';

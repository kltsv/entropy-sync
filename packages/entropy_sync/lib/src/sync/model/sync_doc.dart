/// The opaque document model of `vault_sync` (RV1).
///
/// A document is `{id, body, attachment?, deleted}` and every part of it is
/// opaque to this module: the id is never parsed (in production it is the
/// HMAC id minted by `vault_crypto`), the body is stored and transferred
/// verbatim, and the single attachment is a byte stream resting in the blob
/// store, referenced by content digest. Deletion is a tombstone revision —
/// the id survives and the deletion replicates (R15).
library;

/// A reference to attachment bytes resting in the blob store, keyed by
/// content digest (`vault_sync` RV4). Documents carry the reference; the
/// bytes themselves stream through and are never held whole in memory.
class AttachmentRef {
  const AttachmentRef({required this.digest, required this.length});

  /// The content digest the blob store keys the bytes by.
  final String digest;

  /// Total attachment length in bytes.
  final int length;

  @override
  String toString() => 'AttachmentRef($digest, $length bytes)';
}

/// One opaque document as the replica sees it (`vault_sync` RV1): an opaque
/// [id], an opaque JSON [body], at most one [attachment] under the fixed name
/// `data`, and the [deleted] tombstone flag. [rev] is the revision this
/// snapshot was taken at (the winner for `LocalStore.get`, the leaf for
/// conflict losers).
class SyncDoc {
  const SyncDoc({
    required this.id,
    this.body,
    this.attachment,
    this.deleted = false,
    this.rev,
  });

  /// Opaque document id — never parsed by this module.
  final String id;

  /// Opaque JSON body, `null` for tombstones.
  final Map<String, Object?>? body;

  /// The single attachment's blob-store reference, if any.
  final AttachmentRef? attachment;

  /// Whether this revision is a tombstone (R15).
  final bool deleted;

  /// The revision id this document snapshot carries (`N-<32 hex>`, RV4).
  final String? rev;

  @override
  String toString() => 'SyncDoc($id @ $rev${deleted ? ', deleted' : ''})';
}

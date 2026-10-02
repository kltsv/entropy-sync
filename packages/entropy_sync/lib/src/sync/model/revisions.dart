/// Revision ids and revisioned documents (`vault_sync` RV4).
///
/// Every locally minted revision is `N-<32 lowercase random hex>`: `N` is the
/// parent's generation plus one and the hash is random, carrying **no**
/// content-derived information — nothing about a revision's plaintext can be
/// inferred from its id (RV2's leakage budget).
library;

import 'dart:math';

import 'sync_doc.dart';

final Random _random = Random.secure();

/// Mint a fresh revision id `generation-<32 lowercase random hex>` using a
/// cryptographically secure RNG (`vault_sync` RV4).
String mintRev(int generation) {
  final buf = StringBuffer('$generation-');
  for (var i = 0; i < 32; i++) {
    buf.write('0123456789abcdef'[_random.nextInt(16)]);
  }
  return buf.toString();
}

/// The generation `N` of a revision id `N-<hash>`.
int revGeneration(String rev) => int.parse(rev.substring(0, rev.indexOf('-')));

/// The hash part of a revision id `N-<hash>`.
String revHash(String rev) => rev.substring(rev.indexOf('-') + 1);

/// One revision of a document together with the ancestor path it grafts by —
/// the transfer unit of the replication protocol (`vault_sync` RV4).
///
/// [revisionIds] is the CouchDB `_revisions.ids` list: the hash of [rev]
/// first, then each ancestor's hash walking toward the root, capped at the
/// revision limit. [revisionsStart] is [rev]'s generation.
class RevisionedDoc {
  const RevisionedDoc({
    required this.id,
    required this.rev,
    required this.revisionsStart,
    required this.revisionIds,
    this.body,
    this.attachment,
    this.deleted = false,
  });

  /// Opaque document id.
  final String id;

  /// The revision this document carries (`N-<hash>`).
  final String rev;

  /// Generation of [rev] — CouchDB `_revisions.start`.
  final int revisionsStart;

  /// Hashes of [rev] and its ancestors, newest first — `_revisions.ids`.
  final List<String> revisionIds;

  /// Opaque body, `null` for tombstones.
  final Map<String, Object?>? body;

  /// Blob-store reference of the single attachment, if any.
  final AttachmentRef? attachment;

  /// Tombstone flag.
  final bool deleted;

  /// This document with its attachment reference replaced — used when the
  /// attachment bytes have been streamed into the local blob store and the
  /// locally computed digest takes over from the wire stub's.
  RevisionedDoc withAttachment(AttachmentRef? attachment) => RevisionedDoc(
        id: id,
        rev: rev,
        revisionsStart: revisionsStart,
        revisionIds: revisionIds,
        body: body,
        attachment: attachment,
        deleted: deleted,
      );

  @override
  String toString() => 'RevisionedDoc($id @ $rev${deleted ? ', deleted' : ''})';
}

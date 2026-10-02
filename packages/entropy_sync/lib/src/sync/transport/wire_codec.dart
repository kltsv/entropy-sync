/// The CouchDB wire JSON shape of one opaque document (`vault_sync` RV1,
/// RV4), shared by the transport and the test emulator so both ends agree.
///
/// The opaque body map is spread **at the top level** of the couch document,
/// next to the protocol fields:
///
/// ```json
/// {
///   "...opaque body keys...": "...verbatim...",
///   "_id": "<opaque id>",
///   "_rev": "N-<32 hex>",
///   "_revisions": {"start": N, "ids": ["<hash>", "<parent hash>", …]},
///   "_deleted": true,                        // tombstones only
///   "_attachments": {"data": {…}}            // at most one, fixed name
/// }
/// ```
///
/// Opaque body keys never collide with the protocol fields: CouchDB reserves
/// the `_` prefix for itself (a client cannot store top-level underscore
/// fields), and in production the body is the `{v, n, c}` frame minted by
/// `vault_crypto`. Parsing is the mirror: every key not starting with `_` is
/// the body, verbatim.
///
/// The single attachment lives under the fixed name `data` (R7, N5) in one of
/// two wire forms: a stub `{"stub": true, "length": …, "digest": …}` inside
/// `_bulk_get` responses, or `{"follows": true, "content_type":
/// "application/octet-stream", "length": …}` when the bytes ride alongside in
/// a `multipart/related` part.
library;

import '../model/revisions.dart';
import '../model/sync_doc.dart';
import 'sync_exception.dart';

/// How the attachment reference is framed in the wire JSON.
enum AttachmentEncoding {
  /// `{"stub": true, …}` — bytes not included (bulk_get, changes-side views).
  stub,

  /// `{"follows": true, …}` — bytes ride in the next multipart part.
  follows,
}

/// Encode a revisioned document into the wire JSON shape above.
Map<String, Object?> wireDocJson(
  RevisionedDoc doc, {
  AttachmentEncoding attachmentEncoding = AttachmentEncoding.stub,
}) {
  final att = doc.attachment;
  return <String, Object?>{
    ...?doc.body,
    '_id': doc.id,
    '_rev': doc.rev,
    if (doc.deleted) '_deleted': true,
    '_revisions': {'start': doc.revisionsStart, 'ids': doc.revisionIds},
    if (att != null)
      '_attachments': {
        'data': switch (attachmentEncoding) {
          AttachmentEncoding.stub => {
              'stub': true,
              'content_type': 'application/octet-stream',
              'length': att.length,
              'digest': att.digest,
            },
          AttachmentEncoding.follows => {
              'follows': true,
              'content_type': 'application/octet-stream',
              'length': att.length,
              'digest': att.digest,
            },
        },
      },
  };
}

/// Decode wire JSON (which must carry `_revisions`, i.e. come from a
/// `revs=true` fetch) back into a revisioned document. The attachment digest
/// in a stub is advisory — pull replication re-derives it by streaming the
/// bytes into the local blob store (RV4).
RevisionedDoc revisionedDocFromWire(Map<String, Object?> json) {
  final rev = json['_rev'] as String;
  final revisions = (json['_revisions'] as Map?)?.cast<String, Object?>();
  final ids = revisions == null
      ? <String>[revHash(rev)]
      : (revisions['ids'] as List).cast<String>();
  final start = revisions == null
      ? revGeneration(rev)
      : (revisions['start'] as num).toInt();
  final deleted = json['_deleted'] == true;

  AttachmentRef? attachment;
  final atts = json['_attachments'];
  if (atts is Map && atts['data'] is Map) {
    final meta = (atts['data'] as Map).cast<String, Object?>();
    // Real CouchDB serves attachments in their *stored* encoding and
    // advertises it via `encoding`/`encoded_length` (a server whose
    // compressible_types covers application/octet-stream gzips them). This
    // client never uploads compressed attachments and does not gunzip —
    // storing the encoded bytes verbatim would silently corrupt the content,
    // so fail loudly instead.
    final encoding = meta['encoding'];
    if (encoding != null && encoding != 'identity') {
      throw SyncException(
          SyncErrorKind.protocol,
          "attachment of ${json['_id']} is transfer-encoded "
          "('$encoding') — encoded attachments are not supported; disable "
          'attachment compression for application/octet-stream on the '
          'server ([attachments] compressible_types)');
    }
    attachment = AttachmentRef(
      digest: (meta['digest'] as String?) ?? '',
      length: (meta['length'] as num?)?.toInt() ?? 0,
    );
  }

  final body = <String, Object?>{
    for (final e in json.entries)
      if (!e.key.startsWith('_')) e.key: e.value,
  };

  return RevisionedDoc(
    id: json['_id'] as String,
    rev: rev,
    revisionsStart: start,
    revisionIds: ids,
    body: deleted ? null : body,
    attachment: deleted ? null : attachment,
    deleted: deleted,
  );
}

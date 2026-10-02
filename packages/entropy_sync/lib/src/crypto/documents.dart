import 'dart:typed_data';

/// A **logical document** — what the shells and `vault_hist` see: a real
/// vault file's path, bytes, and mtime (`vault_crypto` §Inputs).
///
/// [path] is vault-relative with `/` separators, Unicode **NFC**,
/// case-sensitive. Dart's SDK has no NFC normalizer, so canonicalization is
/// the caller's contract: shells must supply already-NFC paths (the macOS
/// shells normalize at the filesystem boundary). [mtime] is UTC epoch
/// milliseconds. [bytes] are the file content as-is — markdown is UTF-8,
/// binaries are bytes; this layer never distinguishes (RV2).
class LogicalDoc {
  final String path;
  final Uint8List? bytes;
  final int mtime;
  final bool deleted;

  const LogicalDoc({
    required this.path,
    this.bytes,
    this.mtime = 0,
    this.deleted = false,
  });
}

/// A **wire document** — what `vault_sync` replicates: an opaque id, an
/// encrypted body, an optional encrypted attachment (`vault_crypto` RV2).
///
/// [body] is `{v: 1, n: base64(nonce), c: base64(ciphertext‖tag)}`; it is
/// `null` for tombstones — deletion carries nothing to decrypt.
class WireDoc {
  final String id;
  final Map<String, Object?>? body;
  final bool deleted;

  const WireDoc({required this.id, this.body, this.deleted = false});
}

/// The plaintext **frame header** carried inside the encrypted body:
/// `{path, mtime, size, inline}` (`vault_crypto` RV2). Path, mtime, and size
/// cross the wire only here — inside the ciphertext, never as plaintext
/// fields.
class DocHeader {
  final String path;
  final int mtime;
  final int size;
  final bool inline;

  const DocHeader({
    required this.path,
    required this.mtime,
    required this.size,
    required this.inline,
  });

  Map<String, Object?> toJson() =>
      {'path': path, 'mtime': mtime, 'size': size, 'inline': inline};
}

/// The result of encrypting a logical document: the wire document plus, for
/// content above the inline threshold, the STREAM ciphertext as a lazy
/// single-subscription stream (`vault_crypto` RV2, RV3).
///
/// [attachment] is non-null **iff** the content rides as an attachment
/// (size strictly above the threshold, and never for tombstones). On the
/// wire it travels under the fixed name `data` with content type
/// `application/octet-stream` — see `VaultCrypto.attachmentName` /
/// `VaultCrypto.attachmentContentType`.
class EncryptedDoc {
  final WireDoc wire;
  final Stream<List<int>>? attachment;

  const EncryptedDoc({required this.wire, this.attachment});
}

/// The result of decrypting a wire document's **body** only: the frame
/// header, plus the content bytes when they were inline. When
/// `header.inline` is false, [inlineContent] is `null` and the caller
/// fetches the attachment separately (`vault_crypto` RV2).
class DecryptedDoc {
  final DocHeader header;
  final Uint8List? inlineContent;

  const DecryptedDoc({required this.header, this.inlineContent});
}

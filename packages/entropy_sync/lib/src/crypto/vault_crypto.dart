import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'documents.dart';
import 'exceptions.dart';
import 'frame.dart';
import 'keys.dart';
import 'random.dart';
import 'stream_cipher.dart';

final _aesGcm = AesGcm.with256bits();

/// The E2EE module (`vault_crypto`): a **pure transformation** between
/// logical vault documents and wire documents. It knows nothing about
/// replication and nothing about history — the shells compose it between
/// the vault and the sync core (RV1).
///
/// The server sees only: document counts, ciphertext sizes, timing, and
/// deletion facts. It cannot see content, paths, or file types (RV2).
class VaultCrypto {
  /// The fixed wire name of the single attachment (RV2).
  static const attachmentName = 'data';

  /// The fixed wire content type of the attachment — the real file type is
  /// never sent (RV2).
  static const attachmentContentType = 'application/octet-stream';

  /// The default inline-size threshold: 1 MiB (RV2).
  static const defaultInlineThreshold = 1024 * 1024;

  final KeyMaterial keys;

  /// Content of `size ≤ inlineThreshold` travels inside the body frame;
  /// larger content rides as the STREAM attachment. The split is strictly
  /// **by byte size**, never by file type — after encryption everything is
  /// bytes, and distinguishing text from binary here would only leak (RV2).
  final int inlineThreshold;

  VaultCrypto(this.keys, {this.inlineThreshold = defaultInlineThreshold});

  /// Derives [KeyMaterial] from the passphrase (`vault_crypto` RV3).
  ///
  /// - [meta] `== null` — **first-device init**: generates a random 16-byte
  ///   per-vault salt, derives `master = Argon2id(passphrase, salt)` with
  ///   [params] (production defaults `m = 64 MiB, t = 3, p = 1`), the HKDF
  ///   subkeys, and the `meta` document
  ///   `{v, kdf: {alg, salt, m, t, p}, check: {n, c}}` — returned on the
  ///   key material for the shell to write to the database.
  /// - [meta] `!= null` — **later device**: derives with the salt and
  ///   parameters stored in `meta` and verifies the passphrase against the
  ///   check value before any sync runs. A typo'd passphrase raises a typed
  ///   [VaultCryptoErrorKind.wrongPassphrase] error without touching a
  ///   single vault document.
  /// - [fresh] declares first-init **intent** (the daemon's `init` verb):
  ///   when the database already has a `meta`, a fresh init is refused with
  ///   [VaultCryptoErrorKind.metaExists] — `meta` is never regenerated,
  ///   never overwritten (RV3). Passphrase change is a new database, not a
  ///   rewrite.
  static Future<KeyMaterial> init(
    String passphrase, {
    Map<String, Object?>? meta,
    Argon2Params? params,
    bool fresh = false,
  }) async {
    // No "unencrypted" mode exists: an empty passphrase would derive the key
    // from the empty string plus the salt and parameters published in the
    // plaintext `meta` document — ciphertext anyone can undo (RV3).
    if (passphrase.isEmpty) {
      throw const VaultCryptoException.wrongPassphrase(
          'the passphrase must not be empty — there is no unencrypted mode, '
          'and an empty one derives a key anyone can derive');
    }
    if (meta != null) {
      if (fresh) {
        throw const VaultCryptoException.metaExists(
            'the database already has a meta document — init never '
            'overwrites it; a passphrase change is a new database');
      }
      return verifyKeyMaterial(passphrase, meta);
    }
    return createKeyMaterial(passphrase,
        params: params ?? Argon2Params.production);
  }

  /// The wire document id for [path]: lowercase hex of
  /// `HMAC-SHA256(k_id, UTF-8 path bytes)` — 64 hex characters,
  /// deterministic and one-way (RV2). Every client independently maps the
  /// same path to the same id with no coordination; the id reveals nothing,
  /// and the path travels only inside the encrypted frame.
  ///
  /// [path] must be canonical: vault-relative, `/` separators, Unicode
  /// **NFC**, case-sensitive. The Dart SDK has no NFC normalizer and this
  /// module adds no dependency for one — callers supply already-NFC paths
  /// (macOS shells normalize at the filesystem boundary).
  String idFor(String path) => crypto.Hmac(crypto.sha256, keys.kId)
      .convert(utf8.encode(path))
      .toString();

  /// Logical → wire (RV2).
  ///
  /// A deleted logical document becomes a tombstone: the same deterministic
  /// HMAC id a live document at that path would have, `deleted: true`, and
  /// no body and no attachment — there is nothing to decrypt. For live
  /// documents the frame (header + inline content) is sealed with
  /// AES-256-GCM under `k_body`, a fresh random 96-bit nonce, and
  /// **AAD = the wire id**, binding the ciphertext to its document so it
  /// cannot be transplanted under another id.
  Future<EncryptedDoc> encrypt(LogicalDoc doc) async {
    final id = idFor(doc.path);
    if (doc.deleted) {
      return EncryptedDoc(wire: WireDoc(id: id, deleted: true));
    }
    final bytes = doc.bytes;
    if (bytes == null) {
      throw ArgumentError('a live logical document must carry bytes');
    }
    final inline = bytes.length <= inlineThreshold;
    final header = DocHeader(
      path: doc.path,
      mtime: doc.mtime,
      size: bytes.length,
      inline: inline,
    );
    return EncryptedDoc(
      wire: WireDoc(
          id: id, body: await _sealBody(id, header, inline ? bytes : null)),
      attachment: inline
          ? null
          : encryptStream(Stream<List<int>>.value(bytes), docId: id),
    );
  }

  /// Logical → wire without ever holding the content whole (RV3).
  ///
  /// The streamed counterpart of [encrypt] for shells that read files from
  /// disk: [size] is the content's byte length (from `stat`), [openContent]
  /// is invoked at most once to obtain the plaintext stream. For
  /// `size ≤ inlineThreshold` the content is buffered (bounded by the
  /// threshold) and sealed inline exactly like [encrypt]; above the
  /// threshold the wire document is built from the header alone and
  /// [openContent] is piped through the id-bound STREAM cipher lazily —
  /// constant memory, the file is never resident. A stream that delivers a
  /// different byte count than [size] fails with a typed error instead of
  /// producing a header that lies.
  Future<EncryptedDoc> encryptStreamed({
    required String path,
    required int mtime,
    required int size,
    required Stream<List<int>> Function() openContent,
  }) async {
    if (size <= inlineThreshold) {
      final buffer = BytesBuilder(copy: true);
      await for (final chunk in openContent()) {
        buffer.add(chunk);
      }
      final bytes = buffer.takeBytes();
      if (bytes.length != size) {
        throw VaultCryptoException.malformed(
            'content of $path delivered ${bytes.length} bytes, size says '
            '$size — the file changed while being read');
      }
      return encrypt(LogicalDoc(path: path, bytes: bytes, mtime: mtime));
    }
    final id = idFor(path);
    final header =
        DocHeader(path: path, mtime: mtime, size: size, inline: false);
    return EncryptedDoc(
      wire: WireDoc(id: id, body: await _sealBody(id, header, null)),
      attachment:
          encryptStream(_exactlySized(openContent(), size, path), docId: id),
    );
  }

  /// Seals the frame (header + optional inline content) with AES-256-GCM
  /// under `k_body`, a fresh random 96-bit nonce, and **AAD = the wire id**
  /// into the `{v, n, c}` body map (RV2).
  Future<Map<String, Object?>> _sealBody(
    String id,
    DocHeader header,
    Uint8List? inlineContent,
  ) async {
    final nonce = randomBytes(12);
    final box = await _aesGcm.encrypt(
      encodeFrame(header, inlineContent),
      secretKey: SecretKey(keys.kBody),
      nonce: nonce,
      aad: utf8.encode(id),
    );
    final sealed = (BytesBuilder(copy: false)
          ..add(box.cipherText)
          ..add(box.mac.bytes))
        .takeBytes();
    return <String, Object?>{
      'v': 1,
      'n': base64Encode(nonce),
      'c': base64Encode(sealed),
    };
  }

  /// Re-yields [source], erroring at the end if it did not deliver exactly
  /// [size] bytes — the sealed header already promised that size.
  static Stream<List<int>> _exactlySized(
    Stream<List<int>> source,
    int size,
    String path,
  ) async* {
    var total = 0;
    await for (final chunk in source) {
      total += chunk.length;
      yield chunk;
    }
    if (total != size) {
      throw VaultCryptoException.malformed(
          'content of $path delivered $total bytes, size says $size — the '
          'file changed while being read');
    }
  }

  /// Decrypts only the **body** of a wire document: the frame header plus
  /// the content when it was inline (RV2). When `header.inline` is false
  /// the caller fetches the attachment and runs it through [decryptStream]
  /// (or uses [decrypt]).
  ///
  /// Tampered or transplanted ciphertext fails GCM authentication (the AAD
  /// is [WireDoc.id]) with a typed tamper error — nothing partial is
  /// emitted. Tombstones carry no body and cannot be decrypted; the shell
  /// resolves deleted ids against its own path index.
  Future<DecryptedDoc> decryptBody(WireDoc wire) async {
    final body = wire.body;
    if (body == null) {
      throw const VaultCryptoException.malformed(
          'the wire document has no body — tombstones carry nothing to '
          'decrypt; the shell maps deleted ids to paths itself');
    }
    if (body['v'] != 1) {
      throw VaultCryptoException.malformed(
          'unsupported body version: ${body['v']}');
    }
    final nonce = _base64Field(body, 'n');
    final sealed = _base64Field(body, 'c');
    if (nonce.length != 12) {
      throw const VaultCryptoException.malformed('body nonce is not 96 bits');
    }
    if (sealed.length < 16) {
      throw const VaultCryptoException.malformed(
          'body ciphertext is shorter than a GCM tag');
    }
    final List<int> frame;
    try {
      frame = await _aesGcm.decrypt(
        SecretBox(
          Uint8List.sublistView(sealed, 0, sealed.length - 16),
          nonce: nonce,
          mac: Mac(Uint8List.sublistView(sealed, sealed.length - 16)),
        ),
        secretKey: SecretKey(keys.kBody),
        aad: utf8.encode(wire.id),
      );
    } on SecretBoxAuthenticationError {
      throw VaultCryptoException.tampered(
          'body of ${wire.id} failed authentication — tampered or '
          'transplanted ciphertext');
    }
    final decoded =
        decodeFrame(frame is Uint8List ? frame : Uint8List.fromList(frame));
    return DecryptedDoc(header: decoded.header, inlineContent: decoded.content);
  }

  /// Wire → logical, in full (RV2): decrypts the body and, for non-inline
  /// content, buffers the attachment through [decryptStream]. Round trips
  /// are byte-faithful — the exact original path, bytes, and mtime come
  /// back.
  ///
  /// [openAttachment] must be supplied for documents whose frame says
  /// `inline: false`; it is invoked once to obtain the attachment
  /// ciphertext stream. Note this convenience buffers the whole plaintext —
  /// stream consumers use [decryptStream] directly.
  Future<LogicalDoc> decrypt(
    WireDoc wire, {
    Stream<List<int>> Function()? openAttachment,
  }) async {
    final decrypted = await decryptBody(wire);
    final header = decrypted.header;
    if (header.inline) {
      return LogicalDoc(
        path: header.path,
        bytes: decrypted.inlineContent,
        mtime: header.mtime,
      );
    }
    if (openAttachment == null) {
      throw VaultCryptoException.malformed(
          'document ${wire.id} carries its content as an attachment, but no '
          'openAttachment was supplied');
    }
    final buffer = BytesBuilder(copy: true);
    await for (final chunk in decryptStream(openAttachment(), docId: wire.id)) {
      buffer.add(chunk);
    }
    final bytes = buffer.takeBytes();
    if (bytes.length != header.size) {
      throw VaultCryptoException.tampered(
          'attachment of ${wire.id} decrypted to ${bytes.length} bytes, the '
          'authenticated frame says ${header.size}');
    }
    return LogicalDoc(path: header.path, bytes: bytes, mtime: header.mtime);
  }

  /// STREAM-encrypts attachment-sized content under `k_att` in constant
  /// memory (RV3), bound to the document [docId] — the per-attachment key
  /// derivation includes the wire id, so the ciphertext decrypts only under
  /// the same document. See `stream_cipher.dart` for the construction.
  Stream<List<int>> encryptStream(
    Stream<List<int>> plain, {
    required String docId,
  }) =>
      encryptAttachment(keys.kAtt, docId, plain);

  /// STREAM-decrypts the attachment ciphertext of document [docId] in
  /// constant memory (RV3). Truncation, reordering, duplication, or
  /// tampering of any segment — and ciphertext sealed for a **different**
  /// document id (a swapped attachment) — fails loudly with a typed error;
  /// a short final read without the final flag is an error, not a short
  /// file.
  Stream<List<int>> decryptStream(
    Stream<List<int>> cipher, {
    required String docId,
  }) =>
      decryptAttachment(keys.kAtt, docId, cipher);

  Uint8List _base64Field(Map<String, Object?> body, String field) {
    final value = body[field];
    if (value is! String) {
      throw VaultCryptoException.malformed('body.$field is not a string');
    }
    try {
      return base64Decode(value);
    } on FormatException {
      throw VaultCryptoException.malformed('body.$field is not valid base64');
    }
  }
}

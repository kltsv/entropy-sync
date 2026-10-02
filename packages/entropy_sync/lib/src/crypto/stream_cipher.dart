/// STREAM segmented-AEAD attachment encryption (`vault_crypto` RV3) — the
/// published construction used by age and Tink's `AesGcmHkdfStreaming`,
/// adopted as-is, not invented here.
///
/// Ciphertext layout:
///
/// `16-byte random key salt ‖ 4-byte random nonce prefix ‖ segments`
///
/// The per-attachment key is `HKDF-SHA256(ikm = k_att, salt = key salt,
/// info = "entropy-sync/att" ‖ 0x00 ‖ UTF-8 wire id, 32 B)` — the document
/// id in the info **binds the attachment to its document**: ciphertext
/// served under any other id derives a different key and fails segment
/// authentication, so a hostile server cannot swap the attachments of two
/// documents (equal sizes included). Each segment is AES-256-GCM over up to
/// 64 KiB of plaintext with nonce `prefix (4 B) ‖ counter (u56 BE, 7 B) ‖
/// final flag (1 B)`; every non-final segment covers exactly 64 KiB, the
/// final segment (and only it) sets the flag and covers 0..64 KiB. Both
/// directions run in constant memory: incoming chunks are segmented in
/// place (sub-views, never a second whole-input buffer) with at most one
/// segment of carried lookahead.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'exceptions.dart';
import 'random.dart';

/// HKDF `info` prefix for the per-attachment key; the full info is
/// `attachmentKeyInfo ‖ 0x00 ‖ UTF-8 wire id` (RV3).
const attachmentKeyInfo = 'entropy-sync/att';

/// Plaintext bytes per STREAM segment: 64 KiB (RV3).
const attachmentSegmentSize = 64 * 1024;

/// Ciphertext bytes per full segment unit: segment + 16-byte GCM tag.
const attachmentUnitSize = attachmentSegmentSize + 16;

/// Random key salt length at the head of the ciphertext.
const attachmentKeySaltSize = 16;

/// Random nonce prefix length following the key salt.
const attachmentNoncePrefixSize = 4;

/// Key salt + nonce prefix: everything before the first segment.
const attachmentHeaderSize = attachmentKeySaltSize + attachmentNoncePrefixSize;

final _aesGcm = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

Future<SecretKey> _attachmentKey(
  Uint8List kAtt,
  String docId,
  List<int> keySalt,
) =>
    _hkdf.deriveKey(
      secretKey: SecretKey(kAtt),
      nonce: keySalt,
      info: (BytesBuilder(copy: false)
            ..add(utf8.encode(attachmentKeyInfo))
            ..addByte(0x00)
            ..add(utf8.encode(docId)))
          .takeBytes(),
    );

/// The 96-bit segment nonce: `prefix ‖ u56 big-endian counter ‖ final flag`.
Uint8List _segmentNonce(Uint8List prefix, int counter,
    {required bool isFinal}) {
  final nonce = Uint8List(12);
  nonce.setRange(0, attachmentNoncePrefixSize, prefix);
  for (var i = 0; i < 7; i++) {
    nonce[4 + i] = (counter >> (8 * (6 - i))) & 0xff;
  }
  nonce[11] = isFinal ? 1 : 0;
  return nonce;
}

Uint8List _asBytes(List<int> chunk) =>
    chunk is Uint8List ? chunk : Uint8List.fromList(chunk);

/// Encrypts [plain] as the STREAM attachment of document [docId] under
/// [kAtt] (RV3).
///
/// Constant memory: each incoming chunk is segmented via sub-views — never
/// copied wholesale into a second buffer — and only a sub-segment carry
/// (< 64 KiB) persists between chunks. A segment is sealed non-final only
/// once at least one more byte exists behind it. An empty attachment still
/// emits one final segment over zero bytes.
Stream<List<int>> encryptAttachment(
  Uint8List kAtt,
  String docId,
  Stream<List<int>> plain,
) async* {
  final keySalt = randomBytes(attachmentKeySaltSize);
  final noncePrefix = randomBytes(attachmentNoncePrefixSize);
  final key = await _attachmentKey(kAtt, docId, keySalt);
  yield (BytesBuilder(copy: false)
        ..add(keySalt)
        ..add(noncePrefix))
      .takeBytes();

  var counter = 0;
  final carry = BytesBuilder(copy: true);
  await for (final chunk in plain) {
    final data = _asBytes(chunk);
    var offset = 0;
    // Strictly more than one segment available ⇒ at least one byte remains
    // behind the sealed segment, so it is provably non-final.
    while (carry.length + (data.length - offset) > attachmentSegmentSize) {
      final Uint8List segment;
      if (carry.length == 0) {
        segment =
            Uint8List.sublistView(data, offset, offset + attachmentSegmentSize);
        offset += attachmentSegmentSize;
      } else {
        final take = attachmentSegmentSize - carry.length;
        carry.add(Uint8List.sublistView(data, offset, offset + take));
        offset += take;
        segment = carry.takeBytes();
      }
      yield await _sealSegment(key, noncePrefix, counter++,
          isFinal: false, plain: segment);
    }
    if (offset < data.length) {
      carry.add(Uint8List.sublistView(data, offset));
    }
  }
  yield await _sealSegment(
    key,
    noncePrefix,
    counter,
    isFinal: true,
    plain: carry.takeBytes(),
  );
}

Future<Uint8List> _sealSegment(
  SecretKey key,
  Uint8List noncePrefix,
  int counter, {
  required bool isFinal,
  required Uint8List plain,
}) async {
  final box = await _aesGcm.encrypt(
    plain,
    secretKey: key,
    nonce: _segmentNonce(noncePrefix, counter, isFinal: isFinal),
  );
  return (BytesBuilder(copy: false)
        ..add(box.cipherText)
        ..add(box.mac.bytes))
      .takeBytes();
}

/// Decrypts the STREAM attachment of document [docId] under [kAtt] (RV3).
///
/// Frames the input into 64 KiB + tag units with one-unit lookahead: a unit
/// with at least one byte behind it is non-final; the unit the stream ends
/// on — full or partial — is the final segment and must carry the final
/// flag. The counter sequence is enforced implicitly through the nonces, so
/// truncation, reordering, duplication, or tampering fails loudly with a
/// typed error, and ciphertext sealed for a **different document id**
/// derives a different key and fails at the first segment; a short final
/// read without the flag is an error, not a short file. Constant memory:
/// incoming chunks are segmented via sub-views with at most one unit of
/// carried lookahead — never a second whole-input buffer.
Stream<List<int>> decryptAttachment(
  Uint8List kAtt,
  String docId,
  Stream<List<int>> cipher,
) async* {
  final carry = BytesBuilder(copy: true);
  SecretKey? key;
  Uint8List? noncePrefix;
  var counter = 0;

  await for (final chunk in cipher) {
    final data = _asBytes(chunk);
    var offset = 0;
    if (key == null) {
      final need = attachmentHeaderSize - carry.length;
      if (data.length < need) {
        carry.add(data);
        continue;
      }
      carry.add(Uint8List.sublistView(data, 0, need));
      offset = need;
      final head = carry.takeBytes();
      key = await _attachmentKey(
          kAtt, docId, Uint8List.sublistView(head, 0, attachmentKeySaltSize));
      noncePrefix = Uint8List.fromList(Uint8List.sublistView(
          head, attachmentKeySaltSize, attachmentHeaderSize));
    }
    // Strictly more than one unit available ⇒ the opened unit is non-final.
    while (carry.length + (data.length - offset) > attachmentUnitSize) {
      final Uint8List unit;
      if (carry.length == 0) {
        unit = Uint8List.sublistView(data, offset, offset + attachmentUnitSize);
        offset += attachmentUnitSize;
      } else {
        final take = attachmentUnitSize - carry.length;
        carry.add(Uint8List.sublistView(data, offset, offset + take));
        offset += take;
        unit = carry.takeBytes();
      }
      yield await _openSegment(key, noncePrefix!, counter++,
          isFinal: false, unit: unit);
    }
    if (offset < data.length) {
      carry.add(Uint8List.sublistView(data, offset));
    }
  }

  if (key == null) {
    throw VaultCryptoException.malformed(
        'attachment truncated before its key salt and nonce prefix '
        '(${carry.length} bytes)');
  }
  final tail = carry.takeBytes();
  if (tail.isEmpty) {
    throw const VaultCryptoException.malformed(
        'attachment carries no segments — the final segment never arrived');
  }
  if (tail.length < 16) {
    throw VaultCryptoException.malformed(
        'attachment truncated mid-segment: ${tail.length} trailing bytes '
        'cannot hold a GCM tag');
  }
  yield await _openSegment(key, noncePrefix!, counter,
      isFinal: true, unit: tail);
}

Future<Uint8List> _openSegment(
  SecretKey key,
  Uint8List noncePrefix,
  int counter, {
  required bool isFinal,
  required Uint8List unit,
}) async {
  try {
    final plain = await _aesGcm.decrypt(
      SecretBox(
        Uint8List.sublistView(unit, 0, unit.length - 16),
        nonce: _segmentNonce(noncePrefix, counter, isFinal: isFinal),
        mac: Mac(Uint8List.sublistView(unit, unit.length - 16)),
      ),
      secretKey: key,
    );
    return Uint8List.fromList(plain);
  } on SecretBoxAuthenticationError {
    throw VaultCryptoException.tampered(
        'attachment segment $counter failed authentication — tampered, '
        'reordered, truncated, or swapped-between-documents ciphertext');
  }
}

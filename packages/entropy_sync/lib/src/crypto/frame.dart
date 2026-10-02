import 'dart:convert';
import 'dart:typed_data';

import 'documents.dart';
import 'exceptions.dart';

/// The plaintext of a body's `c` is a binary **frame** (`vault_crypto` RV2):
///
/// `u32 big-endian header length ‖ header JSON (UTF-8) ‖ content bytes`
///
/// The content bytes are present iff `header.inline` — otherwise the frame
/// carries no content and the bytes ride as the STREAM attachment.
Uint8List encodeFrame(DocHeader header, Uint8List? content) {
  assert(header.inline == (content != null),
      'content must be present exactly when the header says inline');
  final headerBytes = utf8.encode(jsonEncode(header.toJson()));
  final length = ByteData(4)..setUint32(0, headerBytes.length); // big-endian
  final frame = BytesBuilder(copy: false)
    ..add(length.buffer.asUint8List())
    ..add(headerBytes);
  if (content != null) frame.add(content);
  return frame.takeBytes();
}

/// Parses an authenticated frame back into its header and inline content.
///
/// The frame arrives GCM-authenticated, so structural breakage here means an
/// encoder bug or scheme drift, not an attacker — still a typed `malformed`
/// error, never garbage output.
({DocHeader header, Uint8List? content}) decodeFrame(Uint8List frame) {
  if (frame.length < 4) {
    throw const VaultCryptoException.malformed(
        'frame is shorter than its length prefix');
  }
  final headerLength = ByteData.sublistView(frame, 0, 4).getUint32(0);
  if (4 + headerLength > frame.length) {
    throw const VaultCryptoException.malformed(
        'frame header length exceeds the frame');
  }
  final header = _headerFromJson(_decodeJson(frame, headerLength));
  final rest = Uint8List.sublistView(frame, 4 + headerLength);
  if (header.inline) {
    if (rest.length != header.size) {
      throw VaultCryptoException.malformed(
          'inline frame carries ${rest.length} content bytes, '
          'header says ${header.size}');
    }
    return (header: header, content: Uint8List.fromList(rest));
  }
  if (rest.isNotEmpty) {
    throw const VaultCryptoException.malformed(
        'non-inline frame carries content bytes');
  }
  return (header: header, content: null);
}

Object? _decodeJson(Uint8List frame, int headerLength) {
  try {
    return jsonDecode(
        utf8.decode(Uint8List.sublistView(frame, 4, 4 + headerLength)));
  } on FormatException {
    throw const VaultCryptoException.malformed(
        'frame header is not valid UTF-8 JSON');
  }
}

DocHeader _headerFromJson(Object? json) {
  if (json is! Map<String, Object?>) {
    throw const VaultCryptoException.malformed('frame header is not a map');
  }
  final path = json['path'];
  final mtime = json['mtime'];
  final size = json['size'];
  final inline = json['inline'];
  if (path is! String || mtime is! int || size is! int || inline is! bool) {
    throw const VaultCryptoException.malformed(
        'frame header is missing {path, mtime, size, inline}');
  }
  return DocHeader(path: path, mtime: mtime, size: size, inline: inline);
}

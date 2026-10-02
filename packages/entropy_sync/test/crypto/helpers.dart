import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:entropy_sync/src/crypto/crypto.dart';
import 'package:test/test.dart';

/// Tiny Argon2id parameters so tests never pay the production 64 MiB cost
/// (the production defaults are asserted separately, without running the
/// KDF).
const tinyParams = Argon2Params(memoryKiB: 64, iterations: 1, parallelism: 1);

/// First-device init with [tinyParams].
Future<KeyMaterial> tinyInit([String passphrase = 'P']) =>
    VaultCrypto.init(passphrase, params: tinyParams);

Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

/// Deterministic binary content spanning the full byte range, with runs of
/// NUL bytes every 100 positions.
Uint8List patternBytes(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = i % 100 < 10 ? 0x00 : (i * 31 + i ~/ 251) & 0xff;
  }
  return bytes;
}

/// ASCII markdown text of exactly [length] bytes.
Uint8List markdownBytes(int length) {
  const line = 'All work and no play makes Jack a dull boy.\n';
  final sb = StringBuffer('# big\n');
  while (sb.length < length) {
    sb.write(line);
  }
  return bytesOf(sb.toString().substring(0, length));
}

/// Collects a byte stream into a single buffer.
Future<Uint8List> collectBytes(Stream<List<int>> stream) async {
  final buffer = BytesBuilder(copy: true);
  await for (final chunk in stream) {
    buffer.add(chunk);
  }
  return buffer.takeBytes();
}

/// Drains [stream], returning whatever bytes were emitted before it
/// completed or erred, plus the error (if any).
Future<({Uint8List bytes, Object? error})> drainBytes(
  Stream<List<int>> stream,
) async {
  final buffer = BytesBuilder(copy: true);
  try {
    await for (final chunk in stream) {
      buffer.add(chunk);
    }
    return (bytes: buffer.takeBytes(), error: null);
  } catch (error) {
    return (bytes: buffer.takeBytes(), error: error);
  }
}

/// Splits [bytes] into chunks of at most [size] bytes.
List<Uint8List> chunked(Uint8List bytes, int size) => [
      for (var i = 0; i < bytes.length; i += size)
        Uint8List.sublistView(bytes, i, min(i + size, bytes.length)),
    ];

/// Matches a [VaultCryptoException] of the given [kind].
Matcher isVaultCrypto(VaultCryptoErrorKind kind) =>
    isA<VaultCryptoException>().having((e) => e.kind, 'kind', kind);

/// Matches a thrown [VaultCryptoException] of the given [kind].
Matcher throwsVaultCrypto(VaultCryptoErrorKind kind) =>
    throwsA(isVaultCrypto(kind));

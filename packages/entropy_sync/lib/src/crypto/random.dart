import 'dart:math';
import 'dart:typed_data';

final _rng = Random.secure();

/// [length] cryptographically random bytes — salts, nonces, nonce prefixes.
Uint8List randomBytes(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = _rng.nextInt(256);
  }
  return bytes;
}

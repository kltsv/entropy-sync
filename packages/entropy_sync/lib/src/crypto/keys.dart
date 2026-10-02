import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'exceptions.dart';
import 'random.dart';

/// The fixed plaintext sealed into the `meta` check value: decrypting it
/// successfully proves the passphrase (`vault_crypto` RV3).
const metaCheckPlaintext = 'vault-sync-check';

/// The AAD binding the check value to the `meta` document (RV3).
const metaCheckAad = 'meta';

/// Argon2id cost parameters (`vault_crypto` RV3).
///
/// [memoryKiB] is the Argon2 `m` parameter in KiB blocks — the production
/// default `65536` is 64 MiB, acceptable on mobile for a one-time derivation
/// per device per vault. Tests may pass tiny parameters; production code
/// uses [production] (the default everywhere parameters are optional).
class Argon2Params {
  /// Argon2 `m`, in KiB blocks.
  final int memoryKiB;

  /// Argon2 `t` — the number of passes.
  final int iterations;

  /// Argon2 `p` — the parallelism degree.
  final int parallelism;

  const Argon2Params({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
  });

  /// The spec-fixed production parameters: `m = 64 MiB, t = 3, p = 1` (RV3).
  static const production =
      Argon2Params(memoryKiB: 64 * 1024, iterations: 3, parallelism: 1);
}

/// Key material derived from the passphrase, held in memory by the shell's
/// process (`vault_crypto` §Outputs) — plus the `meta` document the keys
/// were created from (first init) or verified against (later devices).
///
/// The subkeys are pairwise independent HKDF outputs: possessing one is not
/// possessing another — an id-key compromise does not decrypt bodies (RV3).
class KeyMaterial {
  /// HMAC key for the deterministic one-way path → id map (info `"id"`).
  final Uint8List kId;

  /// AES-256-GCM key for body frames and the `meta` check (info `"body"`).
  final Uint8List kBody;

  /// Root key for per-attachment STREAM keys (info `"att"`).
  final Uint8List kAtt;

  /// The `meta` document map:
  /// `{v, kdf: {alg, salt, m, t, p}, check: {n, c}}` (RV3). Unmodifiable
  /// when built by [createKeyMaterial]; the map handed to
  /// [verifyKeyMaterial] is kept as-is and never mutated.
  final Map<String, Object?> meta;

  KeyMaterial({
    required this.kId,
    required this.kBody,
    required this.kAtt,
    required this.meta,
  });
}

final _aesGcm = AesGcm.with256bits();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// `master = Argon2id(passphrase, salt)` with the given cost parameters
/// (`vault_crypto` RV3). Primitives come from the audited
/// `package:cryptography`, nothing hand-rolled.
Future<Uint8List> deriveMaster(
  String passphrase,
  List<int> salt,
  Argon2Params params,
) async {
  final argon2 = Argon2id(
    memory: params.memoryKiB,
    iterations: params.iterations,
    parallelism: params.parallelism,
    hashLength: 32,
  );
  final key =
      await argon2.deriveKeyFromPassword(password: passphrase, nonce: salt);
  return Uint8List.fromList(await key.extractBytes());
}

/// One 32-byte subkey via HKDF-SHA256 from [master] with the given [info]
/// and an empty HKDF salt (RV3).
Future<Uint8List> _subkey(Uint8List master, String info) async {
  final key = await _hkdf.deriveKey(
    secretKey: SecretKey(master),
    info: utf8.encode(info),
  );
  return Uint8List.fromList(await key.extractBytes());
}

Future<(Uint8List, Uint8List, Uint8List)> _subkeys(Uint8List master) async => (
      await _subkey(master, 'id'),
      await _subkey(master, 'body'),
      await _subkey(master, 'att'),
    );

/// First-device init: generates a random per-vault salt (unless a fixed
/// [salt] is injected by a test), derives the keys, and builds the `meta`
/// document — the database's **only plaintext document** (`vault_crypto`
/// RV3).
Future<KeyMaterial> createKeyMaterial(
  String passphrase, {
  Argon2Params params = Argon2Params.production,
  Uint8List? salt,
}) async {
  final vaultSalt = salt ?? randomBytes(16);
  final master = await deriveMaster(passphrase, vaultSalt, params);
  final (kId, kBody, kAtt) = await _subkeys(master);

  final nonce = randomBytes(12);
  final box = await _aesGcm.encrypt(
    utf8.encode(metaCheckPlaintext),
    secretKey: SecretKey(kBody),
    nonce: nonce,
    aad: utf8.encode(metaCheckAad),
  );
  final check = (BytesBuilder(copy: false)
        ..add(box.cipherText)
        ..add(box.mac.bytes))
      .takeBytes();

  final meta = Map<String, Object?>.unmodifiable(<String, Object?>{
    'v': 1,
    'kdf': Map<String, Object?>.unmodifiable(<String, Object?>{
      'alg': 'argon2id',
      'salt': base64Encode(vaultSalt),
      'm': params.memoryKiB,
      't': params.iterations,
      'p': params.parallelism,
    }),
    'check': Map<String, Object?>.unmodifiable(<String, Object?>{
      'n': base64Encode(nonce),
      'c': base64Encode(check),
    }),
  });
  return KeyMaterial(kId: kId, kBody: kBody, kAtt: kAtt, meta: meta);
}

/// Later-device init: derives keys with the salt and parameters stored in
/// [meta] and verifies the passphrase against the check value **before any
/// sync runs** (`vault_crypto` RV3). A failed check is a typed
/// wrong-passphrase error; a structurally broken `meta` is `malformed`.
Future<KeyMaterial> verifyKeyMaterial(
  String passphrase,
  Map<String, Object?> meta,
) async {
  if (meta['v'] != 1) {
    throw VaultCryptoException.malformed(
        'unsupported meta version: ${meta['v']}');
  }
  final kdf = _requireMap(meta['kdf'], 'kdf');
  if (kdf['alg'] != 'argon2id') {
    throw VaultCryptoException.malformed('unsupported meta KDF: ${kdf['alg']}');
  }
  final salt = _requireBase64(kdf['salt'], 'kdf.salt');
  final params = Argon2Params(
    memoryKiB: _requireInt(kdf['m'], 'kdf.m'),
    iterations: _requireInt(kdf['t'], 'kdf.t'),
    parallelism: _requireInt(kdf['p'], 'kdf.p'),
  );
  final check = _requireMap(meta['check'], 'check');
  final nonce = _requireBase64(check['n'], 'check.n');
  final sealed = _requireBase64(check['c'], 'check.c');
  if (sealed.length < 16) {
    throw const VaultCryptoException.malformed(
        'meta check.c is shorter than a GCM tag');
  }

  final master = await deriveMaster(passphrase, salt, params);
  final (kId, kBody, kAtt) = await _subkeys(master);

  final List<int> plain;
  try {
    plain = await _aesGcm.decrypt(
      SecretBox(
        Uint8List.sublistView(sealed, 0, sealed.length - 16),
        nonce: nonce,
        mac: Mac(Uint8List.sublistView(sealed, sealed.length - 16)),
      ),
      secretKey: SecretKey(kBody),
      aad: utf8.encode(metaCheckAad),
    );
  } on SecretBoxAuthenticationError {
    throw const VaultCryptoException.wrongPassphrase(
        'the passphrase failed verification against the meta check value');
  }
  if (utf8.decode(plain, allowMalformed: true) != metaCheckPlaintext) {
    throw const VaultCryptoException.wrongPassphrase(
        'the meta check value decrypted to an unexpected plaintext');
  }
  return KeyMaterial(kId: kId, kBody: kBody, kAtt: kAtt, meta: meta);
}

Map<String, Object?> _requireMap(Object? value, String field) {
  if (value is Map<String, Object?>) return value;
  throw VaultCryptoException.malformed('meta.$field is not a map');
}

int _requireInt(Object? value, String field) {
  if (value is int) return value;
  throw VaultCryptoException.malformed('meta.$field is not an integer');
}

Uint8List _requireBase64(Object? value, String field) {
  if (value is! String) {
    throw VaultCryptoException.malformed('meta.$field is not a string');
  }
  try {
    return base64Decode(value);
  } on FormatException {
    throw VaultCryptoException.malformed('meta.$field is not valid base64');
  }
}

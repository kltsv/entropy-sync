import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// The setup-URI transfer cipher (`vault_sync_control` D9).
///
/// A setup-URI's payload is encrypted under a **short transfer secret** so the
/// copyable string alone discloses nothing. This codec is deliberately separate
/// from the vault E2EE (`vault_crypto`): it protects a one-time transfer, not
/// the vault, and it must stay **byte-for-byte compatible** with the TypeScript
/// port in the Obsidian plugin (verified by a cross-language fixture test).
///
/// Wire format (inherited from the original v1 codec, kept stable):
/// `base64(nonce ‖ ciphertext ‖ tag)` under AES-256-GCM with a key derived as
/// `PBKDF2-HMAC-SHA256(secret, salt = "entropy-sync-v1-vault-salt", 120k)`.
///
/// **Accepted threat model** (reviewed, deliberate): this protects a
/// **one-time, short-lived transfer secret** for a copy-pasted setup string —
/// it is *not* vault-grade cryptography. The PBKDF2 salt is a fixed global
/// constant because the TS port in the Obsidian plugin must stay
/// byte-compatible with it, which means identical secrets derive identical
/// keys and offline guessing amortizes across users at ~120k PBKDF2
/// iterations per guess. A captured setup-URI plus a guessed weak secret
/// discloses only the encrypted payload — server endpoint, database name,
/// and server credentials — never the vault E2EE passphrase; vault content
/// stays protected by `vault_crypto` regardless. The mitigation is
/// operational, not cryptographic: use a generated, high-entropy transfer
/// secret and treat the URI as spent once redeemed.
class TransferCipher {
  TransferCipher._(this._key);

  static const _salt = 'entropy-sync-v1-vault-salt';
  static final _gcm = AesGcm.with256bits();

  final SecretKey _key;

  /// Derive from the transfer secret. Moderately expensive (PBKDF2) — derive
  /// once per encode/decode.
  static Future<TransferCipher> derive(String secret) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 120000,
      bits: 256,
    );
    final key = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(secret)),
      nonce: utf8.encode(_salt),
    );
    return TransferCipher._(key);
  }

  Future<String> encryptText(String plaintext) async {
    final box = await _gcm.encrypt(utf8.encode(plaintext), secretKey: _key);
    return base64.encode(box.concatenation());
  }

  /// Throws [TransferCipherException] on a wrong secret or corrupt payload, so a
  /// bad setup-URI is rejected before anything is stored.
  Future<String> decryptText(String cipherText) async {
    try {
      final box = SecretBox.fromConcatenation(
        base64.decode(cipherText),
        nonceLength: _gcm.nonceLength,
        macLength: _gcm.macAlgorithm.macLength,
      );
      return utf8.decode(await _gcm.decrypt(box, secretKey: _key));
    } on SecretBoxAuthenticationError {
      throw TransferCipherException('wrong transfer secret or corrupt payload');
    } on FormatException {
      throw TransferCipherException('malformed setup payload');
    }
  }
}

class TransferCipherException implements Exception {
  TransferCipherException(this.message);
  final String message;

  @override
  String toString() => 'TransferCipherException: $message';
}

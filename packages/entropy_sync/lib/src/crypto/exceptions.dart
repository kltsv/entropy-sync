/// What went wrong, as a closed set — the spec demands **typed failures**,
/// never silently corrupt plaintext (`vault_crypto` §Failure modes, RV3).
enum VaultCryptoErrorKind {
  /// The passphrase failed verification against the `meta` check value —
  /// raised before any vault document is touched (`vault_crypto` RV3).
  wrongPassphrase,

  /// Authenticated decryption failed: the body's GCM tag (with its AAD = id
  /// binding), the `meta` check value, or a STREAM attachment segment.
  /// Covers tampering, transplanting, truncation, and reordering (RV2, RV3).
  tampered,

  /// Structurally invalid input: a malformed `meta` or body map, a bad
  /// base64 field, a broken frame, or an attachment too short to even carry
  /// its key salt and nonce prefix.
  malformed,

  /// A fresh `init` was attempted against a database that already has a
  /// `meta` — `init` never overwrites an existing `meta` (`vault_crypto`
  /// RV3).
  metaExists,
}

/// A typed failure of the `vault_crypto` module.
///
/// Every error path surfaces as one of the [VaultCryptoErrorKind]s; callers
/// branch on [kind], and [message] carries human-readable detail for logs.
class VaultCryptoException implements Exception {
  final VaultCryptoErrorKind kind;
  final String message;

  const VaultCryptoException(this.kind, this.message);

  const VaultCryptoException.wrongPassphrase(this.message)
      : kind = VaultCryptoErrorKind.wrongPassphrase;

  const VaultCryptoException.tampered(this.message)
      : kind = VaultCryptoErrorKind.tampered;

  const VaultCryptoException.malformed(this.message)
      : kind = VaultCryptoErrorKind.malformed;

  const VaultCryptoException.metaExists(this.message)
      : kind = VaultCryptoErrorKind.metaExists;

  @override
  String toString() => 'VaultCryptoException(${kind.name}): $message';
}

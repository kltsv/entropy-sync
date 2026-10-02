/// Error surface of the `vault_sync` module.
library;

/// What went wrong, coarsely — the shells branch on this to decide between
/// "offline" and "broken" states (`vault_sync` R17).
enum SyncErrorKind {
  /// The hub could not be reached (network / DNS / TLS failure).
  unreachable,

  /// The hub rejected the credentials (401/403).
  auth,

  /// A payload could not be decrypted — reserved for the shells composing
  /// `vault_crypto` around this module; the sync core itself never decrypts
  /// (RV1).
  decrypt,

  /// The server answered outside the protocol (unexpected status, malformed
  /// body, MVCC conflict on a plain PUT).
  protocol,
}

/// A replication failure, carried to the shells with its [kind] so control
/// surfaces can distinguish an unreachable hub from an auth failure
/// (`vault_sync` R17).
class SyncException implements Exception {
  SyncException(this.kind, this.message, {this.statusCode});

  final SyncErrorKind kind;
  final String message;

  /// The HTTP status the server answered with, when the failure was an
  /// unexpected status (e.g. 413 from a size-capped proxy — push replication
  /// splits its batch and retries smaller on that one).
  final int? statusCode;

  @override
  String toString() => 'SyncException(${kind.name}): $message';
}

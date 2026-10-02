/// Public API of the `vault_crypto` module — the E2EE layer of
/// entropy-sync: a pure transformation between logical vault documents and
/// wire documents (`vault_crypto`, RV1–RV3).
///
/// The frame codec (`frame.dart`) and the raw random helper stay internal;
/// everything a shell or the daemon composes with is exported here.
library;

export 'documents.dart';
export 'exceptions.dart';
export 'keys.dart';
export 'stream_cipher.dart';
export 'vault_crypto.dart';

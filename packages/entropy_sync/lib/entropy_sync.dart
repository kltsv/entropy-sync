/// The pure-Dart sync library of the entropy stack — the two modules of the
/// vault-sync design that replication is made of (`vault_sync`,
/// `vault_crypto`), written once and reused verbatim by the desktop daemon
/// and the Flutter app. The modules never import each other; shells compose
/// them (RV1). History is a separate package (`entropy_hist`) that neither
/// depends on this one nor is depended on by it.
library;

// The document-opaque replication client (`vault_sync`).
export 'src/sync/sync.dart';

// End-to-end encryption as a pure transformation (`vault_crypto`).
export 'src/crypto/crypto.dart';

import 'dart:io';

import 'package:path/path.dart' as p;

/// Per-vault secret storage for the daemon (`vault_daemon` C11, RV10).
///
/// Secrets — the E2EE passphrase and the server password — are keyed by vault
/// and live **outside** every vault and outside anything the daemon syncs. The
/// primary backend is the macOS Keychain; the file store is the headless
/// fallback and the cross-front-end interop path (the Obsidian plugin and the
/// app write the same `~/.entropy-sync/secrets/<vault>.<key>` files today).
abstract interface class DaemonSecretStore {
  Future<void> write(String vaultId, String key, String value);
  Future<String?> read(String vaultId, String key);
  Future<void> delete(String vaultId, String key);

  static const keyPassphrase = 'passphrase';
  static const keyServerPassword = 'serverPassword';
}

/// macOS Keychain via the `security` CLI (generic passwords). Service is
/// `entropy-sync/<vaultId>`, account is the secret key — one item per secret,
/// upserted with `-U`.
class KeychainSecretStore implements DaemonSecretStore {
  KeychainSecretStore({this.securityBinary = '/usr/bin/security'});

  final String securityBinary;

  static bool get isSupported => Platform.isMacOS;

  String _service(String vaultId) => 'entropy-sync/$vaultId';

  @override
  Future<void> write(String vaultId, String key, String value) async {
    final result = await Process.run(securityBinary, [
      'add-generic-password',
      '-U',
      '-s',
      _service(vaultId),
      '-a',
      key,
      '-w',
      value,
    ]);
    if (result.exitCode != 0) {
      throw StateError('keychain write failed: ${result.stderr}');
    }
  }

  @override
  Future<String?> read(String vaultId, String key) async {
    final result = await Process.run(securityBinary, [
      'find-generic-password',
      '-s',
      _service(vaultId),
      '-a',
      key,
      '-w',
    ]);
    if (result.exitCode != 0) return null;
    final out = result.stdout as String;
    return out.endsWith('\n') ? out.substring(0, out.length - 1) : out;
  }

  @override
  Future<void> delete(String vaultId, String key) async {
    await Process.run(securityBinary, [
      'delete-generic-password',
      '-s',
      _service(vaultId),
      '-a',
      key,
    ]);
  }
}

/// The user-only file fallback, byte-compatible with the front-ends' stores:
/// `<dir>/<urlencode(vaultId)>.<urlencode(key)>`, contents = the secret, mode
/// 0600. Used headless and to read secrets a front-end stored.
class FileSecretStore implements DaemonSecretStore {
  FileSecretStore(this.dir);

  final String dir;

  String _fileFor(String vaultId, String key) => p.join(
        dir,
        '${Uri.encodeComponent(vaultId)}.${Uri.encodeComponent(key)}',
      );

  @override
  Future<void> write(String vaultId, String key, String value) async {
    final file = File(_fileFor(vaultId, key));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(value);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', file.path]);
    }
  }

  @override
  Future<String?> read(String vaultId, String key) async {
    final file = File(_fileFor(vaultId, key));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  @override
  Future<void> delete(String vaultId, String key) async {
    final file = File(_fileFor(vaultId, key));
    if (file.existsSync()) file.deleteSync();
  }
}

/// Keychain first, file fallback — reads consult both (so secrets stored by a
/// front-end's file store are found), writes go to the primary backend.
class ChainedSecretStore implements DaemonSecretStore {
  ChainedSecretStore(this.primary, this.fallback);

  final DaemonSecretStore primary;
  final DaemonSecretStore fallback;

  @override
  Future<void> write(String vaultId, String key, String value) =>
      primary.write(vaultId, key, value);

  @override
  Future<String?> read(String vaultId, String key) async =>
      await primary.read(vaultId, key) ?? await fallback.read(vaultId, key);

  @override
  Future<void> delete(String vaultId, String key) async {
    await primary.delete(vaultId, key);
    await fallback.delete(vaultId, key);
  }
}

/// The production store for a daemon rooted at [stateRoot]
/// (`~/.entropy-sync`): Keychain when available, always falling back to the
/// shared secrets directory the front-ends use.
DaemonSecretStore productionSecretStore(String stateRoot) {
  final files = FileSecretStore(p.join(stateRoot, 'secrets'));
  if (KeychainSecretStore.isSupported) {
    return ChainedSecretStore(KeychainSecretStore(), files);
  }
  return files;
}

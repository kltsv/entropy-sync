import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'secret_store.dart';

/// The daemon's persistent, **non-secret** vault registry (`vault_daemon`
/// RV10): which vaults this daemon serves, written by `init` and the control
/// channel's add/edit-vault command, read at startup. Lives in the daemon's
/// state root, outside every vault. Secrets stay in the [DaemonSecretStore];
/// this file structurally cannot hold one.
class VaultRegistry {
  VaultRegistry(this.stateRoot);

  final String stateRoot;

  File get _file => File(p.join(stateRoot, 'vaults.json'));

  /// Every entry, in the one shape the registry has — per module. An entry
  /// in any other shape is refused with a clear error rather than guessed at.
  List<Map<String, Object?>> _readAll() {
    if (!_file.existsSync()) return [];
    final json = jsonDecode(_file.readAsStringSync());
    final entries = (json as List).cast<Map<String, Object?>>();
    for (final entry in entries) {
      if (entry['modules'] is! List) {
        throw FormatException(
          'vaults.json: the entry for "${entry['vaultId']}" is not shaped per '
          'module (no "modules" list); register the vault again',
        );
      }
    }
    return entries;
  }

  void _writeAll(List<Map<String, Object?>> entries) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(entries),
    );
  }

  /// Upsert a vault's non-secret profile (idempotent by vaultId).
  void upsert(VaultProfile profile) {
    final entries = _readAll();
    entries.removeWhere((e) => e['vaultId'] == profile.vaultId);
    entries.add(profile.toRegistryJson());
    _writeAll(entries);
  }

  void remove(String vaultId) {
    final entries = _readAll()..removeWhere((e) => e['vaultId'] == vaultId);
    _writeAll(entries);
  }

  List<Map<String, Object?>> entries() => _readAll();

  /// Load every registered vault as a full profile, hydrating secrets from the
  /// store — for vaults that enable sync; a history-only vault has none to
  /// read (`daemon-modules` R8). A vault whose secrets are missing is
  /// returned with empty secrets — the engine will surface a
  /// bad-passphrase/auth error rather than the registry guessing.
  Future<List<VaultProfile>> loadProfiles(DaemonSecretStore secrets) async {
    final out = <VaultProfile>[];
    for (final entry in _readAll()) {
      final vaultId = entry['vaultId'] as String;
      final bare = VaultProfile.fromRegistryJson(entry,
          serverPassword: '', passphrase: '');
      if (!bare.syncEnabled) {
        out.add(bare);
        continue;
      }
      out.add(bare.copyWith(
        serverPassword:
            await secrets.read(vaultId, DaemonSecretStore.keyServerPassword) ??
                '',
        passphrase:
            await secrets.read(vaultId, DaemonSecretStore.keyPassphrase) ?? '',
      ));
    }
    return out;
  }
}

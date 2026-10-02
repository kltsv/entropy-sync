import 'dart:convert';
import 'dart:io';

import 'package:entropy_hist/entropy_hist.dart' show ExclusionMatcher;
import 'package:entropy_daemon/src/config.dart';
import 'package:entropy_daemon/src/last_synced.dart';
import 'package:entropy_daemon/src/secret_store.dart';
import 'package:entropy_daemon/src/transfer_cipher.dart';
import 'package:entropy_daemon/src/vault_registry.dart';
import 'package:test/test.dart';

/// Unit coverage for the daemon's standalone support pieces (`vault_daemon`
/// RV8, RV10, C11 and `vault_sync_control` D9): the exclusion matcher, the
/// last-synced cursor, the secret stores, the vault registry, and the setup-URI
/// transfer cipher.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('entropyd-test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('ExclusionMatcher (RV8)', () {
    final matcher = ExclusionMatcher(VaultProfile.defaultExclusions);

    test('default exclusions match at any depth and by prefix', () {
      expect(matcher.excludes('.DS_Store'), isTrue);
      expect(matcher.excludes('notes/.DS_Store'), isTrue);
      expect(matcher.excludes('.trash/old.md'), isTrue);
      expect(matcher.excludes('.git/config'), isTrue);
      expect(matcher.excludes('_workspace/scripts/x.py'), isTrue);
      expect(matcher.excludes('.obsidian/workspace.json'), isTrue);
      expect(matcher.excludes('.obsidian/workspace-mobile.json'), isTrue);
      expect(
        matcher.excludes('.obsidian/plugins/obsidian-livesync/main.js'),
        isTrue,
      );
      expect(
        matcher.excludes('.obsidian/plugins/remotely-save/data.json'),
        isTrue,
      );
    });

    test('.hist/ and ordinary .obsidian config are NOT excluded (RV8)', () {
      expect(
          matcher.excludes('.hist/notes/a.md/0000000000001.snapshot'), isFalse);
      expect(matcher.excludes('.obsidian/app.json'), isFalse);
      expect(
          matcher.excludes('.obsidian/plugins/entropy-sync-obsidian/main.js'),
          isFalse);
      expect(matcher.excludes('notes/todo.md'), isFalse);
    });

    test('glob matches only within one segment', () {
      expect(matcher.excludes('sub/.obsidian/workspace.json'), isFalse);
    });
  });

  group('LastSyncedIndex', () {
    test('persists and reloads entries', () {
      final path = '${tmp.path}/cursor.json';
      final index = LastSyncedIndex(path);
      index.set(
        'notes/a.md',
        const LastSyncedEntry(hash: 'h1', mtime: 111, size: 5),
      );
      index.set(
        'img/b.png',
        const LastSyncedEntry(hash: 'h2', mtime: 222, size: 9),
      );
      index.remove('img/b.png');

      final reloaded = LastSyncedIndex(path);
      expect(reloaded['notes/a.md']?.hash, 'h1');
      expect(reloaded['notes/a.md']?.mtime, 111);
      expect(reloaded['img/b.png'], isNull);
      expect(reloaded.paths, ['notes/a.md']);
    });

    test('a corrupt cursor file resets instead of crashing', () {
      final path = '${tmp.path}/cursor.json';
      File(path).writeAsStringSync('not json');
      final index = LastSyncedIndex(path);
      expect(index.paths, isEmpty);
    });
  });

  group('FileSecretStore (C11)', () {
    test('is byte-compatible with the front-end layout', () async {
      final store = FileSecretStore('${tmp.path}/secrets');
      await store.write('my vault', DaemonSecretStore.keyPassphrase, 's3cret');
      // Same file name scheme the TS plugin and the app use:
      // <urlencode(vaultId)>.<urlencode(key)>.
      final file = File('${tmp.path}/secrets/my%20vault.passphrase');
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), 's3cret');
      expect(
        await store.read('my vault', DaemonSecretStore.keyPassphrase),
        's3cret',
      );
      await store.delete('my vault', DaemonSecretStore.keyPassphrase);
      expect(
        await store.read('my vault', DaemonSecretStore.keyPassphrase),
        isNull,
      );
    });
  });

  group('VaultRegistry (RV10)', () {
    test('upserts idempotently and never stores secrets', () async {
      final registry = VaultRegistry(tmp.path);
      final profile = VaultProfile(
        vaultId: 'v1',
        vaultRoot: '/tmp/v1',
        endpoint: 'https://hub.example',
        database: 'vault',
        serverUser: 'u',
        serverPassword: 'server-pw',
        passphrase: 'pass-ph',
      );
      registry.upsert(profile);
      registry.upsert(profile); // idempotent
      expect(registry.entries(), hasLength(1));

      final raw = File('${tmp.path}/vaults.json').readAsStringSync();
      expect(raw, isNot(contains('server-pw')));
      expect(raw, isNot(contains('pass-ph')));

      final secrets = FileSecretStore('${tmp.path}/secrets');
      await secrets.write(
          'v1', DaemonSecretStore.keyServerPassword, 'server-pw');
      await secrets.write('v1', DaemonSecretStore.keyPassphrase, 'pass-ph');
      final profiles = await registry.loadProfiles(secrets);
      expect(profiles.single.serverPassword, 'server-pw');
      expect(profiles.single.passphrase, 'pass-ph');
      expect(profiles.single.effectiveWriterName, 'v1');
    });
  });

  group('TransferCipher (D9)', () {
    test('round-trips and rejects a wrong secret', () async {
      final cipher = await TransferCipher.derive('correct horse');
      final blob = await cipher.encryptText('{"endpoint":"https://x"}');
      expect(await cipher.decryptText(blob), '{"endpoint":"https://x"}');

      final wrong = await TransferCipher.derive('wrong secret');
      await expectLater(
        wrong.decryptText(blob),
        throwsA(isA<TransferCipherException>()),
      );
    });

    test(
        'the wire format is base64(nonce ‖ ct ‖ tag), as the plugin port '
        'expects', () async {
      final cipher = await TransferCipher.derive('s');
      final raw = base64.decode(await cipher.encryptText('hi'));
      // 12-byte GCM nonce + 2 bytes plaintext + 16-byte tag.
      expect(raw.length, 12 + 2 + 16);
    });
  });
}

/// `vault_daemon` test-spec — "Composing the modules (RV1)" and
/// "Init (D5, RV3, RV10)".
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  // A marker that cannot appear inside base64 ciphertext by chance (`::` is
  // outside the base64 alphabet).
  const marker = 'plain::text::marker::42';

  /// The daemon's `init` verb, realized through the same library pieces
  /// `bin/entropyd.dart _init` composes: store the profile in the
  /// registry, place the secrets, build the production shell (database +
  /// `meta` write-or-verify), and run the first scan.
  Future<VaultHandle> initVault(String name,
      {String passphrase = defaultPassphrase}) async {
    final handle = h.handleFor(name);
    final registry = VaultRegistry(handle.stateRoot);
    final secrets = FileSecretStore(p.join(handle.stateRoot, 'secrets'));
    final profile = h.profileFor(handle, passphrase: passphrase);
    await secrets.write(
        name, DaemonSecretStore.keyServerPassword, profile.serverPassword);
    await secrets.write(name, DaemonSecretStore.keyPassphrase, passphrase);
    registry.upsert(profile);
    handle.shell = await h.buildShell(handle, profile);
    await handle.shell.reconcile();
    return handle;
  }

  test(
      'the replica and the server hold only wire documents; '
      'plaintext exists only as files (RV1)', () async {
    final mac = await h.spawn('mac');
    mac.write('secret.md', 'top note $marker\n');
    await mac.shell.reconcile();

    // The sole plaintext copy is the real file in the vault folder.
    expect(mac.file('secret.md').readAsStringSync(), contains(marker));

    // The sync replica holds wire (encrypted) documents only.
    final replicaIds = mac.shell.store.allDocIds;
    expect(replicaIds, contains(mac.docId('secret.md')));
    for (final id in replicaIds) {
      if (id == 'meta') continue;
      final raw = jsonEncode(mac.shell.store.get(id)?.body ?? const {});
      expect(raw, isNot(contains(marker)));
      expect(raw, isNot(contains('secret')));
    }
    // ... including its persisted form on disk.
    final replicaDir = Directory(p.join(mac.stateDir, 'replica'));
    expect(replicaDir.existsSync(), isTrue);
    for (final f in replicaDir.listSync(recursive: true).whereType<File>()) {
      expect(f.readAsStringSync(), isNot(contains(marker)));
    }

    // The server, too, sees only ciphertext — ids and bodies alike.
    expect(h.serverRawJson(), isNot(contains(marker)));
    for (final id in h.serverStore().allDocIds) {
      expect(id, isNot(contains('secret')));
    }
  });

  test(
      'init on an empty database stores the profile, places secrets, '
      'and writes `meta` (D5, RV3, RV10)', () async {
    final handle = h.handleFor('mac');
    handle.write('a.md', 'first note\n');
    handle.write('notes/b.md', 'second note\n');
    await initVault('mac');

    // The profile lands in the daemon's state directory, outside the vault.
    final registryFile = File(p.join(handle.stateRoot, 'vaults.json'));
    expect(registryFile.existsSync(), isTrue);
    expect(registryFile.readAsStringSync(), contains('"mac"'));
    expect(p.isWithin(handle.vaultRoot, registryFile.path), isFalse);

    // Secrets land in the secret store keyed by the vault…
    final secrets = FileSecretStore(p.join(handle.stateRoot, 'secrets'));
    expect(await secrets.read('mac', DaemonSecretStore.keyPassphrase),
        defaultPassphrase);
    expect(
        await secrets.read('mac', DaemonSecretStore.keyServerPassword), 'pw');
    // …never inside the vault, and never on the server.
    for (final rel in handle.vaultPaths()) {
      expect(handle.file(rel).readAsStringSync(),
          isNot(contains(defaultPassphrase)));
    }
    expect(h.serverRawJson(), isNot(contains(defaultPassphrase)));

    // A single plaintext `meta` (salt, KDF parameters, check value) on the
    // formerly-empty database; every other document is ciphertext-only.
    final meta = h.serverStore().get('meta');
    expect(meta, isNotNull);
    final kdf = (meta!.body!['kdf'] as Map).cast<String, Object?>();
    expect(kdf['salt'], isNotNull);
    expect(kdf['alg'], isNotNull);
    expect(meta.body!['check'], isNotNull);
    for (final id in h.serverStore().allDocIds) {
      if (id == 'meta') continue;
      expect(h.serverStore().get(id)!.body!.keys.toSet(), {'v', 'n', 'c'});
    }

    // The first scan ran: both files were pushed as encrypted revisions.
    expect(h.serverStore().get(handle.docId('a.md')), isNotNull);
    expect(h.serverStore().get(handle.docId('notes/b.md')), isNotNull);
  });

  test(
      'init on a populated database verifies the passphrase and refuses to '
      'overwrite `meta` (RV3)', () async {
    final mac = h.handleFor('mac');
    mac.write('notes/hello.md', 'hello from A\n');
    await initVault('mac');
    final metaBefore = jsonEncode(h.serverStore().get('meta')!.body);

    // The second machine: correct passphrase against the populated database.
    final desk = await initVault('desk');

    // Replication proceeded and the vault materialized.
    expect(desk.file('notes/hello.md').existsSync(), isTrue);
    expect(desk.file('notes/hello.md').readAsStringSync(), 'hello from A\n');

    // The existing `meta` was left untouched — init never overwrites it.
    expect(jsonEncode(h.serverStore().get('meta')!.body), metaBefore);
    expect(h.serverStore().allDocIds.where((id) => id == 'meta').length, 1);
  });

  test(
      'a wrong passphrase surfaces as the vault\'s error state and no sync '
      'runs (RV3)', () async {
    final mac = h.handleFor('mac');
    mac.write('a.md', 'the real content\n');
    await initVault('mac');
    final serverDocsBefore = h.serverStore().allDocIds.length;

    final thief = h.handleFor('thief');
    final daemon = Daemon(
      version: 'test',
      shellFactory: (profile) => h.buildShell(h.handleFor('thief'), profile),
    );
    h.emulator.clearLog();
    await daemon.addVault(h.profileFor(thief, passphrase: 'typo passphrase'));

    // The meta check failed → the vault is in the error state, visible in
    // status.
    final status = daemon.status().vaults.single;
    expect(status.state, SyncState.error);
    expect(status.error, contains('bad passphrase'));

    // Nothing was pulled, nothing was scanned, nothing was pushed.
    expect(thief.vaultPaths(), isEmpty);
    expect(h.serverStore().allDocIds.length, serverDocsBefore);
    expect(Directory(p.join(thief.stateDir, 'replica')).existsSync(), isFalse);
    for (final req in h.emulator.requestLog) {
      expect(req.path, isNot(contains('_changes')));
      expect(req.path, isNot(contains('_bulk')));
      expect(req.path, isNot(contains('_revs_diff')));
    }
  });
}

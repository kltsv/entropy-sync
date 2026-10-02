/// `vault_daemon` test-spec — "Module hosting" (`daemon-modules` R1,
/// R2, R3, R8): any subset of modules works, a failing module is isolated
/// and named, and the persisted profile is shaped per module — the only
/// shape the registry reads.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:entropy_hist/entropy_hist.dart';
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

/// A history store that fails every write — the module rigged to fail (R3).
class _FailingHistStore implements HistStore {
  _FailingHistStore(this.inner);
  final HistStore inner;
  int attempts = 0;

  @override
  Future<List<HistFileHeader>> listHeaders(String path) =>
      inner.listHeaders(path);

  @override
  Future<List<String>> listPaths() => inner.listPaths();

  @override
  Future<Uint8List> read(String path, String filename) =>
      inner.read(path, filename);

  @override
  Future<void> write(String path, String filename, List<int> bytes) async {
    attempts++;
    throw const FileSystemException('disk full (simulated)');
  }
}

void main() {
  late Harness h;
  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  test(
      'a vault with history only serves with no connection and no passphrase '
      '(R1, R8)', () async {
    final mac = h.handleFor('mac');
    mac.write('notes/plan.md', 'v1\n');
    await h.spawn('mac', modules: {VaultModule.history});
    await mac.shell.reconcile();
    mac.write('notes/plan.md', 'v2\n');
    await mac.shell.reconcile();
    await mac.shell.reconcile();

    expect(mac.shell.sync, isNull, reason: 'no replication module at all');
    expect(mac.recordedVersions('notes/plan.md'),
        containsAll([sha256OfText('v1\n'), sha256OfText('v2\n')]),
        reason: 'history over a plain folder, from the first scan on');
    expect(mac.histHeaders('notes/plan.md').every((x) => x.writer == 'mac'),
        isTrue);
    expect(h.serverStore().allDocIds, isEmpty,
        reason: 'the server received nothing — not even a meta document');
    expect(Directory(p.join(mac.stateDir, 'replica')).existsSync(), isFalse,
        reason: 'no replica was opened');

    // Registered over the control channel, it stores no secret.
    final stateRoot = p.join(h.tmp.path, 'daemon-state');
    final secrets = FileSecretStore(p.join(stateRoot, 'secrets'));
    final daemon = Daemon(
      version: 't',
      shellFactory: h.daemonShell,
      registry: VaultRegistry(stateRoot),
      secrets: secrets,
    );
    await daemon.registerVault(AddVaultRequest(
      profile: h.profileFor(h.handleFor('bare'),
          modules: {VaultModule.history}).toRegistryJson(),
      passphrase: '',
      serverPassword: '',
    ));
    expect(await secrets.read('bare', DaemonSecretStore.keyPassphrase), isNull);
    expect(await secrets.read('bare', DaemonSecretStore.keyServerPassword),
        isNull);
    final status = daemon.status().vaults.single;
    expect(status.state, SyncState.running);
    expect(status.modules, ['history']);
    expect(status.unsynced, 0);
    expect(status.error, isNull);
    expect(status.degraded, isEmpty);
    await daemon.stopAll();
  });

  test('a vault with sync only replicates and creates no .hist/ (R1)',
      () async {
    final mac = await h.spawn('mac', modules: {VaultModule.sync});
    mac.write('notes/a.md', 'first\n');
    await mac.shell.reconcile();
    mac.write('notes/a.md', 'second\n');
    await mac.shell.reconcile();
    final desk = await h.spawn('desk', modules: {VaultModule.sync});
    await h.settle([mac, desk]);

    expect(desk.file('notes/a.md').readAsStringSync(), 'second\n',
        reason: 'the content converges');
    expect(mac.shell.history, isNull);
    expect(Directory(p.join(mac.vaultRoot, '.hist')).existsSync(), isFalse,
        reason: 'nothing was recorded');
    expect(Directory(p.join(desk.vaultRoot, '.hist')).existsSync(), isFalse);
    expect(mac.shell.divergent, 0);
  });

  test('a failing module is isolated, and status names it (R3)', () async {
    late _FailingHistStore failing;
    final mac = h.handleFor('mac');
    mac.write('notes/a.md', 'first\n');
    await h.spawn('mac', histStore: (root) {
      return failing = _FailingHistStore(FsHistStore(root));
    });
    await mac.shell.reconcile(); // seed: baseline only
    final desk = await h.spawn('desk');
    await h.settle([mac, desk]);

    // Every edit is replicated while history cannot write a byte.
    mac.write('notes/a.md', 'second\n');
    await mac.shell.reconcile();
    mac.write('notes/b.md', 'new\n');
    await mac.shell.reconcile();
    await h.settle([mac, desk]);

    expect(desk.file('notes/a.md').readAsStringSync(), 'second\n');
    expect(desk.file('notes/b.md').readAsStringSync(), 'new\n');
    expect(failing.attempts, greaterThan(0), reason: 'history did try');
    expect(Directory(p.join(mac.vaultRoot, '.hist')).existsSync(), isFalse,
        reason: 'and recorded nothing');
    expect(mac.shell.unsynced, 0);
    expect(mac.shell.moduleErrors.keys, ['history']);
    expect(mac.shell.moduleErrors['history'], contains('disk full'));
    expect(mac.shell.lastError, isNull,
        reason: 'the vault is degraded, not down');

    final daemon = Daemon(version: 't', shellFactory: h.daemonShell);
    daemon.vaults['mac'] =
        VaultEntry(profile: h.profileFor(mac), shell: mac.shell);
    final status = daemon.status().vaults.single;
    expect(status.state, SyncState.running);
    expect(status.degraded.keys, ['history']);
    expect(status.degraded['history'], contains('disk full'));
    expect(VaultStatus.fromJson(status.toJson()).degraded['history'],
        contains('disk full'),
        reason: 'carried over the wire');
    // The other module of the same vault, and the other device, are fine.
    expect(desk.shell.moduleErrors, isEmpty);
  });

  test(
      'the persisted profile is shaped per module, and nothing else loads '
      '(R8)', () async {
    final stateRoot = p.join(h.tmp.path, 'registry');
    final registry = VaultRegistry(stateRoot);
    final secrets = FileSecretStore(p.join(stateRoot, 'secrets'));
    await secrets.write('v', DaemonSecretStore.keyPassphrase, 'pass');
    await secrets.write('v', DaemonSecretStore.keyServerPassword, 'pw');

    registry.upsert(const VaultProfile(
      vaultId: 'v',
      vaultRoot: '/vaults/v',
      endpoint: 'https://hub.example',
      database: 'vault',
      serverUser: 'u',
      writerName: 'the-mac',
      exclusions: ['.DS_Store', 'drafts/'],
      histExtensions: ['.md', '.json'],
      histIdleMillis: 5000,
      watchDebounceMillis: 900,
      rescanSeconds: 60,
      inlineThresholdBytes: 4096,
    ));
    final entry = registry.entries().single;
    expect(entry['modules'], ['sync', 'history']);
    expect((entry['sync'] as Map)['endpoint'], 'https://hub.example');
    expect((entry['history'] as Map)['extensions'], ['.md', '.json']);
    expect((entry['folder'] as Map)['rescanSeconds'], 60);
    expect(entry.containsKey('endpoint'), isFalse, reason: 'nothing flat');

    final loaded = (await registry.loadProfiles(secrets)).single;
    expect(loaded.modules, VaultProfile.allModules);
    expect(loaded.endpoint, 'https://hub.example');
    expect(loaded.database, 'vault');
    expect(loaded.serverUser, 'u');
    expect(loaded.passphrase, 'pass');
    expect(loaded.serverPassword, 'pw');
    expect(loaded.writerName, 'the-mac');
    expect(loaded.exclusions, ['.DS_Store', 'drafts/']);
    expect(loaded.histExtensions, ['.md', '.json']);
    expect(loaded.histIdleMillis, 5000);
    expect(loaded.watchDebounceMillis, 900);
    expect(loaded.rescanSeconds, 60);
    expect(loaded.inlineThresholdBytes, 4096);
    expect(loaded.toRegistryJson(), entry, reason: 'the round trip is exact');

    // A connection arriving flat (a front-end's registration) over the served
    // profile changes the connection and keeps everything it omits.
    final registered = VaultProfile.fromRegistryJson(
      {...loaded.toConnectionJson(), 'endpoint': 'https://moved.example'},
      serverPassword: 'pw',
      passphrase: 'pass',
      keep: loaded,
    );
    expect(registered.endpoint, 'https://moved.example');
    expect(registered.writerName, 'the-mac');
    expect(registered.histIdleMillis, 5000);

    // A patch names blocks, never flat keys.
    expect(
      loaded.patched({
        'history': {'writerName': 'renamed'}
      }).writerName,
      'renamed',
    );

    // A history-only entry carries no connection block and reads no secret.
    registry.upsert(VaultProfile(
      vaultId: 'bare',
      vaultRoot: '/vaults/bare',
      modules: {VaultModule.history},
      histExtensions: const ['*'],
    ));
    final bareEntry =
        registry.entries().singleWhere((e) => e['vaultId'] == 'bare');
    expect(bareEntry['modules'], ['history']);
    expect(bareEntry.containsKey('sync'), isFalse);
    final bare = (await registry.loadProfiles(secrets))
        .singleWhere((e) => e.vaultId == 'bare');
    expect(bare.modules, {VaultModule.history});
    expect(bare.histExtensions, ['*']);
    expect(bare.endpoint, '');
    expect(bare.passphrase, '');

    // An entry in any other shape is refused, not guessed at.
    File(p.join(stateRoot, 'vaults.json')).writeAsStringSync(
      '[{"vaultId": "flat", "vaultRoot": "/vaults/flat", '
      '"endpoint": "https://hub.example"}]',
    );
    expect(() => registry.entries(), throwsA(isA<FormatException>()));
    expect(
        () => registry.loadProfiles(secrets), throwsA(isA<FormatException>()));
  });
}

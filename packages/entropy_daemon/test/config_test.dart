/// `vault_daemon` test-spec — "Changing a module's configuration"
/// (`daemon-modules` R9, R10): a setting changes without re-registering the
/// vault, without secrets, in place for history, and survives a restart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;
  late String stateRoot;
  late VaultRegistry registry;
  late FileSecretStore secrets;

  Daemon makeDaemon() => Daemon(
        version: 'test',
        shellFactory: h.daemonShell,
        registry: registry,
        secrets: secrets,
      );

  setUp(() async {
    h = await Harness.start();
    stateRoot = p.join(h.tmp.path, 'daemon-state');
    registry = VaultRegistry(stateRoot);
    secrets = FileSecretStore(p.join(stateRoot, 'secrets'));
  });
  tearDown(() => h.stop());

  test(
      'a history setting changes in place, without stopping replication, '
      'and survives a restart (R9, R10)', () async {
    final daemon = makeDaemon();
    final mac = h.handleFor('mac');
    final tuned = VaultProfile(
      vaultId: 'mac',
      vaultRoot: mac.vaultRoot,
      endpoint: h.endpoint,
      database: 'vault',
      serverUser: 'u',
      serverPassword: 'pw',
      passphrase: defaultPassphrase,
      writerName: 'the-mac',
      histIdleMillis: 0,
    );
    await secrets.write(
        'mac', DaemonSecretStore.keyPassphrase, defaultPassphrase);
    await secrets.write('mac', DaemonSecretStore.keyServerPassword, 'pw');
    registry.upsert(tuned);
    await daemon.addVault(tuned);
    mac.shell = daemon.vaults['mac']!.shell!;
    final desk = await h.spawn('desk');
    await h.settle([mac, desk]);
    final syncBefore = mac.shell.sync;
    final historyBefore = mac.shell.history;

    final server = ControlServer(daemon: daemon, token: 't');
    await server.start();
    final client = ControlClient(port: server.port, token: 't');
    try {
      final before = await client.vaultConfig('mac');
      expect(jsonEncode(before), isNot(contains(defaultPassphrase)));
      expect(jsonEncode(before), isNot(contains('pw')));
      expect((before['history'] as Map)['extensions'], ['.md']);

      // Only the extensions are named.
      final after = await client.updateVaultConfig('mac', {
        'history': {
          'extensions': ['.md', '.txt']
        }
      });
      expect((after['history'] as Map)['extensions'], ['.md', '.txt']);
      expect((after['history'] as Map)['writerName'], 'the-mac',
          reason: 'omitted means unchanged');
      expect((after['history'] as Map)['idleMillis'], 0);
      expect(jsonEncode(after), isNot(contains(defaultPassphrase)));

      expect(identical(mac.shell.sync, syncBefore), isTrue,
          reason: 'replication was never stopped');
      expect(identical(mac.shell.history, historyBefore), isFalse,
          reason: 'history was rebuilt in place');
      expect(daemon.vaults['mac']!.profile.histExtensions, ['.md', '.txt']);

      // The edit still replicates, and a .txt file now gains history.
      mac.write('notes/todo.txt', 'buy milk\n');
      await daemon.syncNow('mac');
      await h.settle([mac, desk]);
      expect(desk.file('notes/todo.txt').readAsStringSync(), 'buy milk\n');
      expect(mac.recordedVersions('notes/todo.txt'),
          contains(sha256OfText('buy milk\n')));

      // Persisted: a daemon restarted from the registry still tracks .txt.
      await daemon.stopAll();
      final restarted = makeDaemon();
      final reloaded = (await registry.loadProfiles(secrets))
          .singleWhere((e) => e.vaultId == 'mac');
      expect(reloaded.histExtensions, ['.md', '.txt']);
      expect(reloaded.writerName, 'the-mac');
      await restarted.addVault(reloaded);
      expect(restarted.vaults['mac']!.shell!.hist.extensions, ['.md', '.txt']);
      await restarted.stopAll();
    } finally {
      client.close();
      await server.stop();
    }
  });

  test('enabling and disabling history changes the module set alone (R9)',
      () async {
    final daemon = makeDaemon();
    final mac = h.handleFor('mac');
    final syncOnly = h.profileFor(mac, modules: {VaultModule.sync});
    registry.upsert(syncOnly);
    await daemon.addVault(syncOnly);
    mac.shell = daemon.vaults['mac']!.shell!;
    final desk = await h.spawn('desk');
    final syncBefore = mac.shell.sync;
    expect(mac.shell.history, isNull);

    await daemon.updateConfig('mac', {
      'modules': ['sync', 'history']
    });
    expect(mac.shell.history, isNotNull);
    expect(identical(mac.shell.sync, syncBefore), isTrue);
    expect(daemon.status().vaults.single.modules, ['sync', 'history']);
    mac.write('notes/a.md', 'recorded\n');
    await daemon.syncNow('mac');
    await h.settle([mac, desk]);
    expect(mac.recordedVersions('notes/a.md'),
        contains(sha256OfText('recorded\n')));
    expect(desk.file('notes/a.md').readAsStringSync(), 'recorded\n');

    await daemon.updateConfig('mac', {
      'modules': ['sync']
    });
    expect(mac.shell.history, isNull);
    expect(daemon.status().vaults.single.modules, ['sync']);
    mac.write('notes/a.md', 'not recorded\n');
    await daemon.syncNow('mac');
    await h.settle([mac, desk]);
    expect(desk.file('notes/a.md').readAsStringSync(), 'not recorded\n');
    expect(mac.recordedVersions('notes/a.md'),
        isNot(contains(sha256OfText('not recorded\n'))));
    expect(registry.entries().single['modules'], ['sync']);
    await daemon.stopAll();
  });

  test('enabling sync needs a connection, and an unknown vault is refused',
      () async {
    final daemon = makeDaemon();
    final bare = h.handleFor('bare');
    final profile = h.profileFor(bare, modules: {VaultModule.history});
    registry.upsert(profile);
    await daemon.addVault(profile);
    final before = registry.entries().single;

    await expectLater(
      daemon.updateConfig('bare', {
        'modules': ['sync', 'history']
      }),
      throwsA(isA<ConfigError>()
          .having((e) => e.message, 'message', contains('connection'))),
    );
    await expectLater(
      daemon.updateConfig('nobody', {
        'history': {'idleMillis': 1}
      }),
      throwsA(
          isA<ConfigError>().having((e) => e.unknownVault, 'unknown', true)),
    );
    expect(registry.entries().single, before, reason: 'nothing changed');
    expect(daemon.vaults['bare']!.profile.modules, {VaultModule.history});
    await daemon.stopAll();
  });

  test('the config verb reads and writes through the running daemon (RV10)',
      () async {
    final cliTmp = Directory.systemTemp.createTempSync('entropyd-config');
    addTearDown(() => cliTmp.deleteSync(recursive: true));
    final dill = p.join(cliTmp.path, 'entropy_daemon.dill');
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      p.join(Directory.current.path, 'bin', 'entropyd.dart'),
      '-o',
      dill,
    ]);
    expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
    Future<ProcessResult> cli(List<String> args) =>
        Process.run(Platform.resolvedExecutable, [dill, ...args]);

    final daemon = makeDaemon();
    final mac = h.handleFor('mac');
    registry.upsert(h.profileFor(mac));
    await daemon.addVault(h.profileFor(mac));
    mac.shell = daemon.vaults['mac']!.shell!;
    final server = ControlServer(daemon: daemon, token: 'cli-token');
    await server.start();
    ControlDiscovery(stateRoot).write(port: server.port, token: 'cli-token');
    try {
      final shown = await cli(['config', 'mac', '--state-root', stateRoot]);
      expect(shown.exitCode, 0, reason: '${shown.stderr}');
      final config = jsonDecode(shown.stdout as String) as Map<String, Object?>;
      expect((config['history'] as Map)['extensions'], ['.md']);
      expect(shown.stdout, isNot(contains(defaultPassphrase)));

      final changed = await cli([
        'config',
        'mac',
        '--history-extensions',
        '.md,.json',
        '--state-root',
        stateRoot,
      ]);
      expect(changed.exitCode, 0, reason: '${changed.stderr}');
      expect(changed.stdout, contains('applied through the running daemon'));
      expect(mac.shell.hist.extensions, ['.md', '.json'],
          reason: 'took effect without a restart');

      final again = await cli(['config', 'mac', '--state-root', stateRoot]);
      final now = jsonDecode(again.stdout as String) as Map<String, Object?>;
      expect((now['history'] as Map)['extensions'], ['.md', '.json']);
    } finally {
      await daemon.stopAll();
      await server.stop();
    }
  });
}

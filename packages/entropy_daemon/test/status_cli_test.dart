/// `vault_daemon` test-spec — "Status and CLI (R17, RV10)".
///
/// The un-synced-count case exercises the daemon's status API directly; the
/// CLI verbs (`init`, `status`, `inspect`, `hist`) are exercised as true
/// processes against a temp state root — compiled once to a kernel snapshot so
/// each spawn is fast.
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Directory cliTmp;
  late String dill;

  setUpAll(() async {
    cliTmp = Directory.systemTemp.createTempSync('entropyd-cli');
    dill = p.join(cliTmp.path, 'entropy_daemon.dill');
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      p.join(Directory.current.path, 'bin', 'entropyd.dart'),
      '-o',
      dill,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });

  tearDownAll(() {
    if (cliTmp.existsSync()) cliTmp.deleteSync(recursive: true);
  });

  Future<ProcessResult> cli(List<String> args) =>
      Process.run(Platform.resolvedExecutable, [dill, ...args]);

  late Harness h;
  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  /// Register a vault for the CLI process under [stateRoot]: the non-secret
  /// registry entry plus the file-fallback secrets, exactly the layout
  /// `productionSecretStore` reads.
  Future<void> registerForCli(String stateRoot, VaultHandle handle) async {
    VaultRegistry(stateRoot).upsert(h.profileFor(handle));
    final secrets = FileSecretStore(p.join(stateRoot, 'secrets'));
    await secrets.write(handle.name, DaemonSecretStore.keyServerPassword, 'pw');
    await secrets.write(
        handle.name, DaemonSecretStore.keyPassphrase, defaultPassphrase);
  }

  test('status reports the real count of un-synced local changes (R17)',
      () async {
    final daemon = Daemon(version: 'test', shellFactory: h.daemonShell);
    final mac = h.handleFor('mac');
    mac.write('start.md', 'initial\n');
    await daemon.addVault(h.profileFor(mac));
    final t1 = daemon.status().vaults.single.lastSyncMillis;
    expect(t1, isNotNull);

    // The server becomes unreachable; three files are written and the
    // daemon settles locally.
    await h.emulator.stop();
    mac.write('one.md', '1\n');
    mac.write('two.md', '2\n');
    mac.write('three.md', '3\n');
    await daemon.syncNow();

    var status = daemon.status().vaults.single;
    expect(status.state, SyncState.offline);
    expect(status.unsynced, 3,
        reason: 'the actual pending local changes, not a placeholder');
    expect(status.lastSyncMillis, t1);

    // Connectivity restored: the count returns to 0 and last-sync updates.
    await h.emulator.start();
    await daemon.syncNow();
    status = daemon.status().vaults.single;
    expect(status.state, SyncState.running);
    expect(status.unsynced, 0);
    expect(status.error, isNull);
    expect(status.lastSyncMillis, greaterThanOrEqualTo(t1!));
  });

  test('`status` is a one-shot control-channel client (R17, RV10)', () async {
    final daemon = Daemon(version: 'test', shellFactory: h.daemonShell);
    final mac = h.handleFor('mac');
    mac.write('note.md', 'hi\n');
    await daemon.addVault(h.profileFor(mac));
    final server = ControlServer(daemon: daemon, token: 'cli-token');
    await server.start();
    final stateRoot = p.join(h.tmp.path, 'cli-state');
    ControlDiscovery(stateRoot).write(port: server.port, token: 'cli-token');

    try {
      // It authenticates with the token, prints per-vault status, and exits.
      final ok = await cli(['status', '--state-root', stateRoot]);
      expect(ok.exitCode, 0, reason: '${ok.stderr}');
      expect(ok.stdout, contains('entropyd test'));
      expect(ok.stdout, contains('mac: running'));
      expect(ok.stdout, contains('un-synced 0'));

      // The daemon keeps running.
      final still = ControlClient(port: server.port, token: 'cli-token');
      expect((await still.status()).vaults.single.vaultId, 'mac');
      still.close();

      // With no daemon running it reports that clearly instead of hanging.
      ControlDiscovery(stateRoot).clear();
      final none = await cli(['status', '--state-root', stateRoot]);
      expect(none.exitCode, 1);
      expect(none.stderr, contains('no running daemon'));
    } finally {
      await server.stop();
    }
  });

  test('`status` reports a stale discovery file cleanly (RV10)', () async {
    // A daemon died uncleanly and left its advertisement behind: the port
    // answers nothing.
    final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = sock.port;
    await sock.close();
    final stateRoot = p.join(h.tmp.path, 'stale-state');
    ControlDiscovery(stateRoot).write(port: deadPort, token: 'dead-token');

    final res = await cli(['status', '--state-root', stateRoot]);
    expect(res.exitCode, 1, reason: '${res.stdout}\n${res.stderr}');
    expect(res.stderr, contains('not reachable'));
    expect(res.stderr, isNot(contains('Unhandled exception')));
    expect(res.stderr, isNot(contains('SocketException')));
  });

  test(
      '`init` hands off to a running daemon over the control channel '
      'instead of opening its live replica (RV10)', () async {
    final daemonStateRoot = p.join(h.tmp.path, 'daemon-state');
    final daemon = Daemon(
      version: 'test',
      shellFactory: h.daemonShell,
      registry: VaultRegistry(daemonStateRoot),
      secrets: FileSecretStore(p.join(daemonStateRoot, 'secrets')),
    );
    final server = ControlServer(daemon: daemon, token: 'cli-token');
    await server.start();
    final stateRoot = p.join(h.tmp.path, 'cli-state');
    ControlDiscovery(stateRoot).write(port: server.port, token: 'cli-token');

    try {
      final v = h.handleFor('handoff');
      v.write('a.md', 'hello handoff\n');
      final res = await cli([
        'init',
        '--vault',
        v.vaultRoot,
        '--vault-id',
        'handoff',
        '--endpoint',
        h.endpoint,
        '--database',
        'vault',
        '--server-user',
        'u',
        '--server-password',
        'pw',
        '--passphrase',
        defaultPassphrase,
        '--state-root',
        stateRoot,
      ]);
      expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
      expect(res.stdout, contains('registered with the running daemon'));

      // The running daemon now serves the vault…
      expect(daemon.vaults.containsKey('handoff'), isTrue);
      expect(daemon.vaults['handoff']!.shell, isNotNull);
      expect(await h.decryptServerText(v, 'a.md'), 'hello handoff\n');
      // …and the CLI process never opened a second LocalStore of its own
      // over any replica under its state root.
      expect(
        Directory(p.join(stateRoot, 'data', 'handoff')).existsSync(),
        isFalse,
      );
    } finally {
      await daemon.stopAll();
      await server.stop();
    }
  });

  test('`init` falls back to the direct path when the advertisement is stale',
      () async {
    final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = sock.port;
    await sock.close();
    final stateRoot = p.join(h.tmp.path, 'stale-init-state');
    ControlDiscovery(stateRoot).write(port: deadPort, token: 'dead-token');

    final v = h.handleFor('direct');
    v.write('a.md', 'direct init\n');
    final res = await cli([
      'init',
      '--vault',
      v.vaultRoot,
      '--vault-id',
      'direct',
      '--endpoint',
      h.endpoint,
      '--database',
      'vault',
      '--server-user',
      'u',
      '--server-password',
      'pw',
      '--passphrase',
      defaultPassphrase,
      '--state-root',
      stateRoot,
    ]);
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    expect(res.stdout, contains('initialized'));
    // The direct path ran: the vault synced and the replica lives under the
    // CLI's state root.
    expect(
      Directory(p.join(stateRoot, 'data', 'direct')).existsSync(),
      isTrue,
    );
  });

  test('`inspect` decrypts the database client-side for the owner (RV2)',
      () async {
    final mac = h.handleFor('spec-cli-inspect');
    mac.write('notes/a.md', 'hello');
    await h.spawn('spec-cli-inspect');
    await mac.shell.reconcile(); // synced

    // The fake server holds only wire documents — the bytes alone reveal
    // nothing.
    expect(h.serverRawJson(), isNot(contains('hello')));

    final stateRoot = p.join(h.tmp.path, 'cli-root');
    await registerForCli(stateRoot, mac);
    final result =
        await cli(['inspect', 'notes/a.md', '--state-root', stateRoot]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    // The owner sees the decrypted logical document: path, metadata, content.
    expect(result.stdout, contains('# notes/a.md'));
    expect(result.stdout, contains('mtime'));
    expect(result.stdout, contains('hello'));
  });

  test('`hist` runs the history command line over a served vault (RV10)',
      () async {
    final mac = h.handleFor('spec-cli-history');
    await h.spawn('spec-cli-history');
    await mac.shell.reconcile();
    for (final content in ['one\n', 'two\n', 'three\n']) {
      mac.write('notes/a.md', content);
      await mac.shell.reconcile();
    }
    final stateRoot = p.join(h.tmp.path, 'cli-root');
    await registerForCli(stateRoot, mac);

    // Log: the file's versions, the live one marked — no --folder given; the
    // vault's profile supplied the folder.
    final log =
        await cli(['hist', 'log', 'notes/a.md', '--state-root', stateRoot]);
    expect(log.exitCode, 0, reason: '${log.stderr}');
    expect(log.stdout, startsWith('notes/a.md\n'));
    for (final content in ['one\n', 'two\n', 'three\n']) {
      expect(log.stdout, contains(sha256OfText(content).substring(0, 12)));
    }
    expect(
        log.stdout, contains('${sha256OfText('three\n').substring(0, 12)}  '));
    expect(log.stdout, contains('  live\n'));

    // Show: the chosen version's content, byte for byte.
    final show = await cli([
      'hist',
      'show',
      'notes/a.md',
      sha256OfText('two\n').substring(0, 10),
      '--state-root',
      stateRoot,
    ]);
    expect(show.exitCode, 0, reason: '${show.stderr}');
    expect(show.stdout, 'two\n');

    // Diff: the last edit as a unified diff.
    final diff =
        await cli(['hist', 'diff', 'notes/a.md', '--state-root', stateRoot]);
    expect(diff.exitCode, 0, reason: '${diff.stderr}');
    expect(diff.stdout, contains('-two\n+three\n'));

    // Restore: the chosen version becomes the live file.
    final restore = await cli([
      'hist',
      'restore',
      'notes/a.md',
      sha256OfText('two\n'),
      '--state-root',
      stateRoot,
    ]);
    expect(restore.exitCode, 0, reason: '${restore.stderr}');
    expect(restore.stdout, contains('restored'));
    expect(mac.file('notes/a.md').readAsStringSync(), 'two\n');

    // …and the restored content syncs (the daemon ingests it as an edit).
    await mac.shell.reconcile();
    expect(await h.decryptServerText(mac, 'notes/a.md'), 'two\n');
  });

  test(
      '`setup-uri` emits a pasteable connection string, never the passphrase '
      '(RV10, D9)', () async {
    final mac = await h.spawn('setup-uri-mac');
    final stateRoot = p.join(cliTmp.path, 'setup-uri-root');
    await registerForCli(stateRoot, mac);

    final result = await cli(['setup-uri', '--state-root', stateRoot]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final out = result.stdout as String;

    // One pasteable string: the secret rides inside it (D9).
    final uriMatch =
        RegExp(r'entropy-sync://setup#([A-Za-z0-9_=-]+)~([a-z2-9-]+)')
            .firstMatch(out);
    expect(uriMatch, isNotNull, reason: out);
    final secretMatch = RegExp(r'~([a-z2-9-]+)').firstMatch(out);
    expect(secretMatch, isNotNull, reason: out);
    expect(out, isNot(contains(defaultPassphrase)),
        reason: 'the E2EE passphrase must never appear in the output');

    // The front-ends' decoder recovers exactly the registered connection.
    final blob = utf8.decode(base64Url.decode(uriMatch!.group(1)!));
    final cipher = await TransferCipher.derive(secretMatch!.group(1)!);
    final payload =
        jsonDecode(await cipher.decryptText(blob)) as Map<String, Object?>;
    final expected = h.profileFor(mac);
    expect(payload['endpoint'], expected.endpoint);
    expect(payload['database'], expected.database);
    expect(payload['serverUser'], expected.serverUser);
    expect(payload['serverPassword'], 'pw');

    // A wrong transfer secret is rejected, not garbage.
    final wrong = await TransferCipher.derive('wrong-secret');
    await expectLater(
        wrong.decryptText(blob), throwsA(isA<TransferCipherException>()));

    // An explicit --transfer-secret is used verbatim.
    final explicit = await cli([
      'setup-uri',
      '--state-root',
      stateRoot,
      '--transfer-secret',
      'my-explicit-secret',
    ]);
    expect(explicit.exitCode, 0, reason: '${explicit.stderr}');
    final out2 = explicit.stdout as String;
    expect(out2, contains('~my-explicit-secret'));
    final blob2 = utf8.decode(base64Url.decode(
        RegExp(r'entropy-sync://setup#([A-Za-z0-9_=-]+)~')
            .firstMatch(out2)!
            .group(1)!));
    final cipher2 = await TransferCipher.derive('my-explicit-secret');
    final payload2 =
        jsonDecode(await cipher2.decryptText(blob2)) as Map<String, Object?>;
    expect(payload2['database'], expected.database);

    // --split keeps the two-channel form: a bare URI plus the secret apart.
    final split = await cli([
      'setup-uri',
      '--state-root',
      stateRoot,
      '--transfer-secret',
      'my-explicit-secret',
      '--split',
    ]);
    expect(split.exitCode, 0, reason: '${split.stderr}');
    final out3 = split.stdout as String;
    expect(out3, contains('Transfer secret: my-explicit-secret'));
    expect(out3, isNot(contains('~my-explicit-secret')));
  });

  test(
      '`setup-uri` encodes an explicit connection with no vault registered '
      '(RV10)', () async {
    // A freshly provisioned server: a state root with nothing registered.
    final stateRoot = p.join(cliTmp.path, 'empty-root');
    Directory(stateRoot).createSync(recursive: true);

    final result = await cli([
      'setup-uri',
      '--state-root',
      stateRoot,
      '--endpoint',
      'https://sync.example.com',
      '--database',
      'vault',
      '--server-user',
      'entropy',
      '--server-password',
      's3cret-pw',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final out = result.stdout as String;

    final match = RegExp(r'entropy-sync://setup#([A-Za-z0-9_=-]+)~([a-z2-9-]+)')
        .firstMatch(out);
    expect(match, isNotNull, reason: out);

    final cipher = await TransferCipher.derive(match!.group(2)!);
    final payload = jsonDecode(
      await cipher.decryptText(utf8.decode(base64Url.decode(match.group(1)!))),
    ) as Map<String, Object?>;
    expect(payload['endpoint'], 'https://sync.example.com');
    expect(payload['database'], 'vault');
    expect(payload['serverUser'], 'entropy');
    expect(payload['serverPassword'], 's3cret-pw');

    // Nothing was registered or stored on the way.
    expect(VaultRegistry(stateRoot).entries(), isEmpty);
    expect(Directory(p.join(stateRoot, 'secrets')).existsSync(), isFalse);

    // A half-given connection is a clear usage error, not a silent fallback.
    final partial = await cli([
      'setup-uri',
      '--state-root',
      stateRoot,
      '--endpoint',
      'https://sync.example.com',
      '--database',
      'vault',
    ]);
    expect(partial.exitCode, 64);
    expect(
      partial.stderr as String,
      allOf(contains('--server-user'), contains('--server-password')),
    );
  });

  test(
      '`init` refuses a shared database without the flag and accepts it with '
      'one (RV10, R23)', () async {
    final stateRoot = p.join(cliTmp.path, 'shared-db-${h.endpoint.hashCode}');
    final first = h.handleFor('first');
    await registerForCli(stateRoot, first); // already on database `vault`

    // A second vault at its own, non-overlapping folder, aimed at the same
    // endpoint and database. No daemon is advertised, so this is the direct
    // path — the CLI's own registry check.
    final second = h.handleFor('second');
    List<String> initArgs({required bool acknowledge}) => [
          'init',
          '--state-root',
          stateRoot,
          '--vault',
          second.vaultRoot,
          '--vault-id',
          'second',
          '--endpoint',
          h.endpoint,
          '--database',
          'vault',
          '--server-user',
          'u',
          '--server-password',
          'pw',
          '--passphrase',
          defaultPassphrase,
          if (acknowledge) '--allow-shared-database',
        ];

    // Without the flag: refused, naming the vault already using it, and
    // nothing is registered.
    final refused = await cli(initArgs(acknowledge: false));
    expect(refused.exitCode, 1);
    expect(
      refused.stderr as String,
      allOf(contains('first'), contains('--allow-shared-database')),
    );
    expect(
      VaultRegistry(stateRoot).entries().map((e) => e['vaultId']),
      ['first'],
    );

    // With the flag: registered alongside the first.
    final accepted = await cli(initArgs(acknowledge: true));
    expect(accepted.exitCode, 0, reason: '${accepted.stderr}');
    expect(
      VaultRegistry(stateRoot).entries().map((e) => e['vaultId']),
      unorderedEquals(['first', 'second']),
    );
  });
}

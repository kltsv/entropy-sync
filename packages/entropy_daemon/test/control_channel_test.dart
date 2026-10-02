/// `vault_daemon` test-spec — "Control channel (R18, R19, R20)".
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  const token = 'spec-shared-token-0451';
  const marker = 'plain::text::marker::42';

  late Harness h;
  late Daemon daemon;
  late ControlServer server;
  late VaultRegistry registry;
  late FileSecretStore secrets;
  late String daemonStateRoot;
  late VaultHandle v1;

  setUp(() async {
    h = await Harness.start();
    daemonStateRoot = p.join(h.tmp.path, 'daemon-state');
    registry = VaultRegistry(daemonStateRoot);
    secrets = FileSecretStore(p.join(daemonStateRoot, 'secrets'));
    daemon = Daemon(
      version: 'test',
      shellFactory: h.daemonShell,
      registry: registry,
      secrets: secrets,
    );
    v1 = h.handleFor('v1');
    v1.write('note.md', 'the vault content $marker\n');
    await daemon.addVault(h.profileFor(v1, database: 'db-one'));
    server = ControlServer(daemon: daemon, token: token);
    await server.start();
  });

  tearDown(() async {
    await daemon.stopAll();
    await server.stop();
    await h.stop();
  });

  ControlClient client([String presented = token]) =>
      ControlClient(port: server.port, token: presented);

  test(
      'a front-end presenting the token reads status and issues commands '
      '(R18)', () async {
    final c = client();
    final status = await c.status();
    expect(status.version, 'test');
    final vs = status.vaults.single;
    expect(vs.vaultId, 'v1');
    expect(vs.state, SyncState.running);
    expect(vs.unsynced, 0);
    expect(vs.lastSyncMillis, isNotNull);
    expect(vs.error, isNull);
    expect(vs.conflicts, isEmpty);

    final after = await c.command(ControlCommand.pause, vaultId: 'v1');
    expect(after.vaults.single.state, SyncState.paused);
    expect(daemon.vaults['v1']!.shell!.paused, isTrue);
    c.close();
  });

  test('an unauthenticated caller is refused (R19)', () async {
    // A wrong token…
    final bad = client('not-the-token');
    await expectLater(bad.status(), throwsA(isA<StateError>()));
    await expectLater(bad.command(ControlCommand.pause, vaultId: 'v1'),
        throwsA(isA<StateError>()));
    bad.close();
    // …and no token at all: neither status nor commands.
    final raw =
        await http.get(Uri.parse('http://127.0.0.1:${server.port}/status'));
    expect(raw.statusCode, 403);
    // The refused pause did not take effect.
    expect(daemon.vaults['v1']!.shell!.paused, isFalse);
  });

  test('two controllers see the same authoritative state (R20)', () async {
    final c1 = client();
    final c2 = client();
    await c1.command(ControlCommand.pause, vaultId: 'v1');
    final seenByC2 = await c2.status();
    expect(seenByC2.vaults.single.state, SyncState.paused,
        reason: 'a control action from one controller is reflected to the '
            'other — the daemon is the single source of truth');
    await c2.command(ControlCommand.resume, vaultId: 'v1');
    expect((await c1.status()).vaults.single.state, SyncState.running);
    c1.close();
    c2.close();
  });

  test(
      'add-vault over the channel registers and serves without a restart '
      '(D10, R23)', () async {
    final c = client();
    final v2 = h.handleFor('v2');
    final request = AddVaultRequest(
      profile: h.profileFor(v2, database: 'db-two').toRegistryJson(),
      passphrase: defaultPassphrase,
      serverPassword: 'pw',
    );
    final status = await c.addVault(request);
    expect(status.vaults.map((v) => v.vaultId).toSet(), {'v1', 'v2'});

    // The secrets landed in the daemon's secret store…
    expect(await secrets.read('v2', DaemonSecretStore.keyPassphrase),
        defaultPassphrase);
    expect(await secrets.read('v2', DaemonSecretStore.keyServerPassword), 'pw');
    // …the non-secret registry entry was persisted…
    expect(registry.entries().where((e) => e['vaultId'] == 'v2'), hasLength(1));
    // …and the vault serves immediately — no daemon restart: an edit syncs.
    v2.write('fresh.md', 'served without restart\n');
    await c.command(ControlCommand.syncNow, vaultId: 'v2');
    expect(await h.decryptServerText(v2, 'fresh.md', database: 'db-two'),
        'served without restart\n');

    // Re-sending the same profile is the idempotent attach — no duplicate
    // registration, no error.
    await c.addVault(request);
    expect(daemon.vaults.keys.toSet(), {'v1', 'v2'});
    expect(registry.entries().where((e) => e['vaultId'] == 'v2'), hasLength(1));

    // An edit-vault command updates V2's profile in place — shaped per
    // module, like the registry.
    final editedJson = h.profileFor(v2, database: 'db-two').toRegistryJson();
    (editedJson['history'] as Map)['writerName'] = 'renamed-writer';
    await c.addVault(AddVaultRequest(
      profile: editedJson,
      passphrase: defaultPassphrase,
      serverPassword: 'pw',
    ));
    expect(daemon.vaults['v2']!.profile.writerName, 'renamed-writer');
    // Persisted per module (`daemon-modules` R8): the writer name lives in
    // the history block.
    final persisted =
        registry.entries().singleWhere((e) => e['vaultId'] == 'v2');
    expect((persisted['history'] as Map)['writerName'], 'renamed-writer');

    // A vault whose target collides with an already-served one gets a 409;
    // nothing is stored for it.
    final v3 = h.handleFor('v3');
    await expectLater(
      c.addVault(AddVaultRequest(
        profile: h.profileFor(v3, database: 'db-one').toRegistryJson(),
        passphrase: defaultPassphrase,
        serverPassword: 'pw',
      )),
      throwsA(isA<ControlVaultConflict>()
          .having((e) => e.conflictsWith, 'conflictsWith', 'v1')),
    );
    expect(daemon.vaults.containsKey('v3'), isFalse);
    expect(await secrets.read('v3', DaemonSecretStore.keyPassphrase), isNull);
    expect(registry.entries().where((e) => e['vaultId'] == 'v3'), isEmpty);
    c.close();
  });

  test('the control channel carries no vault plaintext (C3)', () async {
    // The vault content (with its marker) is synced and even conflict-free
    // status mentions the vault; capture everything the channel returns.
    final headers = {
      'x-entropy-token': token,
      'content-type': 'application/json'
    };
    final captured = <String>[];
    final statusResp = await http.get(
        Uri.parse('http://127.0.0.1:${server.port}/status'),
        headers: headers);
    captured.add(statusResp.body);
    final controlResp = await http.post(
      Uri.parse('http://127.0.0.1:${server.port}/control'),
      headers: headers,
      body: jsonEncode({'command': 'syncNow', 'vaultId': 'v1'}),
    );
    captured.add(controlResp.body);

    for (final body in captured) {
      // Control/status fields only — never document bodies or the
      // passphrase; E2EE is not weakened by the channel.
      expect(body, isNot(contains(marker)));
      expect(body, isNot(contains(defaultPassphrase)));
      final decoded = jsonDecode(body) as Map<String, Object?>;
      expect(decoded.keys.toSet(), {'version', 'vaults'});
    }
  });

  test(
      'a second start attaches to the running daemon rather than '
      'duplicating it (R20, R21)', () async {
    // The running daemon advertises its endpoint.
    ControlDiscovery(daemonStateRoot).write(port: server.port, token: token);
    final before = await client().status();
    final shellBefore = daemon.vaults['v1']!.shell;

    // "Start/bootstrap again": discovery finds the live endpoint, the second
    // front-end attaches, and re-adding the vault is the idempotent attach.
    final discovered = ControlDiscovery(daemonStateRoot).read();
    expect(discovered, isNotNull);
    expect(discovered!.port, server.port);
    final attached =
        ControlClient(port: discovered.port, token: discovered.token);
    final after = await attached.status();
    expect(after.version, before.version);
    expect(after.vaults.single.vaultId, 'v1');

    await daemon.addVault(h.profileFor(v1, database: 'db-one'));
    expect(daemon.vaults.keys, ['v1'], reason: 'no second instance');
    expect(identical(daemon.vaults['v1']!.shell, shellBefore), isTrue,
        reason: 'the existing instance is attached to, not replaced');
    attached.close();
  });

  test('the daemon keeps syncing with no controller attached (R18)', () async {
    // Attach, then detach every controller.
    final c = client();
    await c.status();
    c.close();

    // A change on disk still syncs — the daemon runs independently of any
    // front-end.
    v1.write('headless.md', 'no controller attached\n');
    await daemon.syncNow();
    expect(await h.decryptServerText(v1, 'headless.md', database: 'db-one'),
        'no controller attached\n');
  });
}

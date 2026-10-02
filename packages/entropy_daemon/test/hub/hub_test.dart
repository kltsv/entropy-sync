/// `vault_sync_hub` test-spec.
///
/// Two seams stand in for a VPS. [_RecordingRunner] captures every command the
/// service would run over SSH — that is what proves administration never
/// leaves the hub's loopback (C2) and that an unreachable hub changes nothing
/// (C1). [_FakeCouchAdmin] models CouchDB's **administrative** semantics
/// (databases, `_users` documents with revisions, `_security` members) so the
/// grant logic is exercised end to end; it deliberately models only that
/// surface, not the replication protocol the Couch emulator already covers.
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _RecordingRunner implements HubRunner {
  bool reachableHost = true;
  final List<String> commands = [];
  final Map<String, String> written = {};

  /// Canned replies, matched by substring of the command.
  final List<({String match, HubCommandResult result})> replies = [];

  void reply(String match, {int exitCode = 0, String stdout = ''}) =>
      replies.add((
        match: match,
        result: HubCommandResult(
          exitCode: exitCode,
          stdout: stdout,
          stderr: '',
        ),
      ));

  @override
  Future<bool> reachable(String sshTarget) async => reachableHost;

  @override
  Future<HubCommandResult> run(
    String sshTarget,
    String command, {
    String? stdin,
  }) async {
    commands.add(command);
    for (final r in replies) {
      if (command.contains(r.match)) return r.result;
    }
    return const HubCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> writeFile(
    String sshTarget,
    String remotePath,
    String content,
  ) async =>
      written[remotePath] = content;
}

/// A model of CouchDB's administrative surface, enough for the hub's grants.
class _FakeCouchAdmin implements CouchAdmin {
  final Set<String> databases = {};
  final Map<String, Map<String, Object?>> users = {};
  final Map<String, Map<String, Object?>> security = {};

  AdminResponse _ok(Object? body) =>
      AdminResponse(statusCode: 200, body: jsonEncode(body));

  @override
  Future<AdminResponse> send(String method, String path, {Object? body}) async {
    final noQuery = path.split('?').first;
    final parts = noQuery.split('/');

    if (noQuery == '_all_dbs') {
      return _ok([...databases, '_users', '_replicator']);
    }

    // _users/org.couchdb.user:<name>
    if (parts.length == 2 && parts[0] == '_users') {
      final name = parts[1].replaceFirst('org.couchdb.user:', '');
      switch (method) {
        case 'PUT':
          final doc = (body! as Map).cast<String, Object?>();
          users[name] = {...doc, '_rev': '1-${users.length + 1}'};
          return AdminResponse(statusCode: 201, body: '{"ok":true}');
        case 'GET':
          final doc = users[name];
          return doc == null
              ? AdminResponse(statusCode: 404, body: '{"error":"not_found"}')
              : _ok(doc);
        case 'DELETE':
          users.remove(name);
          return _ok({'ok': true});
      }
    }

    // <db>/_security
    if (parts.length == 2 && parts[1] == '_security') {
      final db = parts[0];
      if (method == 'PUT') {
        security[db] = (body! as Map).cast<String, Object?>();
        return _ok({'ok': true});
      }
      return _ok(security[db] ??
          {
            'admins': {'names': [], 'roles': []},
            'members': {'names': [], 'roles': []},
          });
    }

    // <db>
    if (parts.length == 1) {
      final db = parts[0];
      switch (method) {
        case 'PUT':
          if (!databases.add(db)) {
            return AdminResponse(statusCode: 412, body: '{"error":"exists"}');
          }
          return AdminResponse(statusCode: 201, body: '{"ok":true}');
        case 'DELETE':
          final had = databases.remove(db);
          security.remove(db);
          return had
              ? _ok({'ok': true})
              : AdminResponse(statusCode: 404, body: '{"error":"not_found"}');
        case 'GET':
          return databases.contains(db)
              ? _ok({'db_name': db})
              : AdminResponse(statusCode: 404, body: '{"error":"not_found"}');
      }
    }
    return AdminResponse(statusCode: 400, body: '{"error":"unhandled"}');
  }

  List<String> membersOf(String db) =>
      ((security[db]?['members'] as Map?)?['names'] as List?)
          ?.cast<String>()
          .toList() ??
      const [];
}

void main() {
  late Directory tmp;
  late HubRegistry registry;
  late _RecordingRunner runner;
  late _FakeCouchAdmin admin;
  late HubService hub;

  const record = HubRecord(
    label: 'home',
    sshTarget: 'root@203.0.113.10',
    domain: 'sync.example.com',
    acmeEmail: 'owner@example.com',
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hub_');
    registry = HubRegistry(tmp.path);
    runner = _RecordingRunner();
    admin = _FakeCouchAdmin();
    hub = HubService(
      registry: registry,
      runner: runner,
      adminFactory: (_) => admin,
    );
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('the hub record holds no credentials (C1)', () {
    test('a hub is label, target, domain and email — nothing secret', () {
      registry.upsert(record);

      final back = registry.find('home')!;
      expect(back.sshTarget, 'root@203.0.113.10');
      expect(back.domain, 'sync.example.com');
      expect(back.acmeEmail, 'owner@example.com');
      expect(back.endpoint, 'https://sync.example.com');

      // Nothing secret-shaped is persisted at all.
      final raw = File(p.join(tmp.path, 'hubs.json')).readAsStringSync();
      for (final forbidden in [
        'password',
        'privateKey',
        'passphrase',
        'BEGIN OPENSSH',
      ]) {
        expect(raw, isNot(contains(forbidden)), reason: 'leaked $forbidden');
      }

      // Adding the same label again edits that hub, not a second one.
      registry.upsert(const HubRecord(
        label: 'home',
        sshTarget: 'root@198.51.100.7',
        domain: 'sync.example.com',
        acmeEmail: 'owner@example.com',
      ));
      expect(registry.all(), hasLength(1));
      expect(registry.find('home')!.sshTarget, 'root@198.51.100.7');
    });

    test('an unreachable hub reports its target and runs nothing', () async {
      runner.reachableHost = false;

      await expectLater(
        hub.provision(record),
        throwsA(isA<HubUnreachable>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('root@203.0.113.10'), contains('SSH agent')),
        )),
      );
      await expectLater(
        hub.listDatabases(record),
        throwsA(isA<HubUnreachable>()),
      );

      // Nothing was attempted on the host and nothing was stored.
      expect(runner.commands, isEmpty);
      expect(runner.written, isEmpty);
      expect(registry.all(), isEmpty);
    });
  });

  group('administration never crosses the public internet (C2)', () {
    test('every admin call targets the loopback, never the domain', () async {
      // The real transport, over the recording runner.
      final overSsh = HubService(
        registry: registry,
        runner: runner,
        adminFactory: (h) =>
            SshCouchAdmin(runner: runner, sshTarget: h.sshTarget),
      );
      runner.reply('_all_dbs', stdout: '200\n["vault","_users"]');

      await overSsh.listDatabases(record);

      expect(runner.commands, isNotEmpty);
      for (final command in runner.commands) {
        expect(command, contains('127.0.0.1:5984'));
        expect(
          command,
          isNot(contains('sync.example.com')),
          reason: 'admin traffic must not use the public endpoint',
        );
      }
    });

    test('the admin password is read from the hub, never stored here',
        () async {
      final overSsh = HubService(
        registry: registry,
        runner: runner,
        adminFactory: (h) =>
            SshCouchAdmin(runner: runner, sshTarget: h.sshTarget),
      );
      runner.reply('_all_dbs', stdout: '200\n[]');
      registry.upsert(record);

      await overSsh.listDatabases(record);

      // The credentials are resolved by the *remote* shell out of the hub's
      // own env file, and interpolated there.
      final command = runner.commands.single;
      expect(command, contains('/opt/entropy-sync/.env'));
      expect(command, contains(r'-u "$U:$P"'));

      // …so nothing locally holds them.
      final raw = File(p.join(tmp.path, 'hubs.json')).readAsStringSync();
      expect(raw, isNot(contains('COUCHDB_PASSWORD')));
      expect(raw.toLowerCase(), isNot(contains('admin')));
    });
  });

  group('provisioning (R1)', () {
    test('DNS not pointing here is reported and nothing is changed', () async {
      runner
        ..reply('getent hosts', stdout: '198.51.100.7\n')
        ..reply('ipify', stdout: '203.0.113.10\n');

      await expectLater(
        hub.provision(record),
        throwsA(isA<HubRefused>().having(
          (e) => e.toString(),
          'message',
          allOf(
            contains('sync.example.com'),
            contains('198.51.100.7'),
            contains('203.0.113.10'),
          ),
        )),
      );
      expect(runner.written, isEmpty); // the recipe never reached the host
      expect(registry.all(), isEmpty);
    });

    test('a domain that resolves nowhere is reported as such', () async {
      runner
        ..reply('getent hosts', stdout: '')
        ..reply('ipify', stdout: '203.0.113.10\n');

      await expectLater(
        hub.provision(record),
        throwsA(isA<HubRefused>().having(
            (e) => e.toString(), 'message', contains('does not resolve yet'))),
      );
      expect(runner.written, isEmpty);
    });

    test('a port already in use is reported before anything is changed',
        () async {
      runner
        ..reply('getent hosts', stdout: '203.0.113.10\n')
        ..reply('ipify', stdout: '203.0.113.10\n')
        ..reply('ss -tlnp', stdout: 'LISTEN 0 4096 0.0.0.0:443 users:(("nginx"')
        ..reply('docker-compose.yml', stdout: 'no\n');

      await expectLater(
        hub.provision(record),
        throwsA(isA<HubRefused>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('already in use'), contains('nginx')),
        )),
      );
      expect(runner.written, isEmpty);
    });

    test('an already-provisioned host is attached to, not refused', () async {
      runner
        ..reply('getent hosts', stdout: '203.0.113.10\n')
        ..reply('ipify', stdout: '203.0.113.10\n')
        // Our own stack is holding the ports…
        ..reply('ss -tlnp', stdout: 'LISTEN 0 4096 0.0.0.0:443 entropy-caddy')
        ..reply('docker-compose.yml', stdout: 'yes\n');

      await hub.provision(record);

      // The recipe ran (it is idempotent) and the hub is registered.
      expect(runner.written, contains('/tmp/entropy-remote-setup.sh'));
      expect(
        runner.written['/tmp/entropy-remote-setup.sh'],
        contains('CouchDB'),
      );
      expect(registry.find('home'), isNotNull);
    });

    test('the generated passwords never appear in the stored record', () async {
      runner
        ..reply('getent hosts', stdout: '203.0.113.10\n')
        ..reply('ipify', stdout: '203.0.113.10\n')
        ..reply('docker-compose.yml', stdout: 'yes\n');

      await hub.provision(record);

      final raw = File(p.join(tmp.path, 'hubs.json')).readAsStringSync();
      expect(raw, isNot(contains('COUCH_ADMIN_PASS')));
      expect(raw, isNot(contains('SYNC_USER_PASS')));
    });
  });

  group('databases', () {
    test('creating one restricts it to its own grants from the start',
        () async {
      await hub.createDatabase(record, 'notes');

      expect(await hub.listDatabases(record), contains('notes'));
      // Internal databases are not offered as vault targets.
      expect(await hub.listDatabases(record), isNot(contains('_users')));
      // No members yet — it is never briefly open.
      expect(admin.membersOf('notes'), isEmpty);
    });

    test('creating one that exists is refused, naming the hub', () async {
      await hub.createDatabase(record, 'notes');

      await expectLater(
        hub.createDatabase(record, 'notes'),
        throwsA(isA<HubRefused>().having((e) => e.toString(), 'message',
            allOf(contains('notes'), contains('home')))),
      );
    });

    test('deleting is refused without confirmation, then removes its grants',
        () async {
      await hub.createDatabase(record, 'notes');
      await hub.createGrant(record, 'notes', 'домашний мак');
      await hub.createGrant(record, 'notes', 'рабочий мак');

      // Refused: nothing changes.
      await expectLater(
        hub.deleteDatabase(record, 'notes'),
        throwsA(isA<HubRefused>()
            .having((e) => e.toString(), 'message', contains('destroys'))),
      );
      expect(await hub.listDatabases(record), contains('notes'));
      expect(admin.users, hasLength(2));

      // Confirmed: the database and both users go, no orphan left behind.
      await hub.deleteDatabase(record, 'notes', confirm: true);
      expect(await hub.listDatabases(record), isNot(contains('notes')));
      expect(admin.users, isEmpty);
    });
  });

  group('grants: one device, one user, one URI (R1)', () {
    test('a grant creates its own user and emits a decodable setup-URI',
        () async {
      await hub.createDatabase(record, 'vault');

      final issued = await hub.createGrant(record, 'vault', 'рабочий мак');

      // Its own user, a member of that database, carrying the label.
      expect(admin.users, hasLength(1));
      expect(admin.membersOf('vault'), [issued.grant.user]);
      expect(admin.users[issued.grant.user]!['entropyLabel'], 'рабочий мак');

      // The URI decodes to exactly this grant.
      final cipher = await TransferCipher.derive(issued.transferSecret);
      final payload = jsonDecode(await cipher.decryptText(
        utf8.decode(base64Url.decode(Uri.parse(issued.setupUri).fragment)),
      )) as Map<String, Object?>;
      expect(payload['endpoint'], 'https://sync.example.com');
      expect(payload['database'], 'vault');
      expect(payload['serverUser'], issued.grant.user);
      expect(payload['serverPassword'], issued.password);

      // The single pasteable form is the URI with the secret inside it.
      expect(issued.combined, '${issued.setupUri}~${issued.transferSecret}');
    });

    test('two grants on one database carry different credentials', () async {
      await hub.createDatabase(record, 'vault');

      final home = await hub.createGrant(record, 'vault', 'домашний мак');
      final work = await hub.createGrant(record, 'vault', 'рабочий мак');

      expect(home.grant.user, isNot(work.grant.user));
      expect(home.password, isNot(work.password));
      expect(
        admin.membersOf('vault'),
        containsAll([home.grant.user, work.grant.user]),
      );

      final listed = await hub.listGrants(record, 'vault');
      expect(
        listed.map((g) => g.label),
        containsAll(['домашний мак', 'рабочий мак']),
      );
    });

    test('two devices may share a label and still get distinct users',
        () async {
      await hub.createDatabase(record, 'vault');

      final a = await hub.createGrant(record, 'vault', 'мак');
      final b = await hub.createGrant(record, 'vault', 'мак');

      expect(a.grant.user, isNot(b.grant.user));
      expect(admin.membersOf('vault'), hasLength(2));
    });

    test('revoking one leaves the others untouched', () async {
      await hub.createDatabase(record, 'vault');
      final home = await hub.createGrant(record, 'vault', 'домашний мак');
      final work = await hub.createGrant(record, 'vault', 'рабочий мак');
      final phone = await hub.createGrant(record, 'vault', 'телефон');

      await hub.revokeGrant(record, 'vault', work.grant.user);

      // Gone from the members and from the server's users.
      expect(admin.membersOf('vault'), isNot(contains(work.grant.user)));
      expect(admin.users.containsKey(work.grant.user), isFalse);

      // The other two are exactly as they were — no reconfiguration.
      expect(
        admin.membersOf('vault'),
        containsAll([home.grant.user, phone.grant.user]),
      );
      expect(admin.users.containsKey(home.grant.user), isTrue);
      expect(admin.users.containsKey(phone.grant.user), isTrue);

      // Revoking again is a no-op, not an error.
      await hub.revokeGrant(record, 'vault', work.grant.user);
      expect(admin.membersOf('vault'), hasLength(2));
    });

    test('a revoked user name is never handed out again', () async {
      await hub.createDatabase(record, 'vault');
      final first = await hub.createGrant(record, 'vault', 'мак');
      await hub.revokeGrant(record, 'vault', first.grant.user);

      // Fresh grants keep their own identities even after a revocation.
      final again = await hub.createGrant(record, 'vault', 'мак');
      expect(again.grant.user, isNot(first.grant.user));
    });
  });
}

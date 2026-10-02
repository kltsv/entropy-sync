import 'dart:convert';
import 'dart:math';

import '../transfer_cipher.dart';
import 'couch_admin.dart';
import 'hub_registry.dart';
import 'remote_setup_script.dart';
import 'ssh.dart';

/// One device's access to one database: its own CouchDB user, carrying the
/// owner's label (`vault_sync_hub` R1). Revoking it stops that device and
/// touches no other.
class HubGrant {
  const HubGrant({
    required this.user,
    required this.label,
    required this.createdAtMillis,
  });

  /// The CouchDB user name — this grant's identity on the hub.
  final String user;

  /// What the owner called this device ("рабочий мак").
  final String label;

  final int createdAtMillis;
}

/// A grant just created, with the one-time values that can never be read back
/// from the hub (`vault_sync_hub` R1).
class IssuedGrant {
  const IssuedGrant({
    required this.grant,
    required this.password,
    required this.setupUri,
    required this.transferSecret,
  });

  final HubGrant grant;
  final String password;
  final String setupUri;
  final String transferSecret;

  /// The single pasteable string: the URI with the secret inside it, the form
  /// `vault_sync_control` D9 defines.
  String get combined => '$setupUri~$transferSecret';
}

/// Raised when an operation is refused for a stated reason the owner can act
/// on — a destructive act without confirmation, a name that is already taken.
class HubRefused implements Exception {
  HubRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The hub as a managed object: provision a host, then create the databases
/// that host vaults and grant per-device access to them (`vault_sync_hub`).
///
/// Two seams keep it testable without a VPS: [runner] (production: the system
/// SSH client) and [adminFactory] (production: CouchDB over SSH on the hub's
/// loopback, so administration never crosses the public internet, C2).
class HubService {
  HubService({
    required this.registry,
    HubRunner? runner,
    CouchAdmin Function(HubRecord)? adminFactory,
  })  : runner = runner ?? const SystemSshRunner(),
        _adminFactory = adminFactory;

  final HubRegistry registry;
  final HubRunner runner;
  final CouchAdmin Function(HubRecord)? _adminFactory;

  CouchAdmin _admin(HubRecord hub) =>
      _adminFactory?.call(hub) ??
      SshCouchAdmin(runner: runner, sshTarget: hub.sshTarget);

  /// Fail before touching the host when SSH cannot authenticate — the key is
  /// the owner's, supplied by their agent or SSH config (C1).
  Future<void> _requireReachable(HubRecord hub) async {
    if (!await runner.reachable(hub.sshTarget)) {
      throw HubUnreachable(
        sshTarget: hub.sshTarget,
        detail: 'the SSH client could not authenticate or connect',
      );
    }
  }

  /// Turn a bare host into a hub, or attach to one already provisioned.
  /// **Idempotent**: existing data, users and databases are left alone.
  ///
  /// Reports the two things that are commonly not ready — DNS not pointing
  /// here yet, and a port already in use — before changing anything.
  Future<void> provision(HubRecord hub, {String database = 'vault'}) async {
    await _requireReachable(hub);

    // What the host believes its own address to be, against what the domain
    // resolves to. A mismatch is reported with both values, and nothing is
    // changed (the run is idempotent, so a later attempt costs nothing).
    final resolved = await runner.run(
      hub.sshTarget,
      'getent hosts ${hub.domain} | head -1 | awk "{print \\\$1}"',
    );
    final hostAddress = await runner.run(
      hub.sshTarget,
      'curl -fsS --max-time 10 https://api.ipify.org || hostname -I | '
      'awk "{print \\\$1}"',
    );
    final domainIp = resolved.stdout.trim();
    final hostIp = hostAddress.stdout.trim();
    if (domainIp.isEmpty) {
      throw HubRefused(
        '${hub.domain} does not resolve yet. Point an A record at $hostIp '
        'and run this again — nothing has been changed on the host.',
      );
    }
    if (hostIp.isNotEmpty && domainIp != hostIp) {
      throw HubRefused(
        '${hub.domain} resolves to $domainIp, but this host is $hostIp. Fix '
        'the DNS record and run this again — nothing has been changed.',
      );
    }

    // A port already taken by something we did not install: report it rather
    // than fight over it.
    final ports = await runner.run(
      hub.sshTarget,
      'sudo ss -tlnp 2>/dev/null | grep -E ":(80|443|5984) " || true',
    );
    final foreign = ports.stdout
        .split('\n')
        .where((l) => l.trim().isNotEmpty && !l.contains('entropy'))
        .toList();
    final alreadyOurs = await runner.run(
      hub.sshTarget,
      'test -f /opt/entropy-sync/docker-compose.yml && echo yes || echo no',
    );
    if (foreign.isNotEmpty && alreadyOurs.stdout.trim() != 'yes') {
      throw HubRefused(
        'ports 80/443/5984 are already in use on this host by something else:\n'
        '${foreign.join('\n')}\n'
        'Nothing has been installed or changed. Free those ports, or use a '
        'host that is not already serving.',
      );
    }

    await runner.writeFile(
      hub.sshTarget,
      '/tmp/entropy-remote-setup.sh',
      remoteSetupScript,
    );
    final adminPass = _randomPassword();
    final syncPass = _randomPassword();
    final result = await runner.run(
      hub.sshTarget,
      'sudo chmod +x /tmp/entropy-remote-setup.sh && '
      'sudo DOMAIN=${_sh(hub.domain)} ACME_EMAIL=${_sh(hub.acmeEmail)} '
      'COUCH_ADMIN_PASS=${_sh(adminPass)} SYNC_USER_PASS=${_sh(syncPass)} '
      'DATABASE=${_sh(database)} '
      'bash /tmp/entropy-remote-setup.sh',
    );
    if (!result.ok) {
      throw HubOperationFailed(
        operation: 'provision ${hub.label}',
        detail: result.stderr.trim().isEmpty
            ? result.stdout.trim()
            : result.stderr.trim(),
      );
    }
    registry.upsert(hub);
  }

  /// The hub's databases, excluding CouchDB's own internal ones.
  Future<List<String>> listDatabases(HubRecord hub) async {
    await _requireReachable(hub);
    final resp = await _admin(hub).send('GET', '_all_dbs');
    if (!resp.ok) {
      throw HubOperationFailed(
        operation: 'list databases on ${hub.label}',
        detail: 'HTTP ${resp.statusCode}',
      );
    }
    return [
      for (final db in resp.jsonList.cast<String>())
        if (!db.startsWith('_')) db,
    ];
  }

  /// Create a database for one vault, restricted from the start: no members
  /// until a grant adds one, so it is never briefly open.
  Future<void> createDatabase(HubRecord hub, String name) async {
    await _requireReachable(hub);
    final admin = _admin(hub);
    final created = await admin.send('PUT', name);
    if (created.statusCode == 412) {
      throw HubRefused(
        'database "$name" already exists on ${hub.label} — pick another name, '
        'or grant a device access to the existing one.',
      );
    }
    if (!created.ok) {
      throw HubOperationFailed(
        operation: 'create database "$name"',
        detail: 'HTTP ${created.statusCode} ${created.body}',
      );
    }
    await _putSecurity(admin, name, const []);
  }

  /// Destroy a database and every grant on it. Refused without [confirm]:
  /// this deletes the vault's server copy.
  Future<void> deleteDatabase(
    HubRecord hub,
    String name, {
    bool confirm = false,
  }) async {
    if (!confirm) {
      throw HubRefused(
        'deleting "$name" destroys the vault\'s copy on ${hub.label} and every '
        'device\'s access to it; devices holding a local copy stop syncing. '
        'Confirm explicitly to proceed.',
      );
    }
    await _requireReachable(hub);
    final admin = _admin(hub);
    // Drop the grants first, so no user is left behind pointing at nothing.
    for (final grant in await _grantsVia(admin, name)) {
      await _deleteUser(admin, grant.user);
    }
    final resp = await admin.send('DELETE', name);
    if (!resp.ok && resp.statusCode != 404) {
      throw HubOperationFailed(
        operation: 'delete database "$name"',
        detail: 'HTTP ${resp.statusCode}',
      );
    }
  }

  /// The devices granted access to [database], with their labels.
  Future<List<HubGrant>> listGrants(HubRecord hub, String database) async {
    await _requireReachable(hub);
    return _grantsVia(_admin(hub), database);
  }

  Future<List<HubGrant>> _grantsVia(CouchAdmin admin, String database) async {
    final sec = await admin.send('GET', '$database/_security');
    if (!sec.ok) return const [];
    final members = (sec.json['members'] as Map?)?.cast<String, Object?>();
    final names = (members?['names'] as List?)?.cast<String>() ?? const [];
    final out = <HubGrant>[];
    for (final name in names) {
      final doc = await admin.send('GET', '_users/org.couchdb.user:$name');
      if (!doc.ok) continue;
      final json = doc.json;
      out.add(HubGrant(
        user: name,
        label: json['entropyLabel'] as String? ?? name,
        createdAtMillis: (json['entropyCreatedAt'] as num?)?.toInt() ?? 0,
      ));
    }
    out.sort((a, b) => a.createdAtMillis.compareTo(b.createdAtMillis));
    return out;
  }

  /// Grant one device access to [database]: its own user, its own password,
  /// and the setup-URI carrying them. The password cannot be read back
  /// afterwards, so this is the only moment it exists (R1).
  Future<IssuedGrant> createGrant(
    HubRecord hub,
    String database,
    String label,
  ) async {
    await _requireReachable(hub);
    final admin = _admin(hub);

    final existing = await _grantsVia(admin, database);
    final user = _userNameFor(database, label, existing.map((g) => g.user));
    final password = _randomPassword();

    final created = await admin.send(
      'PUT',
      '_users/org.couchdb.user:$user',
      body: {
        'name': user,
        'password': password,
        'roles': <String>[],
        'type': 'user',
        'entropyLabel': label,
        'entropyDatabase': database,
        'entropyCreatedAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
    if (!created.ok) {
      throw HubOperationFailed(
        operation: 'create grant "$label"',
        detail: 'HTTP ${created.statusCode} ${created.body}',
      );
    }
    await _putSecurity(admin, database, [...existing.map((g) => g.user), user]);

    final secret = newTransferSecret();
    final cipher = await TransferCipher.derive(secret);
    final blob = await cipher.encryptText(jsonEncode({
      'endpoint': hub.endpoint,
      'database': database,
      'serverUser': user,
      'serverPassword': password,
    }));
    return IssuedGrant(
      grant: HubGrant(
        user: user,
        label: label,
        createdAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
      password: password,
      setupUri: 'entropy-sync://setup#${base64Url.encode(utf8.encode(blob))}',
      transferSecret: secret,
    );
  }

  /// Revoke one device: drop its user from the database and delete it. Every
  /// other device keeps working with the credentials it already has. Revoking
  /// something already gone is a no-op, not an error.
  Future<void> revokeGrant(
    HubRecord hub,
    String database,
    String user,
  ) async {
    await _requireReachable(hub);
    final admin = _admin(hub);
    final remaining = (await _grantsVia(admin, database))
        .map((g) => g.user)
        .where((u) => u != user)
        .toList();
    await _putSecurity(admin, database, remaining);
    await _deleteUser(admin, user);
  }

  Future<void> _putSecurity(
    CouchAdmin admin,
    String database,
    List<String> members,
  ) async {
    final resp = await admin.send('PUT', '$database/_security', body: {
      'admins': {'names': <String>[], 'roles': <String>[]},
      'members': {'names': members, 'roles': <String>[]},
    });
    if (!resp.ok) {
      throw HubOperationFailed(
        operation: 'restrict "$database"',
        detail: 'HTTP ${resp.statusCode} ${resp.body}',
      );
    }
  }

  Future<void> _deleteUser(CouchAdmin admin, String user) async {
    final doc = await admin.send('GET', '_users/org.couchdb.user:$user');
    if (!doc.ok) return; // already gone
    final rev = doc.json['_rev'] as String?;
    if (rev == null) return;
    await admin.send('DELETE', '_users/org.couchdb.user:$user?rev=$rev');
  }
}

/// A CouchDB user name for a labelled device: the database, a slug of the
/// label, and a short random suffix so two devices may share a label and a
/// revoked name is never silently reused.
String _userNameFor(String database, String label, Iterable<String> taken) {
  final slug = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final base = '${_slugOf(database)}-${slug.isEmpty ? 'device' : slug}';
  final used = taken.toSet();
  String candidate;
  do {
    candidate = '$base-${_randomHex(3)}';
  } while (used.contains(candidate));
  return candidate;
}

String _slugOf(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

/// A readable one-time transfer secret: four groups of four characters from
/// an unambiguous lowercase alphabet (no 0/o, 1/l) — the same shape the CLI's
/// `setup-uri` verb emits.
String newTransferSecret() {
  const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
  final rng = Random.secure();
  String group() =>
      List.generate(4, (_) => alphabet[rng.nextInt(alphabet.length)]).join();
  return '${group()}-${group()}-${group()}-${group()}';
}

String _randomPassword() {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rng = Random.secure();
  return List.generate(24, (_) => alphabet[rng.nextInt(alphabet.length)])
      .join();
}

String _randomHex(int bytes) {
  final rng = Random.secure();
  return List.generate(
    bytes,
    (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Single-quote a value for the remote shell.
String _sh(String value) => "'${value.replaceAll("'", "'\\''")}'";

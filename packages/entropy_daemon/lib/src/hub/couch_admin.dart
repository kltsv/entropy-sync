import 'dart:convert';

import 'ssh.dart';

/// One administrative response from a hub's CouchDB.
class AdminResponse {
  const AdminResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  bool get ok => statusCode >= 200 && statusCode < 300;

  Map<String, Object?> get json =>
      (jsonDecode(body) as Map).cast<String, Object?>();

  List<Object?> get jsonList => jsonDecode(body) as List<Object?>;
}

/// How administrative calls reach a hub's CouchDB.
///
/// The production implementation goes **through SSH to the hub's loopback**,
/// never to the public endpoint (`vault_sync_hub` C2). Tests point it at a
/// CouchDB directly, so the administration logic is exercised against a real
/// server rather than a mock of one.
abstract class CouchAdmin {
  Future<AdminResponse> send(String method, String path, {Object? body});
}

/// [CouchAdmin] over SSH: `curl` on the hub, against `127.0.0.1`.
///
/// The admin password is **read from the hub's own environment file on every
/// call and discarded** — it is never copied to this device, so nothing about
/// the hub survives locally (`vault_sync_hub` C2).
class SshCouchAdmin implements CouchAdmin {
  SshCouchAdmin({
    required this.runner,
    required this.sshTarget,
    this.installDir = '/opt/entropy-sync',
    this.couchUrl = 'http://127.0.0.1:5984',
  });

  final HubRunner runner;
  final String sshTarget;
  final String installDir;
  final String couchUrl;

  @override
  Future<AdminResponse> send(String method, String path, {Object? body}) async {
    // Read the credentials on the host, use them on the host: they are
    // interpolated by the *remote* shell and never cross to this device.
    final envFile = '$installDir/.env';
    final buffer = StringBuffer()
      ..write('set -e; ')
      ..write('U=\$(sudo sed -n "s/^COUCHDB_USER=//p" $envFile | head -1); ')
      ..write(
          'P=\$(sudo sed -n "s/^COUCHDB_PASSWORD=//p" $envFile | head -1); ')
      ..write('[ -n "\$U" ] || { echo "no admin user in $envFile" >&2; '
          'exit 3; }; ')
      ..write('curl -sS -o /tmp/entropy-hub-body -w "%{http_code}" ')
      ..write('-u "\$U:\$P" -X $method ');
    if (body != null) {
      buffer.write("-H 'Content-Type: application/json' --data-binary @- ");
    }
    buffer
      ..write('"$couchUrl/$path"; ')
      ..write('echo; cat /tmp/entropy-hub-body; rm -f /tmp/entropy-hub-body');

    final result = await runner.run(
      sshTarget,
      buffer.toString(),
      stdin: body == null ? null : jsonEncode(body),
    );
    if (!result.ok) {
      throw HubOperationFailed(
        operation: '$method $path',
        detail: result.stderr.trim().isEmpty
            ? 'exit ${result.exitCode}'
            : result.stderr.trim(),
      );
    }
    // stdout is "<status>\n<body>" — the status line then whatever curl wrote.
    final newline = result.stdout.indexOf('\n');
    final statusText =
        (newline < 0 ? result.stdout : result.stdout.substring(0, newline))
            .trim();
    final payload = newline < 0 ? '' : result.stdout.substring(newline + 1);
    return AdminResponse(
      statusCode: int.tryParse(statusText) ?? 0,
      body: payload,
    );
  }
}

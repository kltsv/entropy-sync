import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'control_protocol.dart';
import 'daemon.dart';

/// The daemon's authenticated, local-only control channel (`vault_daemon`
/// R18, R19). It binds to **localhost only**, requires the daemon's shared token
/// on every request, and carries only control/status — never vault plaintext
/// (C3). Multiple front-ends may attach at once and all see the same
/// authoritative state (R20).
class ControlServer {
  ControlServer({required this.daemon, required this.token});

  final Daemon daemon;
  final String token;

  HttpServer? _server;

  Future<void> start({int port = 0}) async {
    final handler =
        const Pipeline().addMiddleware(_authMiddleware).addHandler(_route);
    // Loopback only — never reachable off the machine (R18).
    _server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, port);
  }

  int get port => _server!.port;

  Future<void> stop() async => _server?.close(force: true);

  Middleware get _authMiddleware => (innerHandler) {
        return (request) {
          final presented = request.headers['x-entropy-token'];
          if (presented == null || presented != token) {
            return Response.forbidden(
              jsonEncode({'error': 'unauthorized'}),
              headers: {'content-type': 'application/json'},
            );
          }
          return innerHandler(request);
        };
      };

  Future<Response> _route(Request request) async {
    if (request.method == 'GET' && request.url.path == 'status') {
      return _json(daemon.status().toJson());
    }
    if (request.method == 'POST' && request.url.path == 'control') {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, Object?>;
      final command = ControlCommand.values.byName(body['command'] as String);
      await daemon.applyCommand(command, body['vaultId'] as String?);
      return _json(daemon.status().toJson());
    }
    // Register (or edit) a vault from a front-end — setup ends with a syncing
    // vault, no restart (`vault_daemon` "add/edit a vault profile",
    // `vault_sync_control` "setup ends with a syncing vault").
    if (request.method == 'POST' && request.url.path == 'vaults') {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, Object?>;
      try {
        await daemon.registerVault(AddVaultRequest.fromJson(body));
      } on VaultTargetConflict catch (e) {
        return Response(
          409,
          body: jsonEncode({
            'error': 'targetConflict',
            'conflictsWith': e.conflictsWith,
            'message': e.toString(),
          }),
          headers: {'content-type': 'application/json'},
        );
      } on VaultFolderConflict catch (e) {
        return Response(
          409,
          body: jsonEncode({
            'error': 'folderConflict',
            'conflictsWith': e.conflictsWith,
            'message': e.toString(),
          }),
          headers: {'content-type': 'application/json'},
        );
      }
      return _json(daemon.status().toJson());
    }
    // One vault's per-module configuration: read, or change a part of it
    // without secrets and without re-registering (`daemon-modules` R9).
    final segments = request.url.pathSegments;
    if (segments.length == 3 &&
        segments[0] == 'vaults' &&
        segments[2] == 'config') {
      final vaultId = Uri.decodeComponent(segments[1]);
      try {
        if (request.method == 'GET') {
          return _json(daemon.vaultConfig(vaultId));
        }
        if (request.method == 'PATCH') {
          final patch =
              jsonDecode(await request.readAsString()) as Map<String, Object?>;
          final next = await daemon.updateConfig(vaultId, patch);
          return _json(next.toRegistryJson());
        }
      } on ConfigError catch (e) {
        return Response(
          e.unknownVault ? 404 : 400,
          body: jsonEncode({'error': 'config', 'message': e.message}),
          headers: {'content-type': 'application/json'},
        );
      }
    }
    return Response.notFound(jsonEncode({'error': 'not found'}));
  }

  Response _json(Object? payload) => Response.ok(
        jsonEncode(payload),
        headers: {'content-type': 'application/json'},
      );
}

/// Where the daemon advertises its live control endpoint so front-ends can
/// **discover** an already-running daemon and attach without re-setup (R18, R20).
/// The file holds the loopback port and the shared token, written user-only.
class ControlDiscovery {
  ControlDiscovery(this.directory);

  /// Default: `~/.entropy-sync` (or `$ENTROPY_SYNC_HOME`).
  factory ControlDiscovery.defaultLocation() {
    final home = Platform.environment['ENTROPY_SYNC_HOME'] ??
        '${Platform.environment['HOME'] ?? '.'}/.entropy-sync';
    return ControlDiscovery(home);
  }

  final String directory;

  File get _file => File('$directory${Platform.pathSeparator}control.json');

  /// Advertise the endpoint. The token is the local shared secret a front-end
  /// must present (R19).
  void write({required int port, required String token}) {
    Directory(directory).createSync(recursive: true);
    _file.writeAsStringSync(jsonEncode({'port': port, 'token': token}));
    _restrictPermissions(_file);
  }

  /// Discover a running daemon, or null if none is advertised.
  ({int port, String token})? read() {
    if (!_file.existsSync()) return null;
    final json = jsonDecode(_file.readAsStringSync()) as Map<String, Object?>;
    return (
      port: (json['port'] as num).toInt(),
      token: json['token'] as String
    );
  }

  void clear() {
    if (_file.existsSync()) _file.deleteSync();
  }

  void _restrictPermissions(File file) {
    if (Platform.isLinux || Platform.isMacOS) {
      // Best-effort: readable only by the owning user (R19).
      Process.runSync('chmod', ['600', file.path]);
    }
  }
}

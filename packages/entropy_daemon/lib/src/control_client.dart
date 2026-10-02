import 'dart:convert';

import 'package:http/http.dart' as http;

import 'control_protocol.dart';

/// A front-end's client to the daemon's control channel (`vault_sync_control`
/// R18, R19). It presents the daemon token on every request; without it the
/// daemon refuses status and commands. Used by the entropy app and mirrored by
/// the Obsidian plugin.
class ControlClient {
  ControlClient({
    required this.port,
    required this.token,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final int port;
  final String token;
  final http.Client _http;

  Uri _uri(String path) => Uri.parse('http://127.0.0.1:$port/$path');

  Map<String, String> get _headers => {
        'x-entropy-token': token,
        'content-type': 'application/json',
      };

  Future<DaemonStatus> status() async {
    final resp = await _http.get(_uri('status'), headers: _headers);
    _check(resp);
    return DaemonStatus.fromJson(
      jsonDecode(resp.body) as Map<String, Object?>,
    );
  }

  Future<DaemonStatus> command(
    ControlCommand command, {
    String? vaultId,
  }) async {
    final resp = await _http.post(
      _uri('control'),
      headers: _headers,
      body: jsonEncode({'command': command.name, 'vaultId': vaultId}),
    );
    _check(resp);
    return DaemonStatus.fromJson(
      jsonDecode(resp.body) as Map<String, Object?>,
    );
  }

  /// Register (or edit) a vault on the running daemon — the front-end handoff
  /// that makes setup end with a syncing vault (`vault_sync_control`). Throws
  /// [ControlVaultConflict] when the daemon refuses a target already served by
  /// a different vault.
  Future<DaemonStatus> addVault(AddVaultRequest request) async {
    final resp = await _http.post(
      _uri('vaults'),
      headers: _headers,
      body: jsonEncode(request.toJson()),
    );
    if (resp.statusCode == 409) {
      final body = jsonDecode(resp.body) as Map<String, Object?>;
      throw ControlVaultConflict(
        conflictsWith: body['conflictsWith'] as String? ?? '?',
        message: body['message'] as String? ?? 'target conflict',
        kind: body['error'] == 'folderConflict'
            ? VaultConflictKind.folder
            : VaultConflictKind.database,
      );
    }
    _check(resp);
    return DaemonStatus.fromJson(
      jsonDecode(resp.body) as Map<String, Object?>,
    );
  }

  /// One vault's per-module configuration — never a secret in it
  /// (`daemon-modules` R9).
  Future<Map<String, Object?>> vaultConfig(String vaultId) async {
    final resp = await _http.get(
        _uri('vaults/${Uri.encodeComponent(vaultId)}/config'),
        headers: _headers);
    _checkConfig(resp);
    return (jsonDecode(resp.body) as Map).cast<String, Object?>();
  }

  /// Change part of one vault's configuration without re-registering it:
  /// [patch] is shaped like the configuration and names only what changes
  /// (`daemon-modules` R9, R10). Returns the whole configuration after.
  Future<Map<String, Object?>> updateVaultConfig(
      String vaultId, Map<String, Object?> patch) async {
    final resp = await _http.patch(
      _uri('vaults/${Uri.encodeComponent(vaultId)}/config'),
      headers: _headers,
      body: jsonEncode(patch),
    );
    _checkConfig(resp);
    return (jsonDecode(resp.body) as Map).cast<String, Object?>();
  }

  void _checkConfig(http.Response resp) {
    if (resp.statusCode == 400 || resp.statusCode == 404) {
      final body = jsonDecode(resp.body) as Map<String, Object?>;
      throw ControlConfigError(
          body['message'] as String? ?? 'configuration refused');
    }
    _check(resp);
  }

  void _check(http.Response resp) {
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw StateError('control channel refused: not authenticated');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('control channel error: HTTP ${resp.statusCode}');
    }
  }

  void close() => _http.close();
}

/// The daemon refused a configuration change — an unknown vault, or one
/// that cannot be applied (enabling sync with no connection).
class ControlConfigError implements Exception {
  ControlConfigError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Which isolation rule the daemon refused on. The two are not
/// interchangeable: a [database] conflict is a policy guard the owner may
/// acknowledge, a [folder] conflict is a technical limit with no override
/// (`vault_daemon` R23).
enum VaultConflictKind { database, folder }

/// The daemon refused to register a vault that collides with one it already
/// serves (`vault_daemon` R23 isolation).
class ControlVaultConflict implements Exception {
  ControlVaultConflict({
    required this.conflictsWith,
    required this.message,
    this.kind = VaultConflictKind.database,
  });

  final String conflictsWith;
  final String message;
  final VaultConflictKind kind;

  /// Whether re-sending with the shared-database acknowledgement could succeed
  /// — true only for a database collision.
  bool get isAcknowledgeable => kind == VaultConflictKind.database;

  @override
  String toString() => message;
}

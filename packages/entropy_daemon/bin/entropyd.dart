import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:entropy_hist/entropy_hist.dart';
import 'package:entropy_sync/entropy_sync.dart';
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Thin process entry point for `entropyd` (`vault_daemon` RV10).
/// All behaviour lives in the tested library; this wires it to the process:
///
///   entropyd init     — register a vault (profile, secrets, meta, scan)
///   entropyd run      — serve all registered vaults (default command)
///   entropyd status   — one-shot status of the running daemon
///   entropyd config   — read/change one vault's per-module configuration
///   entropyd inspect  — decrypt and show the database client-side (RV2)
///   entropyd hist     — the history command line over a served vault
///                            (the same verbs as the standalone `hist`)
const _version = '0.2.0';

/// The running daemon's log, so the last-line-of-defense zone handler can
/// record an escaped error instead of losing it with the process.
DaemonLog? _zoneLog;

Future<void> main(List<String> args) async {
  // Last line of defense (`vault_daemon`): nothing that escapes an
  // unawaited future may kill the daemon — log it and keep serving.
  await runZonedGuarded(() => _dispatch(args), (error, stack) {
    final line = 'unhandled error: $error';
    _zoneLog?.log(line);
    stderr.writeln('entropyd: $line');
  });
}

Future<void> _dispatch(List<String> args) async {
  // `--version` is what the installers ask a binary for; it must never fall
  // through to `run`.
  if (args.isNotEmpty && (args.first == '--version' || args.first == '-v')) {
    stdout.writeln(_version);
    return;
  }
  final command =
      args.isEmpty || args.first.startsWith('-') ? 'run' : args.first;
  final rest =
      args.isEmpty || args.first.startsWith('-') ? args : args.sublist(1);
  try {
    switch (command) {
      case 'run':
        await _run(rest);
      case 'init':
        await _init(rest);
      case 'status':
        await _status(rest);
      case 'inspect':
        await _inspect(rest);
      case 'hist':
        await _hist(rest);
      case 'config':
        await _config(rest);
      case 'setup-uri':
        await _setupUri(rest);
      case 'hub':
        await _hub(rest);
      case 'version':
      case '--version':
        stdout.writeln(_version);
      default:
        stderr.writeln('unknown command: $command\n$_usage');
        exitCode = 64;
    }
  } on UsageException catch (e) {
    stderr.writeln(e.message);
    exitCode = 64;
  }
}

const _usage = 'entropyd <run|init|status|config|inspect|hist|setup-uri|hub> '
    '[options]';

const _hubUsage = '''
entropyd hub <command> [options]

  add        --label … --ssh … --domain … --email …   record a hub
  list                                                the recorded hubs
  remove     --label …                                forget a hub locally
  provision  --label …                                install/attach the hub
  db list    --label …                                its vault databases
  db create  --label … --db …                         a database for a vault
  db delete  --label … --db … --yes                   destroy it and its grants
  grant list   --label … --db …                       the devices with access
  grant create --label … --db … --name "рабочий мак"  a device's own URI
  grant revoke --label … --db … --user …              cut off one device

SSH authentication comes from your agent or ~/.ssh/config — entropy never
stores a key or a password. Administration runs on the hub's loopback, so
nothing administrative crosses the public endpoint.''';

class UsageException implements Exception {
  UsageException(this.message);
  final String message;
}

ArgParser _base() => ArgParser()
  ..addOption(
    'state-root',
    help: 'daemon state root (registry, replicas, secrets fallback)',
    defaultsTo: _defaultStateRoot(),
  )
  ..addFlag('help', abbr: 'h', negatable: false);

String _defaultStateRoot() =>
    Platform.environment['ENTROPY_SYNC_HOME'] ??
    p.join(Platform.environment['HOME'] ?? '.', '.entropy-sync');

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

Future<void> _run(List<String> args) async {
  final parser = _base()
    ..addOption('port', help: 'control channel port', defaultsTo: '0');
  final opts = parser.parse(args);
  if (opts.flag('help')) {
    stdout.writeln('entropyd run\n${parser.usage}');
    return;
  }

  final stateRoot = opts.option('state-root')!;
  final log = DaemonLog(p.join(stateRoot, 'daemon.log'));
  _zoneLog = log;
  final secrets = productionSecretStore(stateRoot);
  final registry = VaultRegistry(stateRoot);
  final daemon = Daemon(
    version: _version,
    shellFactory: (profile) =>
        productionShell(profile, stateRoot: stateRoot, log: log),
    registry: registry,
    secrets: secrets,
    watchFactory: directoryWatchFactory,
  );

  for (final profile in await registry.loadProfiles(secrets)) {
    try {
      await daemon.addVault(profile);
      log.log('[${profile.vaultId}] registered');
    } catch (e) {
      log.log('[${profile.vaultId}] failed to register: $e');
    }
  }

  // Control channel: a random per-run token, advertised for discovery
  // (R18/R19).
  final token = _newToken();
  final server = ControlServer(daemon: daemon, token: token);
  await server.start(port: int.parse(opts.option('port')!));
  ControlDiscovery(stateRoot).write(port: server.port, token: token);
  log.log('entropyd $_version listening on 127.0.0.1:${server.port}');

  // Continuous mode: the daemon owns each vault's runtime — longpoll engine,
  // filesystem watcher with per-path debounce (RV4), and the periodic
  // full-reconcile backstop. Vaults registered or edited later over the
  // control channel get (and replace) their runtime the same way.
  await daemon.startContinuous();

  ProcessSignal.sigint
      .watch()
      .listen((_) => _shutdown(daemon, server, stateRoot));
  ProcessSignal.sigterm
      .watch()
      .listen((_) => _shutdown(daemon, server, stateRoot));
}

Future<void> _shutdown(
  Daemon daemon,
  ControlServer server,
  String stateRoot,
) async {
  await daemon.stopAll();
  ControlDiscovery(stateRoot).clear();
  await server.stop();
  exit(0);
}

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

Future<void> _init(List<String> args) async {
  final parser = _base()
    ..addOption('vault', help: 'absolute path to the vault folder')
    ..addOption('vault-id', help: 'stable vault id (default: folder name)')
    ..addOption('setup-uri', help: 'entropy-sync://setup#… connection string')
    ..addOption('transfer-secret', help: 'the setup-URI transfer secret')
    ..addOption('endpoint', help: 'CouchDB endpoint, e.g. https://host')
    ..addOption('database', help: 'CouchDB database name')
    ..addOption('server-user')
    ..addOption('server-password',
        help: 'server password (omit to be prompted)')
    ..addOption('passphrase', help: 'E2EE passphrase (omit to be prompted)')
    ..addOption('writer', help: 'writer name for history headers')
    ..addOption('hist-extensions',
        help: 'comma-separated extensions to keep history for '
            '(default .md); use "*" for any file whose content is text')
    ..addFlag('allow-shared-database',
        negatable: false,
        help: 'register even though another vault already uses this database '
            '— both folders then become one vault and converge to the same '
            'content set, and must share the same passphrase')
    ..addOption('modules',
        help: 'the modules to enable: sync,history (default), history (no '
            'connection, no passphrase), or sync (no .hist/)',
        defaultsTo: 'sync,history');
  final opts = parser.parse(args);
  if (opts.flag('help') || opts.option('vault') == null) {
    stdout.writeln('entropyd init --vault <dir> '
        '(--setup-uri … --transfer-secret … | --endpoint … --database … '
        '--server-user …) [--passphrase …] [--modules sync,history|history]'
        '\n${parser.usage}');
    if (opts.option('vault') == null) exitCode = 64;
    return;
  }

  final stateRoot = opts.option('state-root')!;
  final vaultRoot = p.canonicalize(opts.option('vault')!);
  final vaultId = opts.option('vault-id') ?? p.basename(vaultRoot);
  final allowSharedDatabase = opts.flag('allow-shared-database');
  final histExtensions = opts
      .option('hist-extensions')
      ?.split(',')
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();
  final modules = <VaultModule>{
    for (final name in opts.option('modules')!.split(','))
      if (name.trim().isNotEmpty)
        VaultModule.values.asNameMap()[name.trim()] ??
            (throw UsageException('unknown module: ${name.trim()} '
                '(sync, history)')),
  };
  if (modules.isEmpty) throw UsageException('--modules names no module');

  // History alone needs no connection and no passphrase (`daemon-modules`
  // R1, R8) — and asks for none.
  if (!modules.contains(VaultModule.sync)) {
    final profile = VaultProfile(
      vaultId: vaultId,
      vaultRoot: vaultRoot,
      modules: modules,
      writerName: opts.option('writer'),
      histExtensions: histExtensions ?? const ['.md'],
    );
    final tuning = <String, Object?>{
      if (opts.option('writer') != null) 'writerName': opts.option('writer'),
      if (histExtensions != null) 'histExtensions': histExtensions,
    };
    if (await _initViaRunningDaemon(stateRoot, profile, tuning: tuning)) {
      return;
    }
    final registry = VaultRegistry(stateRoot);
    for (final other
        in registry.entries().where((o) => o['vaultId'] != vaultId)) {
      if (foldersOverlap(
          vaultRoot, p.canonicalize(other['vaultRoot'] as String))) {
        stderr.writeln('refused: folder overlaps vault "${other['vaultId']}" '
            '(${other['vaultRoot']}) — two vaults must not share or nest '
            'folders');
        exitCode = 1;
        return;
      }
    }
    registry.upsert(profile);
    final log = DaemonLog(p.join(stateRoot, 'daemon.log'));
    final shell =
        await productionShell(profile, stateRoot: stateRoot, log: log);
    await shell.reconcile();
    await shell.stop();
    stdout.writeln('vault "$vaultId" initialized: $vaultRoot — history only, '
        'no server, no passphrase');
    stdout.writeln('If the daemon is running it picks the vault up on restart '
        'or via a front-end; or start it: entropyd run');
    return;
  }

  String endpoint;
  String database;
  String serverUser;
  String serverPassword;
  if (opts.option('setup-uri') != null) {
    final secret = opts.option('transfer-secret') ??
        _prompt('Transfer secret: ', hidden: true);
    final cipher = await TransferCipher.derive(secret);
    final parsed = Uri.parse(opts.option('setup-uri')!);
    final payload = jsonDecode(await cipher
            .decryptText(utf8.decode(base64Url.decode(parsed.fragment))))
        as Map<String, Object?>;
    endpoint = payload['endpoint'] as String;
    database = payload['database'] as String;
    serverUser = payload['serverUser'] as String;
    serverPassword = payload['serverPassword'] as String;
  } else {
    endpoint = opts.option('endpoint') ??
        (throw UsageException('--endpoint or --setup-uri required'));
    database = opts.option('database') ??
        (throw UsageException('--database required'));
    serverUser = opts.option('server-user') ??
        (throw UsageException('--server-user required'));
    serverPassword = opts.option('server-password') ??
        _prompt('Server password: ', hidden: true);
  }
  final passphrase =
      opts.option('passphrase') ?? _prompt('E2EE passphrase: ', hidden: true);
  if (passphrase.isEmpty) {
    throw UsageException(
      'the E2EE passphrase must not be empty — there is no unencrypted mode',
    );
  }

  final profile = VaultProfile(
    vaultId: vaultId,
    vaultRoot: vaultRoot,
    modules: modules,
    endpoint: endpoint,
    database: database,
    serverUser: serverUser,
    serverPassword: serverPassword,
    passphrase: passphrase,
    writerName: opts.option('writer'),
    histExtensions: histExtensions ?? const ['.md'],
  );

  // Only what the invocation actually asked for travels over the channel:
  // sending the rest would overwrite a served vault's tuning with this
  // command's defaults (`vault_daemon` R23).
  final tuning = <String, Object?>{
    if (opts.option('writer') != null) 'writerName': opts.option('writer'),
    if (histExtensions != null) 'histExtensions': histExtensions,
    'modules': [
      for (final m in VaultModule.values)
        if (modules.contains(m)) m.name
    ],
  };

  // A running daemon owns the replica state files — a second process opening
  // them corrupts the write-through backend. When one is advertised, hand
  // the vault over through the control channel instead of touching the state
  // directly; fall back to the direct path only when nothing answers (a
  // stale advertisement).
  if (await _initViaRunningDaemon(stateRoot, profile,
      allowSharedDatabase: allowSharedDatabase, tuning: tuning)) {
    return;
  }

  // Refuse a collision against the registry before storing anything. Database
  // first, in its own pass, so a candidate colliding on both reports the rule
  // the owner can act on — the same ordering the daemon applies.
  final registry = VaultRegistry(stateRoot);
  final others = registry.entries().where((o) => o['vaultId'] != vaultId);

  if (!allowSharedDatabase) {
    for (final other in others) {
      if (_targetOf(other) == _targetOf(profile.toRegistryJson())) {
        stderr.writeln('refused: database already used by "${other['vaultId']}"'
            ' — two vaults must not share one database. Pass '
            '--allow-shared-database to put one vault in both folders on '
            'purpose (they converge to the same content set and must share '
            'the same passphrase)');
        exitCode = 1;
        return;
      }
    }
  }
  for (final other in others) {
    if (foldersOverlap(
        vaultRoot, p.canonicalize(other['vaultRoot'] as String))) {
      stderr.writeln('refused: folder overlaps vault "${other['vaultId']}" '
          '(${other['vaultRoot']}) — two vaults must not share or nest '
          'folders');
      exitCode = 1;
      return;
    }
  }

  final secrets = productionSecretStore(stateRoot);
  await secrets.write(
      vaultId, DaemonSecretStore.keyServerPassword, serverPassword);
  await secrets.write(vaultId, DaemonSecretStore.keyPassphrase, passphrase);
  registry.upsert(profile);

  // Bring the vault up once: database, meta (write-or-verify, never
  // overwrite), first scan, one sync (best-effort offline).
  final log = DaemonLog(p.join(stateRoot, 'daemon.log'));
  try {
    final shell =
        await productionShell(profile, stateRoot: stateRoot, log: log);
    await shell.reconcile();
    await shell.stop();
    stdout.writeln('vault "$vaultId" initialized: $vaultRoot ⇄ '
        '$endpoint/$database'
        '${shell.lastError != null ? ' (sync pending: ${shell.lastError})' : ''}');
  } on VaultCryptoException catch (e) {
    stderr.writeln('wrong passphrase: ${e.message} — vault registered, fix '
        'the passphrase and re-run init');
    exitCode = 1;
  } on SyncException catch (e) {
    stdout.writeln('vault "$vaultId" registered offline (${e.message}); the '
        'daemon will sync when the hub is reachable');
  }
  stdout.writeln('If the daemon is running it picks the vault up on restart '
      'or via a front-end; or start it: entropyd run');
}

/// Register the vault on an already-running daemon over the control channel
/// (POST /vaults): the daemon stores the secrets, persists the registry
/// entry, and starts serving — no second [LocalStore] ever opens over its
/// live replica. Returns `true` when the init was handled (successfully or
/// with a reported error); `false` when no daemon actually answers and the
/// direct path should proceed.
Future<bool> _initViaRunningDaemon(
  String stateRoot,
  VaultProfile profile, {
  bool allowSharedDatabase = false,
  Map<String, Object?> tuning = const {},
}) async {
  final advertised = ControlDiscovery(stateRoot).read();
  if (advertised == null) return false;
  final client = ControlClient(port: advertised.port, token: advertised.token);
  try {
    final status = await client.addVault(AddVaultRequest(
      profile: {...profile.toConnectionJson(), ...tuning},
      passphrase: profile.passphrase,
      serverPassword: profile.serverPassword,
      allowSharedDatabase: allowSharedDatabase,
    ));
    final vault =
        status.vaults.where((v) => v.vaultId == profile.vaultId).toList();
    final error = vault.isEmpty ? null : vault.single.error;
    stdout.writeln('vault "${profile.vaultId}" registered with the running '
        'daemon: ${profile.vaultRoot} ⇄ ${profile.endpoint}/'
        '${profile.database}${error != null ? ' (error: $error)' : ''}');
    if (error != null) exitCode = 1;
    return true;
  } on ControlVaultConflict catch (e) {
    stderr.writeln('refused: $e');
    if (e.isAcknowledgeable) {
      stderr.writeln('Pass --allow-shared-database to put one vault in both '
          'folders on purpose (they converge to the same content set and must '
          'share the same passphrase).');
    }
    exitCode = 1;
    return true;
  } on SocketException {
    // Stale discovery file — no daemon is actually listening.
    return false;
  } on http.ClientException {
    return false;
  } finally {
    client.close();
  }
}

/// The (endpoint, database) key of a registry entry; empty for a vault
/// without sync.
String _targetOf(Map<String, Object?> registryJson) {
  final profile = VaultProfile.fromRegistryJson(registryJson,
      serverPassword: '', passphrase: '');
  if (!profile.syncEnabled) return '';
  final endpoint =
      profile.endpoint.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
  return '$endpoint::${profile.database}';
}

String _prompt(String label, {bool hidden = false}) {
  stdout.write(label);
  if (hidden && stdin.hasTerminal) stdin.echoMode = false;
  final value = stdin.readLineSync() ?? '';
  if (hidden && stdin.hasTerminal) {
    stdin.echoMode = true;
    stdout.writeln();
  }
  return value;
}

// ---------------------------------------------------------------------------
// status
// ---------------------------------------------------------------------------

Future<void> _status(List<String> args) async {
  final opts = _base().parse(args);
  final stateRoot = opts.option('state-root')!;
  final endpoint = ControlDiscovery(stateRoot).read();
  if (endpoint == null) {
    stderr.writeln('no running daemon advertised under $stateRoot');
    exitCode = 1;
    return;
  }
  final client = ControlClient(port: endpoint.port, token: endpoint.token);
  try {
    final DaemonStatus status;
    try {
      status = await client.status();
    } on SocketException {
      _reportStaleDiscovery(stateRoot);
      return;
    } on http.ClientException {
      _reportStaleDiscovery(stateRoot);
      return;
    }
    stdout.writeln('entropyd ${status.version}');
    if (status.vaults.isEmpty) stdout.writeln('  (no vaults configured)');
    for (final vault in status.vaults) {
      final last = vault.lastSyncMillis == null
          ? '—'
          : DateTime.fromMillisecondsSinceEpoch(vault.lastSyncMillis!)
              .toLocal()
              .toString();
      stdout.writeln('  ${vault.vaultId}: ${vault.state.name}, '
          'last sync $last, un-synced ${vault.unsynced}, '
          'divergent ${vault.divergent}'
          '${vault.modules.isNotEmpty ? ', modules ${vault.modules.join('+')}' : ''}'
          '${vault.error != null ? ', error: ${vault.error}' : ''}');
      for (final entry in vault.degraded.entries) {
        stdout.writeln('    degraded: ${entry.key} — ${entry.value}');
      }
      for (final path in vault.conflicts) {
        stdout.writeln('    conflict: $path');
      }
    }
  } finally {
    client.close();
  }
}

/// The discovery file advertises a daemon that no longer answers (crash,
/// SIGKILL, power loss left the advertisement behind): report it cleanly —
/// message + exit 1, never a stack trace.
void _reportStaleDiscovery(String stateRoot) {
  stderr.writeln('daemon not reachable — no running daemon answers the '
      'advertisement under $stateRoot (stale discovery file?)');
  exitCode = 1;
}

// ---------------------------------------------------------------------------
// config (`daemon-modules` R9, R10)
// ---------------------------------------------------------------------------

/// Read or change one vault's per-module configuration — no secrets, no
/// re-registration. Through the running daemon when one answers (the
/// change takes effect at once); into the registry otherwise (the next
/// start picks it up).
Future<void> _config(List<String> args) async {
  final parser = _base()
    ..addOption('history-extensions',
        help: 'comma-separated extensions history tracks; * for any text')
    ..addOption('history-idle',
        help: 'milliseconds a path must be quiet before an edit is recorded')
    ..addOption('history-writer', help: 'writer name in history headers')
    ..addOption('exclude',
        help: 'comma-separated exclusion patterns (replaces the list)')
    ..addOption('rescan', help: 'periodic full-rescan interval, seconds')
    ..addMultiOption('enable', help: 'a module to enable: history, sync')
    ..addMultiOption('disable', help: 'a module to disable: history, sync');
  final opts = parser.parse(args);
  if (opts.flag('help') || opts.rest.isEmpty) {
    stdout.writeln('entropyd config <vault-id> [changes…]\n'
        'With no change: print the configuration.\n${parser.usage}');
    if (opts.rest.isEmpty) exitCode = 64;
    return;
  }
  final vaultId = opts.rest.first;
  final stateRoot = opts.option('state-root')!;

  // The patch: only what was asked for (omitted means unchanged, R10).
  final history = <String, Object?>{};
  final folder = <String, Object?>{};
  if (opts.option('history-extensions') != null) {
    history['extensions'] = opts
        .option('history-extensions')!
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  if (opts.option('history-idle') != null) {
    history['idleMillis'] = int.tryParse(opts.option('history-idle')!) ??
        (throw UsageException('--history-idle: not a number'));
  }
  if (opts.option('history-writer') != null) {
    history['writerName'] = opts.option('history-writer');
  }
  if (opts.option('exclude') != null) {
    folder['exclusions'] = opts
        .option('exclude')!
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  if (opts.option('rescan') != null) {
    folder['rescanSeconds'] = int.tryParse(opts.option('rescan')!) ??
        (throw UsageException('--rescan: not a number'));
  }
  final patch = <String, Object?>{
    if (history.isNotEmpty) 'history': history,
    if (folder.isNotEmpty) 'folder': folder,
  };
  final enable = opts.multiOption('enable');
  final disable = opts.multiOption('disable');
  for (final name in [...enable, ...disable]) {
    if (VaultModule.values.asNameMap()[name] == null) {
      throw UsageException('unknown module: $name (sync, history)');
    }
  }

  // Through the running daemon, when one answers.
  final advertised = ControlDiscovery(stateRoot).read();
  if (advertised != null) {
    final client =
        ControlClient(port: advertised.port, token: advertised.token);
    try {
      var current = await client.vaultConfig(vaultId);
      if (enable.isNotEmpty || disable.isNotEmpty) {
        patch['modules'] = _modulesAfter(current, enable, disable);
      }
      if (patch.isEmpty) {
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(current));
        return;
      }
      current = await client.updateVaultConfig(vaultId, patch);
      stdout.writeln('applied through the running daemon:');
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(current));
      return;
    } on ControlConfigError catch (e) {
      stderr.writeln('refused: $e');
      exitCode = 1;
      return;
    } on SocketException {
      // stale advertisement — fall through to the registry
    } on http.ClientException {
      // stale advertisement — fall through to the registry
    } finally {
      client.close();
    }
  }

  // No daemon: the registry, for the next start.
  final registry = VaultRegistry(stateRoot);
  final entry = registry.entries().cast<Map<String, Object?>?>().firstWhere(
        (e) => e!['vaultId'] == vaultId,
        orElse: () => null,
      );
  if (entry == null) throw UsageException('unknown vault id: $vaultId');
  if (enable.isNotEmpty || disable.isNotEmpty) {
    patch['modules'] = _modulesAfter(entry, enable, disable);
  }
  final current =
      VaultProfile.fromRegistryJson(entry, serverPassword: '', passphrase: '');
  if (patch.isEmpty) {
    stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(current.toRegistryJson()));
    return;
  }
  final next = current.patched(patch);
  if (next.syncEnabled && next.endpoint.isEmpty) {
    stderr.writeln('refused: vault "$vaultId" has no connection to enable '
        'sync on — add one with `init` or a front-end\'s setup');
    exitCode = 1;
    return;
  }
  registry.upsert(next);
  stdout.writeln('written to the registry (no daemon running — it takes '
      'effect on the next start):');
  stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(next.toRegistryJson()));
}

List<String> _modulesAfter(
    Map<String, Object?> config, List<String> enable, List<String> disable) {
  final modules = <String>{
    ...((config['modules'] as List?) ?? const []).cast<String>(),
  };
  modules.addAll(enable);
  modules.removeAll(disable);
  return [
    for (final m in VaultModule.values)
      if (modules.contains(m.name)) m.name
  ];
}

// ---------------------------------------------------------------------------
// inspect
// ---------------------------------------------------------------------------

Future<void> _inspect(List<String> args) async {
  final parser = _base()..addOption('vault-id', help: 'which vault');
  final opts = parser.parse(args);
  final stateRoot = opts.option('state-root')!;
  final profile = await _loadOneProfile(stateRoot, opts.option('vault-id'));
  if (!profile.syncEnabled) {
    throw UsageException(
        'vault "${profile.vaultId}" has no sync module — nothing to inspect');
  }
  final path = opts.rest.isEmpty ? null : opts.rest.first;

  final transport = CouchTransport(
    baseUrl: Uri.parse(profile.endpoint),
    database: profile.database,
    username: profile.serverUser,
    password: profile.serverPassword,
  );
  final keys = await resolveKeyMaterial(
    transport: transport,
    passphrase: profile.passphrase,
    cacheFile: File(p.join(stateRoot, 'data', profile.vaultId, 'meta.json')),
  );
  final crypto =
      VaultCrypto(keys, inlineThreshold: profile.inlineThresholdBytes);

  if (path != null) {
    final doc = await transport.getDoc(crypto.idFor(path));
    if (doc == null) {
      stderr.writeln('no document for $path');
      exitCode = 1;
      return;
    }
    final decrypted = await crypto.decryptBody(WireDoc(
      id: crypto.idFor(path),
      body: (doc['body'] as Map?)?.cast<String, Object?>() ?? doc,
      deleted: false,
    ));
    stdout.writeln('# $path  (mtime ${decrypted.header.mtime}, '
        'size ${decrypted.header.size}, inline ${decrypted.header.inline})');
    if (decrypted.inlineContent != null) {
      stdout.add(decrypted.inlineContent!);
    } else {
      stdout.writeln('[content rides as an encrypted attachment]');
    }
    return;
  }

  // Enumerate: decrypt every document's header, client-side (RV2).
  var since = '0';
  var count = 0;
  while (true) {
    final batch = await transport.changes(since: since, limit: 200);
    if (batch.rows.isEmpty) break;
    for (final row in batch.rows) {
      since = batch.lastSeq;
      if (row.id == 'meta') continue;
      if (row.deleted) {
        stdout.writeln('(deleted) ${row.id}');
        count++;
        continue;
      }
      final doc = await transport.getDoc(row.id);
      if (doc == null) continue;
      try {
        final decrypted = await crypto.decryptBody(WireDoc(
          id: row.id,
          body: (doc['body'] as Map?)?.cast<String, Object?>() ?? doc,
          deleted: false,
        ));
        stdout.writeln('${decrypted.header.path}  '
            '(${decrypted.header.size} B, inline ${decrypted.header.inline})');
      } on VaultCryptoException catch (e) {
        stdout.writeln('${row.id}: cannot decrypt (${e.message})');
      }
      count++;
    }
    since = batch.lastSeq;
    if (batch.rows.length < 200) break;
  }
  stdout.writeln('— $count documents');
}

// ---------------------------------------------------------------------------
// hist
// ---------------------------------------------------------------------------


Future<void> _hist(List<String> args) async {
  String? vaultId;
  String? stateRoot;
  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String? valueOf(String name) {
      if (arg == '--$name' && i + 1 < args.length) return args[++i];
      if (arg.startsWith('--$name=')) return arg.substring(name.length + 3);
      return null;
    }

    final v = valueOf('vault-id');
    if (v != null) {
      vaultId = v;
      continue;
    }
    final s = valueOf('state-root');
    if (s != null) {
      stateRoot = s;
      continue;
    }
    rest.add(arg);
  }
  stateRoot ??= _defaultStateRoot();
  if (rest.isEmpty || rest.first == '--help' || rest.first == '-h') {
    stdout.writeln('entropyd hist [--vault-id <id>] <command> [args]\n'
        'The history command line over a served vault — the same verbs as '
        '`hist`:\n');
    stdout.writeln(HistCli.usage);
    return;
  }

  final profile = await _loadOneProfile(stateRoot, vaultId);
  final cli = HistCli(out: stdout, err: stderr);
  exitCode = await cli.run(
    [
      ...rest,
      '--folder',
      profile.vaultRoot,
      '--writer',
      profile.effectiveWriterName,
      '--extensions',
      profile.histExtensions.join(','),
    ],
    cwd: profile.vaultRoot,
  );
  await stdout.flush();
}

// ---------------------------------------------------------------------------
// setup-uri
// ---------------------------------------------------------------------------

/// Emit the copyable setup-URI for a registered vault (`vault_daemon`
/// RV10, `vault_sync_control` D9): the non-secret connection (endpoint,
/// database, server credentials) encrypted under a transfer secret. The E2EE
/// passphrase is NEVER inside the URI — the receiving device asks for it
/// separately. Byte-compatible with the app's and the Obsidian plugin's
/// decoders (`SetupUri` / `setupUri.ts`).
Future<void> _setupUri(List<String> args) async {
  final parser = _base()
    ..addOption('vault-id', help: 'which vault')
    ..addOption(
      'transfer-secret',
      help: 'the secret that unlocks the URI (omit to generate one)',
    )
    ..addOption('endpoint', help: 'explicit connection: server endpoint')
    ..addOption('database', help: 'explicit connection: database name')
    ..addOption('server-user', help: 'explicit connection: server user')
    ..addOption('server-password', help: 'explicit connection: server password')
    ..addFlag('split',
        negatable: false,
        help: 'print the URI and its secret apart (two channels) instead of '
            'one pasteable string');
  final opts = parser.parse(args);
  if (opts.flag('help')) {
    stdout.writeln(
        'entropyd setup-uri [--vault-id <id>] [--transfer-secret <s>]\n'
        'entropyd setup-uri --endpoint <url> --database <db> '
        '--server-user <u> --server-password <pw> [--transfer-secret <s>]\n'
        '${parser.usage}');
    return;
  }

  // Two ways in: a registered vault, or a connection given explicitly — the
  // latter needs no daemon state at all, which is how a freshly provisioned
  // server hands the owner a pasteable string before any device exists (RV10).
  const explicitOptions = [
    'endpoint',
    'database',
    'server-user',
    'server-password',
  ];
  final given = explicitOptions.where((o) => opts.option(o) != null).toList();
  final String label;
  final String endpoint;
  final String database;
  final String serverUser;
  final String serverPassword;
  if (given.isEmpty) {
    final stateRoot = opts.option('state-root')!;
    final profile = await _loadOneProfile(stateRoot, opts.option('vault-id'));
    if (!profile.syncEnabled) {
      throw UsageException('vault "${profile.vaultId}" has no sync module — '
          'there is no connection to hand on');
    }
    label = 'vault "${profile.vaultId}"';
    endpoint = profile.endpoint;
    database = profile.database;
    serverUser = profile.serverUser;
    serverPassword = profile.serverPassword;
  } else if (given.length == explicitOptions.length) {
    label = '${opts.option('endpoint')} / ${opts.option('database')}';
    endpoint = opts.option('endpoint')!;
    database = opts.option('database')!;
    serverUser = opts.option('server-user')!;
    serverPassword = opts.option('server-password')!;
  } else {
    final missing = explicitOptions.where((o) => opts.option(o) == null);
    throw UsageException(
      'an explicit connection needs all of --endpoint, --database, '
      '--server-user, --server-password (missing: ${missing.join(', ')})',
    );
  }

  final secret = opts.option('transfer-secret') ?? _newTransferSecret();
  final cipher = await TransferCipher.derive(secret);
  final blob = await cipher.encryptText(jsonEncode({
    'endpoint': endpoint,
    'database': database,
    'serverUser': serverUser,
    'serverPassword': serverPassword,
  }));
  final uri = 'entropy-sync://setup#${base64Url.encode(utf8.encode(blob))}';
  final split = opts.flag('split');

  stdout.writeln('Setup-URI for $label:');
  // One string by default — the secret rides inside it (`vault_sync_control`
  // D9); `--split` keeps the two-channel form for whoever wants it.
  stdout.writeln('  ${split ? uri : '$uri~$secret'}');
  if (split) stdout.writeln('Transfer secret: $secret');
  stdout.writeln('Paste it on the new device; the E2EE passphrase is asked '
      'for there separately (it is not in the string).');
}

/// A readable one-time transfer secret: four groups of four characters from
/// an unambiguous lowercase alphabet (no 0/o, 1/l).
String _newTransferSecret() {
  const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
  final rng = Random.secure();
  String group() =>
      List.generate(4, (_) => alphabet[rng.nextInt(alphabet.length)]).join();
  return '${group()}-${group()}-${group()}-${group()}';
}

Future<VaultProfile> _loadOneProfile(String stateRoot, String? vaultId) async {
  final registry = VaultRegistry(stateRoot);
  final secrets = productionSecretStore(stateRoot);
  final profiles = await registry.loadProfiles(secrets);
  if (profiles.isEmpty) {
    throw UsageException('no vaults registered — run: entropyd init');
  }
  if (vaultId == null) {
    if (profiles.length == 1) return profiles.first;
    throw UsageException('several vaults registered — pass --vault-id '
        '(${profiles.map((e) => e.vaultId).join(', ')})');
  }
  return profiles.firstWhere(
    (e) => e.vaultId == vaultId,
    orElse: () => throw UsageException('unknown vault id: $vaultId'),
  );
}

String _newToken() {
  final rng = Random.secure();
  return List.generate(32, (_) => rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

// --- hub (`vault_sync_hub`) ---------------------------------------------------
//
// The server half, headless: everything the console can do to a hub is here,
// so a hub can be provisioned and granted from a script or over SSH from
// another machine. Authentication is the system SSH client's business — this
// binary never holds a key (C1).

Future<void> _hub(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    stdout.writeln(_hubUsage);
    return;
  }
  final group = args.first;
  final rest = args.sublist(1);
  switch (group) {
    case 'add':
      await _hubAdd(rest);
    case 'list':
      await _hubList(rest);
    case 'remove':
      await _hubRemove(rest);
    case 'provision':
      await _hubProvision(rest);
    case 'db':
      await _hubDb(rest);
    case 'grant':
      await _hubGrant(rest);
    default:
      throw UsageException('unknown hub command: $group\n$_hubUsage');
  }
}

ArgParser _hubParser() => _base()
  ..addOption('label', help: 'the hub\'s name')
  ..addOption('ssh', help: 'SSH target, e.g. root@203.0.113.10')
  ..addOption('domain', help: 'hostname whose DNS points at the hub')
  ..addOption('email', help: 'address for the TLS certificate')
  ..addOption('db', help: 'database on the hub')
  ..addOption('name', help: 'label for a device grant')
  ..addOption('user', help: 'the grant\'s CouchDB user')
  ..addFlag('yes', negatable: false, help: 'confirm a destructive action');

/// The hub named by `--label`, or the only one recorded.
({HubService service, HubRecord hub}) _hubFor(ArgResults opts) {
  final registry = HubRegistry(opts.option('state-root')!);
  final label = opts.option('label');
  final hubs = registry.all();
  if (hubs.isEmpty) {
    throw UsageException('no hubs recorded — run: entropyd hub add');
  }
  final HubRecord hub;
  if (label == null) {
    if (hubs.length > 1) {
      throw UsageException(
        '--label is required (recorded: ${hubs.map((h) => h.label).join(', ')})',
      );
    }
    hub = hubs.single;
  } else {
    hub =
        registry.find(label) ?? (throw UsageException('no hub named "$label"'));
  }
  return (service: HubService(registry: registry), hub: hub);
}

Future<void> _hubAdd(List<String> args) async {
  final parser = _hubParser();
  final opts = parser.parse(args);
  for (final required in ['label', 'ssh', 'domain', 'email']) {
    if (opts.option(required) == null) {
      throw UsageException('--$required is required\n${parser.usage}');
    }
  }
  final registry = HubRegistry(opts.option('state-root')!);
  registry.upsert(HubRecord(
    label: opts.option('label')!,
    sshTarget: opts.option('ssh')!,
    domain: opts.option('domain')!,
    acmeEmail: opts.option('email')!,
  ));
  stdout.writeln('hub "${opts.option('label')}" recorded '
      '(${opts.option('ssh')} → https://${opts.option('domain')}).');
  stdout.writeln('Nothing secret was stored: SSH uses your agent or '
      '~/.ssh/config. Next: entropyd hub provision '
      '--label ${opts.option('label')}');
}

Future<void> _hubList(List<String> args) async {
  final opts = _hubParser().parse(args);
  final hubs = HubRegistry(opts.option('state-root')!).all();
  if (hubs.isEmpty) {
    stdout.writeln('no hubs recorded');
    return;
  }
  for (final h in hubs) {
    stdout.writeln('${h.label}\t${h.sshTarget}\t${h.endpoint}');
  }
}

Future<void> _hubRemove(List<String> args) async {
  final opts = _hubParser().parse(args);
  final label =
      opts.option('label') ?? (throw UsageException('--label is required'));
  HubRegistry(opts.option('state-root')!).remove(label);
  stdout.writeln('hub "$label" forgotten locally. The server itself is '
      'untouched — nothing was deleted on it.');
}

Future<void> _hubProvision(List<String> args) async {
  final opts = _hubParser().parse(args);
  final target = _hubFor(opts);
  stdout.writeln('provisioning ${target.hub.label} '
      '(${target.hub.sshTarget})…');
  await target.service.provision(target.hub);
  stdout.writeln('hub "${target.hub.label}" is ready at '
      '${target.hub.endpoint}.');
  stdout.writeln('Next: entropyd hub db create --label '
      '${target.hub.label} --db <name>');
}

Future<void> _hubDb(List<String> args) async {
  if (args.isEmpty) throw UsageException(_hubUsage);
  final action = args.first;
  final opts = _hubParser().parse(args.sublist(1));
  final target = _hubFor(opts);
  switch (action) {
    case 'list':
      final dbs = await target.service.listDatabases(target.hub);
      if (dbs.isEmpty) {
        stdout.writeln('no vault databases on ${target.hub.label} yet');
      }
      for (final db in dbs) {
        stdout.writeln(db);
      }
    case 'create':
      final db =
          opts.option('db') ?? (throw UsageException('--db is required'));
      await target.service.createDatabase(target.hub, db);
      stdout.writeln('database "$db" created on ${target.hub.label}.');
      stdout.writeln('Next: entropyd hub grant create --label '
          '${target.hub.label} --db $db --name "<this device>"');
    case 'delete':
      final db =
          opts.option('db') ?? (throw UsageException('--db is required'));
      await target.service
          .deleteDatabase(target.hub, db, confirm: opts.flag('yes'));
      stdout.writeln('database "$db" and its grants are gone.');
    default:
      throw UsageException('unknown hub db command: $action\n$_hubUsage');
  }
}

Future<void> _hubGrant(List<String> args) async {
  if (args.isEmpty) throw UsageException(_hubUsage);
  final action = args.first;
  final opts = _hubParser().parse(args.sublist(1));
  final target = _hubFor(opts);
  final db = opts.option('db') ?? (throw UsageException('--db is required'));
  switch (action) {
    case 'list':
      final grants = await target.service.listGrants(target.hub, db);
      if (grants.isEmpty) stdout.writeln('no devices have access to "$db"');
      for (final g in grants) {
        stdout.writeln('${g.user}\t${g.label}');
      }
    case 'create':
      final name = opts.option('name') ??
          (throw UsageException('--name is required (what to call the '
              'device, e.g. "рабочий мак")'));
      final issued = await target.service.createGrant(target.hub, db, name);
      stdout.writeln('Setup-URI for "$name" (${target.hub.endpoint} / $db):');
      stdout.writeln('  ${issued.combined}');
      stdout.writeln('Paste it on that device; the E2EE passphrase is asked '
          'for there separately (it is not in the string, and the hub never '
          'learns it).');
      stdout.writeln('This string cannot be shown again — the password is not '
          'recoverable. If it is lost, revoke "${issued.grant.user}" and '
          'create another grant.');
    case 'revoke':
      final user =
          opts.option('user') ?? (throw UsageException('--user is required'));
      await target.service.revokeGrant(target.hub, db, user);
      stdout.writeln('"$user" can no longer reach "$db". Every other device '
          'keeps syncing unchanged.');
    default:
      throw UsageException('unknown hub grant command: $action\n$_hubUsage');
  }
}

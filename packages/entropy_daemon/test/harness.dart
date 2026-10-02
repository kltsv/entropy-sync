/// Shared scaffolding for the `vault_daemon` test-spec suite: a Couch
/// emulator per test, production-wired shells with the observation seams the
/// test-spec needs (recorded notifications, a counting hasher, deterministic
/// trash into the vault's state directory), and small helpers for history
/// files, server-side seeding, and plaintext-leak scans.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:entropy_hist/entropy_hist.dart';
import 'package:entropy_sync/entropy_sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;

const defaultPassphrase = 'correct horse battery staple';

String sha256Of(List<int> bytes) => c.sha256.convert(bytes).toString();
String sha256OfText(String text) => sha256Of(utf8.encode(text));

/// One vault served by a (test) daemon: its folder, its state root, its
/// production-wired [VaultShell], and the observation hooks.
class VaultHandle {
  VaultHandle(this.name, this.stateRoot, this.vaultRoot);

  final String name;
  final String stateRoot;
  final String vaultRoot;

  VaultShell? _shell;
  VaultShell get shell => _shell!;
  set shell(VaultShell value) => _shell = value;

  /// Every OS notification the shell emitted, as `title|message`.
  final List<String> notifications = [];

  /// How many times file/content bytes were hashed by the shell.
  int hashes = 0;

  /// The per-vault state directory (`<stateRoot>/data/<vaultId>`).
  String get stateDir => p.join(stateRoot, 'data', name);

  /// Where the injected trash function moves remotely-deleted files.
  String get trashDir => p.join(stateDir, 'trash');

  File file(String rel) => File(p.join(vaultRoot, rel));

  void write(String rel, String content) {
    final f = file(rel);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  void writeBytes(String rel, List<int> bytes) {
    final f = file(rel);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
  }

  String docId(String path) => shell.crypto.idFor(path);

  Directory histDir(String path) =>
      Directory(p.joinAll([vaultRoot, '.hist', ...path.split('/')]));

  /// Parsed headers + raw bytes of every version file under
  /// `.hist/<path>/`, sorted by filename (the plain-file read the
  /// test-spec prescribes).
  List<(HistFileHeader, Uint8List)> histFiles(String path) {
    final dir = histDir(path);
    if (!dir.existsSync()) return const [];
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final out = <(HistFileHeader, Uint8List)>[];
    for (final f in files) {
      final bytes = f.readAsBytesSync();
      final header = HistFileHeader.tryParse(p.basename(f.path), bytes);
      if (header != null) out.add((header, bytes));
    }
    return out;
  }

  List<HistFileHeader> histHeaders(String path) =>
      [for (final (h, _) in histFiles(path)) h];

  /// Version hashes recorded for [path] (snapshot + patch files).
  Set<String> recordedVersions(String path) => {
        for (final h in histHeaders(path))
          if ((h.type == HistFileType.snapshot ||
                  h.type == HistFileType.patch) &&
              h.version != null)
            h.version!,
      };

  /// Every file currently in the vault folder, vault-relative.
  List<String> vaultPaths() {
    final root = Directory(vaultRoot);
    if (!root.existsSync()) return const [];
    return [
      for (final e in root.listSync(recursive: true, followLinks: false))
        if (e is File)
          p.posix.joinAll(p.split(p.relative(e.path, from: vaultRoot))),
    ];
  }
}

class Harness {
  Harness._(this.tmp, this.emulator);

  final Directory tmp;
  final CouchEmulator emulator;
  final Map<String, VaultHandle> handles = {};

  static Future<Harness> start() async {
    final tmp = Directory.systemTemp.createTempSync('entropyd-spec');
    final emulator = CouchEmulator(username: 'u', password: 'pw');
    await emulator.start();
    return Harness._(tmp, emulator);
  }

  Future<void> stop() async {
    await emulator.stop();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }

  String get endpoint => 'http://127.0.0.1:${emulator.port}';

  LocalStore serverStore([String database = 'vault']) =>
      emulator.db(database).store;

  /// The handle for a named vault, with its folders created (no shell yet).
  VaultHandle handleFor(String name) => handles.putIfAbsent(name, () {
        final vaultRoot = p.join(tmp.path, name, 'vault');
        final stateRoot = p.join(tmp.path, name, 'state');
        Directory(vaultRoot).createSync(recursive: true);
        return VaultHandle(name, stateRoot, vaultRoot);
      });

  VaultProfile profileFor(
    VaultHandle handle, {
    String database = 'vault',
    String passphrase = defaultPassphrase,
    List<String> exclusions = VaultProfile.defaultExclusions,
    int inlineThresholdBytes = 1024 * 1024,
    int watchDebounceMillis = 1500,
    Set<VaultModule> modules = VaultProfile.allModules,
  }) =>
      VaultProfile(
        vaultId: handle.name,
        vaultRoot: handle.vaultRoot,
        modules: modules,
        endpoint: modules.contains(VaultModule.sync) ? endpoint : '',
        database: modules.contains(VaultModule.sync) ? database : '',
        serverUser: modules.contains(VaultModule.sync) ? 'u' : '',
        serverPassword: modules.contains(VaultModule.sync) ? 'pw' : '',
        passphrase: modules.contains(VaultModule.sync) ? passphrase : '',
        writerName: handle.name,
        exclusions: exclusions,
        histIdleMillis: 0,
        inlineThresholdBytes: inlineThresholdBytes,
        watchDebounceMillis: watchDebounceMillis,
      );

  /// The production shell wiring plus the test-spec observation seams.
  /// [histStore] rigs history's storage (a failing store isolates the
  /// module, `daemon-modules` R3).
  Future<VaultShell> buildShell(
    VaultHandle handle,
    VaultProfile profile, {
    DaemonLog? log,
    HistStore Function(String vaultRoot)? histStore,
  }) =>
      productionShell(
        profile,
        stateRoot: handle.stateRoot,
        log: log,
        notifier: (title, message) async =>
            handle.notifications.add('$title|$message'),
        trash: (file, {required String fallbackDir}) async =>
            _moveInto(file, fallbackDir),
        hasher: (bytes) {
          handle.hashes += 1;
          return sha256Of(bytes);
        },
        histStore: histStore,
      );

  /// A [Daemon] shell factory: production wiring through [buildShell], with
  /// the built shell recorded on the vault's handle for assertions.
  Future<VaultShell> daemonShell(VaultProfile profile) async {
    final handle = handleFor(profile.vaultId);
    final shell = await buildShell(handle, profile);
    handle.shell = shell;
    return shell;
  }

  /// Create (or re-create — a daemon restart) a vault's shell. Dirs and
  /// persisted state under the same name are reused.
  Future<VaultHandle> spawn(
    String name, {
    String database = 'vault',
    String passphrase = defaultPassphrase,
    List<String> exclusions = VaultProfile.defaultExclusions,
    int inlineThresholdBytes = 1024 * 1024,
    Set<VaultModule> modules = VaultProfile.allModules,
    HistStore Function(String vaultRoot)? histStore,
    DaemonLog? log,
  }) async {
    final handle = handleFor(name);
    handle.shell = await buildShell(
      handle,
      profileFor(handle,
          database: database,
          passphrase: passphrase,
          exclusions: exclusions,
          inlineThresholdBytes: inlineThresholdBytes,
          modules: modules),
      log: log,
      histStore: histStore,
    );
    return handle;
  }

  static String _moveInto(File file, String dir) {
    Directory(dir).createSync(recursive: true);
    var target = p.join(dir, p.basename(file.path));
    var n = 1;
    while (File(target).existsSync()) {
      target = p.join(dir,
          '${p.basenameWithoutExtension(file.path)}-$n${p.extension(file.path)}');
      n += 1;
    }
    file.renameSync(target);
    return target;
  }

  /// Seed a document revision **server-side** — "another device" pushed it.
  /// Uses [via]'s crypto so the ciphertext is decryptable by the vault under
  /// test; the plain MVCC put mints a child of the server's current winner.
  Future<String> seedServerDoc(
    VaultHandle via,
    String path,
    List<int> bytes, {
    int? mtime,
    String database = 'vault',
  }) async {
    final enc = await via.shell.crypto.encrypt(LogicalDoc(
      path: path,
      bytes: Uint8List.fromList(bytes),
      mtime: mtime ?? DateTime.now().millisecondsSinceEpoch,
    ));
    final db = emulator.db(database);
    await db.store.put(enc.wire.id, enc.wire.body!);
    db.touch();
    return enc.wire.id;
  }

  /// Delete a document server-side — "another device" deleted the file.
  Future<void> deleteServerDoc(
    VaultHandle via,
    String path, {
    String database = 'vault',
  }) async {
    final db = emulator.db(database);
    await db.store.delete(via.docId(path));
    db.touch();
  }

  /// Decrypt the server's winning revision of [path] as UTF-8 text.
  Future<String> decryptServerText(
    VaultHandle via,
    String path, {
    String database = 'vault',
  }) async =>
      utf8.decode(await decryptServerBytes(via, path, database: database));

  Future<Uint8List> decryptServerBytes(
    VaultHandle via,
    String path, {
    String database = 'vault',
  }) async {
    final doc = serverStore(database).get(via.docId(path));
    if (doc == null || doc.deleted) {
      throw StateError('no live server doc for $path');
    }
    final decrypted = await via.shell.crypto
        .decryptBody(WireDoc(id: doc.id, body: doc.body, deleted: false));
    return decrypted.inlineContent!;
  }

  /// Every server-stored id and body serialized to one string — the raw
  /// material for "the marker appears nowhere on the server" assertions.
  String serverRawJson([String database = 'vault']) {
    final store = serverStore(database);
    return jsonEncode({
      for (final id in store.allDocIds) id: store.get(id)?.body,
    });
  }

  /// Alternate reconcile passes across daemons until quiescent enough.
  Future<void> settle(List<VaultHandle> daemons, {int rounds = 3}) async {
    for (var i = 0; i < rounds; i++) {
      for (final d in daemons) {
        await d.shell.reconcile();
      }
    }
  }
}

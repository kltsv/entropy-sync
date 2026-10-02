import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:entropy_sync/entropy_sync.dart';
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Integration against a REAL Apache CouchDB 3.x (`vault_sync` §11, PLAN
/// stage-1 acceptance): the emulator-backed suites prove client⇄emulator
/// agreement; this file proves client⇄CouchDB agreement — protocol shapes,
/// multipart attachments, longpoll, conflicts — on a live server.
///
/// Skipped unless a server is provided:
///
///   REAL_COUCH_URL=http://127.0.0.1:5984 \
///   REAL_COUCH_USER=admin REAL_COUCH_PASSWORD=devpw \
///   dart test test/real_couch_test.dart
///
/// (e.g. `podman run -d -p 127.0.0.1:5984:5984 -e COUCHDB_USER=admin
/// -e COUCHDB_PASSWORD=devpw couchdb:3`.) Each run uses fresh database names
/// and deletes them afterwards.
void main() {
  final url = Platform.environment['REAL_COUCH_URL'];
  final user = Platform.environment['REAL_COUCH_USER'] ?? 'admin';
  final password = Platform.environment['REAL_COUCH_PASSWORD'] ?? '';

  if (url == null) {
    test('real CouchDB integration', () {}, skip: 'REAL_COUCH_URL not set');
    return;
  }

  late Directory tmp;
  late String dbName;

  String freshDbName() => 'entropy_it_${DateTime.now().millisecondsSinceEpoch}_'
      '${Random().nextInt(0xffff)}';

  Future<void> deleteDb(String name) async {
    final client = HttpClient();
    try {
      final req = await client.deleteUrl(Uri.parse('$url/$name'));
      req.headers.set('authorization',
          'Basic ${base64.encode(utf8.encode('$user:$password'))}');
      await (await req.close()).drain<void>();
    } finally {
      client.close();
    }
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('entropy-real-couch');
    dbName = freshDbName();
  });

  tearDown(() async {
    await deleteDb(dbName);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  VaultProfile profileFor(String name, String vaultDir) => VaultProfile(
        vaultId: name,
        vaultRoot: vaultDir,
        endpoint: url,
        database: dbName,
        serverUser: user,
        serverPassword: password,
        passphrase: 'integration passphrase',
        writerName: name,
        histIdleMillis: 0,
      );

  Future<VaultShell> shellFor(String name) async {
    final vaultDir = Directory(p.join(tmp.path, name, 'vault'))
      ..createSync(recursive: true);
    return productionShell(
      profileFor(name, vaultDir.path),
      stateRoot: p.join(tmp.path, name, 'state'),
    );
  }

  test('two devices converge through a real CouchDB with E2EE + history',
      () async {
    final a = await shellFor('mac');

    File(p.join(a.vaultRoot, 'notes', 'todo.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('# Todo\n- buy milk\n');
    await a.reconcile();
    expect(a.lastError, isNull);
    expect(a.unsynced, 0);

    final b = await shellFor('phone');
    await b.reconcile();
    expect(b.lastError, isNull);
    expect(
      File(p.join(b.vaultRoot, 'notes', 'todo.md')).readAsStringSync(),
      '# Todo\n- buy milk\n',
    );

    // Edit on B → A; history files ride along.
    File(p.join(b.vaultRoot, 'notes', 'todo.md'))
        .writeAsStringSync('# Todo\n- buy milk\n- call mom\n');
    await b.reconcile();
    await b.reconcile(); // flush history files, sync them
    await a.reconcile();
    expect(
      File(p.join(a.vaultRoot, 'notes', 'todo.md')).readAsStringSync(),
      contains('call mom'),
    );
    expect(
      Directory(p.join(a.vaultRoot, '.hist', 'notes', 'todo.md')).existsSync(),
      isTrue,
      reason: 'history syncs end-to-end through the real server (RV8)',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a large binary rides as a streamed multipart attachment', () async {
    final a = await shellFor('mac');
    // > 1 MiB → inline threshold exceeded → STREAM attachment (RV2).
    final bytes = List<int>.generate(3 * 1024 * 1024, (i) => (i * 31) & 0xff);
    File(p.join(a.vaultRoot, 'img', 'scan.bin'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    await a.reconcile();
    expect(a.lastError, isNull);
    expect(a.unsynced, 0);

    final b = await shellFor('phone');
    await b.reconcile();
    final received = File(p.join(b.vaultRoot, 'img', 'scan.bin'));
    expect(received.existsSync(), isTrue);
    expect(received.lengthSync(), bytes.length);
    expect(received.readAsBytesSync(), bytes);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('concurrent edits conflict and resolve identically on both devices',
      () async {
    final a = await shellFor('mac');
    final b = await shellFor('desk');

    File(p.join(a.vaultRoot, 'plan.md')).writeAsStringSync('base\n');
    await a.reconcile();
    await b.reconcile();

    File(p.join(a.vaultRoot, 'plan.md')).writeAsStringSync('base\nfrom A\n');
    File(p.join(b.vaultRoot, 'plan.md')).writeAsStringSync('base\nfrom B\n');
    await a.reconcile();
    await b.reconcile();
    await a.reconcile();
    await b.reconcile();
    await a.reconcile();

    final onA = File(p.join(a.vaultRoot, 'plan.md')).readAsStringSync();
    final onB = File(p.join(b.vaultRoot, 'plan.md')).readAsStringSync();
    expect(onA, onB);
    expect(['base\nfrom A\n', 'base\nfrom B\n'], contains(onA));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('wrong passphrase is refused against the real meta document', () async {
    final a = await shellFor('mac');
    File(p.join(a.vaultRoot, 'a.md')).writeAsStringSync('secret');
    await a.reconcile();

    final vaultDir = Directory(p.join(tmp.path, 'thief', 'vault'))
      ..createSync(recursive: true);
    await expectLater(
      productionShell(
        profileFor('thief', vaultDir.path).copyWith(passphrase: 'wrong'),
        stateRoot: p.join(tmp.path, 'thief', 'state'),
      ),
      throwsA(isA<VaultCryptoException>()),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('continuous longpoll delivers a remote change within seconds', () async {
    final a = await shellFor('mac');
    final b = await shellFor('phone');
    File(p.join(a.vaultRoot, 'live.md')).writeAsStringSync('v1');
    await a.reconcile();
    await b.reconcile();

    await b.start();
    try {
      File(p.join(a.vaultRoot, 'live.md')).writeAsStringSync('v2');
      await a.reconcile();
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        if (File(p.join(b.vaultRoot, 'live.md')).readAsStringSync() == 'v2') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      expect(
        File(p.join(b.vaultRoot, 'live.md')).readAsStringSync(),
        'v2',
        reason: 'longpoll materializes the change without a manual reconcile',
      );
    } finally {
      await b.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

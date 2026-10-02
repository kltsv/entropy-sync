import 'dart:convert';
import 'dart:io';

import 'package:entropy_sync/entropy_sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// End-to-end smoke over the full production wiring (`vault_daemon` RV1):
/// two daemons ("two machines"), each with its own vault folder and state,
/// against ONE emulated CouchDB database over real HTTP — E2EE meta flow,
/// first-scan initial sync, cross-device propagation, deletion to trash
/// fallback, multi-writer history, and ciphertext-only server content.
void main() {
  late Directory tmp;
  late CouchEmulator emulator;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('entropy-e2e');
    emulator = CouchEmulator(username: 'u', password: 'pw');
    await emulator.start();
  });

  tearDown(() async {
    await emulator.stop();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  VaultProfile profileFor(String name, String vaultDir) => VaultProfile(
        vaultId: name,
        vaultRoot: vaultDir,
        endpoint: 'http://127.0.0.1:${emulator.port}',
        database: 'vault',
        serverUser: 'u',
        serverPassword: 'pw',
        passphrase: 'correct horse battery staple',
        writerName: name,
        histIdleMillis: 0,
      );

  Future<VaultShell> shellFor(String name) async {
    final vaultDir = Directory(p.join(tmp.path, name, 'vault'))
      ..createSync(recursive: true);
    final stateRoot = p.join(tmp.path, name, 'state');
    return productionShell(
      profileFor(name, vaultDir.path),
      stateRoot: stateRoot,
    );
  }

  test('two devices converge end-to-end with E2EE and history', () async {
    final a = await shellFor('mac');

    // Device A: first scan is the initial sync (D5).
    File(p.join(a.vaultRoot, 'notes', 'todo.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('# Todo\n- buy milk\n');
    await a.reconcile();

    // The server holds only ciphertext: no path, no content in any doc.
    expect(emulator.requestLog, isNotEmpty);
    final serverStore = emulator.db('vault').store;
    expect(serverStore.allDocIds, contains('meta'));
    final nonMeta = serverStore.allDocIds.where((id) => id != 'meta');
    expect(nonMeta, isNotEmpty);
    for (final id in nonMeta) {
      final raw = jsonEncode(serverStore.get(id)?.body ?? const {});
      expect(raw, isNot(contains('todo')));
      expect(raw, isNot(contains('buy milk')));
      expect(id, isNot(contains('todo')));
    }

    // Device B: attaches to the populated database with the same passphrase.
    final b = await shellFor('phone');
    await b.reconcile();
    final onB = File(p.join(b.vaultRoot, 'notes', 'todo.md'));
    expect(onB.existsSync(), isTrue);
    expect(onB.readAsStringSync(), '# Todo\n- buy milk\n');

    // B edits; A receives; B's history for its own edit rides along encrypted.
    onB.writeAsStringSync('# Todo\n- buy milk\n- call mom\n');
    await b.reconcile(); // ingest + push (history idle 0 → version cut)
    await b.reconcile(); // flush history files into the vault → next scan syncs
    await a.reconcile();
    expect(
      File(p.join(a.vaultRoot, 'notes', 'todo.md')).readAsStringSync(),
      contains('call mom'),
    );

    // History: B recorded its own edit; the files sync to A as plain files.
    final histOnB = Directory(p.join(b.vaultRoot, '.hist', 'notes', 'todo.md'));
    expect(histOnB.existsSync(), isTrue,
        reason: 'B records its own edit (RV6)');
    await b.reconcile();
    await a.reconcile();
    final histOnA = Directory(p.join(a.vaultRoot, '.hist', 'notes', 'todo.md'));
    expect(histOnA.existsSync(), isTrue,
        reason: '.hist/ syncs end-to-end (RV8)');

    // A deletes; B's copy goes to the trash fallback, not oblivion.
    File(p.join(a.vaultRoot, 'notes', 'todo.md')).deleteSync();
    await a.reconcile();
    await b.reconcile();
    expect(
      File(p.join(b.vaultRoot, 'notes', 'todo.md')).existsSync(),
      isFalse,
    );

    // Un-synced counts settle to zero on both.
    expect(a.unsynced, 0);
    expect(b.unsynced, 0);
  });

  test('wrong passphrase on the second device is refused before sync (RV3)',
      () async {
    final a = await shellFor('mac');
    File(p.join(a.vaultRoot, 'a.md')).writeAsStringSync('secret');
    await a.reconcile();

    final vaultDir = Directory(p.join(tmp.path, 'thief', 'vault'))
      ..createSync(recursive: true);
    final bad = profileFor('thief', vaultDir.path)
        .copyWith(passphrase: 'wrong passphrase');
    await expectLater(
      productionShell(bad, stateRoot: p.join(tmp.path, 'thief', 'state')),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('concurrent edits resolve deterministically; loser is not lost',
      () async {
    final a = await shellFor('mac');
    final b = await shellFor('desk');

    File(p.join(a.vaultRoot, 'plan.md')).writeAsStringSync('base\n');
    await a.reconcile();
    await b.reconcile();
    expect(File(p.join(b.vaultRoot, 'plan.md')).existsSync(), isTrue);

    // Both edit from the same base without syncing.
    File(p.join(a.vaultRoot, 'plan.md')).writeAsStringSync('base\nfrom A\n');
    File(p.join(b.vaultRoot, 'plan.md')).writeAsStringSync('base\nfrom B\n');
    await a.reconcile();
    await b.reconcile();
    await a.reconcile();
    await b.reconcile();
    await a.reconcile();

    final onA = File(p.join(a.vaultRoot, 'plan.md')).readAsStringSync();
    final onB = File(p.join(b.vaultRoot, 'plan.md')).readAsStringSync();
    expect(onA, onB, reason: 'both replicas agree on the LWW winner');
    expect(['base\nfrom A\n', 'base\nfrom B\n'], contains(onA));

    // No .conflict files in either vault.
    for (final root in [a.vaultRoot, b.vaultRoot]) {
      final stray = Directory(root)
          .listSync(recursive: true)
          .where((e) => e.path.contains('.conflict'))
          .where((e) => !e.path.contains('.hist'));
      expect(stray, isEmpty);
    }
  });
}

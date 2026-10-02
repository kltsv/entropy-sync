/// `vault_sync` test-spec — "Offline-first and the engine" (R3, R4, RV4),
/// plus the spec-default timing knobs asserted separately.
library;

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('offline-first and the engine (R3, R4, RV4)', () {
    test(
        'a week-long divergence converges by transferring only missing '
        'revisions, both ways (S1)', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault');
      final a = makeReplica(emulator, replicaId: 'A');
      final b = makeReplica(emulator, replicaId: 'B');
      addTearDown(() async {
        await a.dispose();
        await b.dispose();
        await emulator.stop();
      });

      // Synced on a 50-document set.
      for (var i = 0; i < 50; i++) {
        await a.store.put('doc-$i', {'i': i});
      }
      await a.engine.syncNow();
      await b.engine.syncNow();
      expect(b.store.allDocIds, hasLength(50));

      // Connectivity cut — offline, disjoint edits.
      final aEdited = [for (var i = 0; i < 10; i++) 'doc-$i'];
      for (final id in aEdited) {
        await a.store.put(id, {'edited-by': 'A', 'id': id});
      }
      await a.store.put('doc-0', {'edited-by': 'A', 'again': 1});
      await a.store.put('doc-0', {'edited-by': 'A', 'again': 2});
      await a.store.put('new-1', {'created-by': 'A'});
      await a.store.put('new-2', {'created-by': 'A'});
      final bEdited = [for (var i = 10; i < 15; i++) 'doc-$i'];
      for (final id in bEdited) {
        await b.store.put(id, {'edited-by': 'B', 'id': id});
      }
      await b.store.delete('doc-49');

      // Reconnect.
      emulator.clearLog();
      await a.engine.syncNow();
      await b.engine.syncNow();
      await a.engine.syncNow();

      // Convergence: identical document set — every edit, creation, and
      // deletion present on both.
      final ids = {...a.store.allDocIds, ...b.store.allDocIds};
      expect(ids, hasLength(52));
      for (final id in ids) {
        final docA = a.store.get(id)!;
        final docB = b.store.get(id)!;
        expect(docA.rev, docB.rev, reason: 'winner of $id');
        expect(docA.body, docB.body, reason: 'body of $id');
        expect(docA.deleted, docB.deleted);
      }
      expect(a.store.get('doc-49')!.deleted, isTrue);
      expect(a.store.get('new-1'), isNotNull);
      // The edits were disjoint — no conflict is reported.
      expect(a.store.conflicts(), isEmpty);
      expect(b.store.conflicts(), isEmpty);
      expect(a.conflicts, isEmpty);
      expect(b.conflicts, isEmpty);

      // Wire economy: only revisions absent from the receiving side crossed.
      // A pushed 12 (10 edited + 2 created), B pushed 6 (5 edits +
      // 1 tombstone); each pulled the other's — and nothing else.
      final pushedIds = <String>[];
      for (final req in logFor(emulator, '_bulk_docs')) {
        for (final doc in ((req.jsonBody as Map)['docs'] as List)) {
          pushedIds.add((doc as Map)['_id'] as String);
        }
      }
      final pulledIds = <String>[];
      for (final req in logFor(emulator, '_bulk_get')) {
        for (final doc in ((req.jsonBody as Map)['docs'] as List)) {
          pulledIds.add((doc as Map)['id'] as String);
        }
      }
      final touched = {...aEdited, ...bEdited, 'new-1', 'new-2', 'doc-49'};
      expect(pushedIds, hasLength(18)); // 12 + 6 bodies pushed
      expect(pulledIds, hasLength(18)); // 12 + 6 bodies pulled
      expect(pushedIds.toSet(), touched);
      expect(pulledIds.toSet(), touched);
      // The 34 untouched documents never crossed in either direction.
      final untouched = ids.difference(touched);
      expect(untouched.intersection(pushedIds.toSet()), isEmpty);
      expect(untouched.intersection(pulledIds.toSet()), isEmpty);
    });

    test('the status stream reports {online, pendingPush, lastSeq, error}',
        () async {
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault');
      final port = emulator.port;
      await emulator.stop(); // the server starts unreachable

      final r = makeReplica(emulator,
          replicaId: 'R',
          backoffBase: const Duration(milliseconds: 50),
          backoffCap: const Duration(milliseconds: 300),
          longpollTimeoutMs: 150);
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });

      await r.store.put('s1', {'v': 1});
      await r.store.put('s2', {'v': 2});
      await r.engine.start();

      // Cut off: online: false with pendingPush: 2 and the error populated.
      await waitUntil(
          () => r.statuses
              .any((s) => !s.online && s.pendingPush == 2 && s.error != null),
          reason: 'offline status with pendingPush 2');
      final offlineAt = r.statuses.indexWhere(
          (s) => !s.online && s.pendingPush == 2 && s.error != null);
      expect(r.statuses[offlineAt].error, contains('unreachable'));

      // Restore connectivity (same port, same databases).
      await emulator.start(port: port);
      await waitUntil(
          () => r.statuses
              .any((s) => s.online && s.pendingPush == 0 && s.lastSeq != '0'),
          reason: 'recovered status');
      final recoveredAt = r.statuses.indexWhere(
          (s) => s.online && s.pendingPush == 0 && s.lastSeq != '0');
      expect(recoveredAt, greaterThan(offlineAt));

      // Rig 401 Unauthorized: error carries the auth failure, online flips.
      // The already-parked longpoll passed its auth check when it was
      // received — wake it with a change so the loop issues fresh requests
      // that hit the 401.
      emulator.forceUnauthorized = true;
      final server = emulator.db('vault');
      await server.store.put('wake', {'v': 1});
      server.touch();
      await waitUntil(
          () => r.statuses
              .any((s) => !s.online && (s.error ?? '').startsWith('auth')),
          reason: 'auth failure status');
      final authAt = r.statuses
          .indexWhere((s) => !s.online && (s.error ?? '').startsWith('auth'));
      expect(authAt, greaterThan(recoveredAt));
      await r.engine.stop();
    });
  });

  group('spec-default timing knobs (RV4)', () {
    test('the engine defaults match the spec; timing is configurable',
        () async {
      final store = LocalStore();
      final engine = SyncEngine(
        store: store,
        transport: CouchTransport(
          baseUrl: Uri.parse('http://127.0.0.1:1'),
          database: 'unused',
        ),
        replicaId: 'defaults',
      );
      expect(engine.pushDebounce, const Duration(seconds: 2)); // ~2 s debounce
      expect(engine.backoffBase, const Duration(seconds: 1));
      expect(engine.backoffCap, const Duration(seconds: 60));
      expect(engine.heartbeatMs, 30000); // heartbeat=30000
      expect(engine.batchLimit, 200); // limit=200
      expect(store.revsLimit, 1000); // default mirrors CouchDB's default
    });
  });
}

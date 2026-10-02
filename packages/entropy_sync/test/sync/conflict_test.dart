/// `vault_sync` test-spec — "Conflicts and resolution" (R9).
library;

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('conflicts and resolution (R9)', () {
    /// Shared arrangement: document `d` conflicted between winner `4-w`
    /// (body only) and loser `4-l` with body and attachment.
    final winnerRev = '4-${hx('f')}'; // greater hash — the winner
    final loserRev = '4-${hx('a')}';
    final shared = ['3-${hx('1')}', '2-${hx('2')}', '1-${hx('3')}'];
    final loserBytes = List<int>.generate(2048, (i) => (i * 3) % 256);

    Future<AttachmentRef> graftConflict(LocalStore store) async {
      final handle = await store.blobStore.put(byteStream(loserBytes));
      final ref = AttachmentRef(digest: handle.digest, length: handle.length);
      store.graft(rdoc('d', [loserRev, ...shared],
          body: {'side': 'loser'}, attachment: ref));
      store.graft(rdoc('d', [winnerRev, ...shared], body: {'side': 'winner'}));
      return ref;
    }

    test('a conflict event carries each loser\'s full content and attachment',
        () async {
      final store = LocalStore();
      final reports = <ConflictReport>[];
      store.onConflict(reports.add);
      final ref = await graftConflict(store);

      expect(reports, hasLength(1));
      final report = reports.single;
      expect(report.id, 'd');
      expect(report.winnerRev, winnerRev);
      final loser = report.losers.single;
      expect(loser.rev, loserRev);
      // The loser's body and attachment bytes are retrievable through the
      // event — nothing was purged.
      expect(loser.body, {'side': 'loser'});
      expect(loser.attachment!.digest, ref.digest);
      expect(
          await collectBytes(store.blobStore.openRead(ref.digest)), loserBytes);
      // The polled view agrees.
      expect(store.conflicts().single.losers.single.rev, loserRev);
    });

    test('resolve writes a deleted child on each named loser and pushes it',
        () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      final r = makeReplica(emulator, replicaId: 'R');
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });
      await graftConflict(server.store);
      await graftConflict(r.store);

      await r.engine.resolve('d', [loserRev]);
      await r.engine.syncNow();

      // The losing branch now ends in a deleted 5-<hash> child of 4-l.
      final tombstone =
          r.store.revsOf('d').firstWhere((rev) => revGeneration(rev) == 5);
      final tombstoneDoc = r.store.revisionedDoc('d', tombstone)!;
      expect(tombstoneDoc.deleted, isTrue);
      expect(tombstoneDoc.revisionIds[1], revHash(loserRev));
      // Exactly one live leaf — the winner, its content untouched (no merge).
      expect(r.store.conflicts(), isEmpty);
      expect(r.store.get('d')!.rev, winnerRev);
      expect(r.store.get('d')!.body, {'side': 'winner'});
      // The tombstone reached the server; it agrees on the single live leaf.
      expect(server.store.hasRevision('d', tombstone), isTrue);
      expect(server.store.conflicts(), isEmpty);
      expect(server.store.get('d')!.rev, winnerRev);
      expect(server.store.get('d')!.body, {'side': 'winner'});
    });

    test('resolving twice is harmless', () async {
      final store = LocalStore();
      await graftConflict(store);
      await store.resolveConflict('d', [loserRev]);
      final revsAfterFirst = store.revsOf('d').toSet();
      final pendingAfterFirst = store.pendingPushCount;
      var events = 0;
      store.onChange((_) => events++);

      // The named leaf is already deleted — a no-op.
      await store.resolveConflict('d', [loserRev]);

      expect(store.revsOf('d').toSet(), revsAfterFirst); // no new revision
      expect(store.pendingPushCount, pendingAfterFirst);
      expect(events, 0); // no event, no error
    });

    test('concurrent resolution from two replicas converges', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      await graftConflict(server.store);
      final a = makeReplica(emulator, replicaId: 'A');
      final b = makeReplica(emulator, replicaId: 'B');
      addTearDown(() async {
        await a.dispose();
        await b.dispose();
        await emulator.stop();
      });
      await a.engine.syncNow();
      await b.engine.syncNow();
      expect(a.store.conflicts(), hasLength(1));
      expect(b.store.conflicts(), hasLength(1));

      // Both resolve before either syncs.
      await a.engine.resolve('d', [loserRev]);
      await b.engine.resolve('d', [loserRev]);
      final conflictEventsA = a.conflicts.length;
      final conflictEventsB = b.conflicts.length;

      await a.engine.syncNow();
      await b.engine.syncNow();
      await a.engine.syncNow();
      await b.engine.syncNow();

      for (final store in [a.store, b.store, server.store]) {
        // The winner is the single live leaf; the two independently minted
        // tombstones coexist without resurrecting the loser.
        expect(store.get('d')!.rev, winnerRev);
        expect(store.conflicts(), isEmpty);
        final tombstones =
            store.revsOf('d').where((rev) => revGeneration(rev) == 5);
        expect(tombstones, hasLength(2));
      }
      // Deleted leaves are not conflicts — no new conflict events during the
      // tombstone exchange.
      expect(a.conflicts.length, conflictEventsA);
      expect(b.conflicts.length, conflictEventsB);
    });
  });
}

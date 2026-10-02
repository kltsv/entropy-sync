/// `vault_sync` test-spec — "Revision ids and the tree" (RV4).
library;

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('revision ids and the tree (RV4)', () {
    test(
        'a put mints revision N-<32 random lowercase hex> with parent '
        'linkage', () async {
      final store = LocalStore();
      final rev1 = await store.put('d', {'v': 1});
      final rev2 = await store.put('d', {'v': 2});

      expect(rev1, matches(RegExp(r'^1-[0-9a-f]{32}$')));
      expect(rev2, matches(RegExp(r'^2-[0-9a-f]{32}$')));
      expect(revHash(rev1), isNot(revHash(rev2)));
      // Parent linkage: rev2's transferred path lists rev1's hash next.
      final doc = store.revisionedDoc('d', rev2)!;
      expect(doc.revisionsStart, 2);
      expect(doc.revisionIds, [revHash(rev2), revHash(rev1)]);
    });

    test(
        'identical content on two replicas mints two distinct revisions — '
        'a same-content conflict with a picked winner', () async {
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

      final body = <String, Object?>{'same': 'content'};
      final revA = await a.store.put('d', body);
      final revB = await b.store.put('d', body);
      // The hash is random, not content-derived — nothing about content can
      // be inferred from a revision id.
      expect(revA, isNot(revB));
      expect(revGeneration(revA), 1);
      expect(revGeneration(revB), 1);

      await a.engine.syncNow();
      await b.engine.syncNow();
      await a.engine.syncNow();

      // Every store holds both leaves — never deduped by revision hashing.
      for (final store in [a.store, b.store, emulator.db('vault').store]) {
        expect(store.revsOf('d').toSet(), {revA, revB});
      }
      expect(a.conflicts, isNotEmpty);
      expect(b.conflicts, isNotEmpty);
      // Both replicas independently pick the same winner: the
      // lexicographically greater hash.
      final expected = revHash(revA).compareTo(revHash(revB)) > 0 ? revA : revB;
      expect(a.store.get('d')!.rev, expected);
      expect(b.store.get('d')!.rev, expected);
    });

    test('write dedup: a put identical to the current winner records nothing',
        () async {
      final store = LocalStore();
      final bytes = List<int>.generate(512, (i) => i % 256);
      await store.put('d', {'b': 1}, attachment: byteStream(bytes));
      final winner = store.get('d')!.rev;
      final pendingBefore = store.pendingPushCount;
      var events = 0;
      store.onChange((_) => events++);

      final rev = await store.put('d', {'b': 1}, attachment: byteStream(bytes));

      expect(rev, winner); // the winner and its rev are unchanged
      expect(store.get('d')!.rev, winner);
      expect(store.revsOf('d'), hasLength(1)); // no new revision exists
      expect(events, 0); // no change event
      expect(store.pendingPushCount, pendingBefore); // nothing queued
    });

    test('pulled revisions graft into the tree with new_edits=false semantics',
        () async {
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

      final rev1 = await a.store.put('d', {'v': 1});
      await a.engine.syncNow();
      await b.engine.syncNow(); // B synced up to 1-r
      expect(b.store.get('d')!.rev, rev1);

      final rev2 = await a.store.put('d', {'v': 2});
      await a.engine.syncNow();
      await b.engine.syncNow();

      // The exact revision id A minted, grafted via its transferred ancestor
      // path — not re-minted.
      expect(b.store.get('d')!.rev, rev2);
      expect(b.store.revsOf('d').toSet(), {rev1, rev2});
      final grafted = b.store.revisionedDoc('d', rev2)!;
      expect(grafted.revisionIds, [revHash(rev2), revHash(rev1)]);
      // A single leaf — fast-forward, no conflict.
      expect(b.store.changes(since: '0').single.leafRevs, [rev2]);
      expect(b.store.conflicts(), isEmpty);
    });

    test('re-grafting a known revision is a no-op', () async {
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

      await a.store.put('d', {'v': 1});
      final rev2 = await a.store.put('d', {'v': 2});
      await a.engine.syncNow();
      await b.engine.syncNow();
      final revsBefore = b.store.revsOf('d').toSet();
      final changesBefore = b.changes.length;

      // Wipe only B's pull checkpoint and pull again from sequence zero.
      b.store.setCheckpoint('pull:B', '0');
      await b.replicator.pullOnce();

      expect(b.store.revsOf('d').toSet(), revsBefore); // no duplicate leaf
      expect(b.store.get('d')!.rev, rev2);
      expect(b.changes.length, changesBefore); // no change event
      expect(b.store.changes(since: '0').single.leafRevs, [rev2]);
    });
  });
}

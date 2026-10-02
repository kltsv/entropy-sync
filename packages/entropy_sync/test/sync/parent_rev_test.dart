/// `vault_sync` test-spec — explicit-parent local writes: `put(parentRev:)`
/// mints the new revision as a child of a *named* revision instead of the
/// current winner. Parenting elsewhere in the tree creates a live branch — a
/// real conflict for the conflict machinery — which is how a shell ingests an
/// edit that raced a pull as a sibling of the pre-graft revision instead of
/// silently fast-forwarding the remote winner.
library;

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('put with an explicit parentRev', () {
    test(
        'parenting on a non-winner ancestor creates a live branch — a real '
        'conflict with a deterministic winner', () async {
      final store = LocalStore();
      final rev1 = await store.put('d', {'v': 1});
      final rev2 = await store.put('d', {'v': 2});

      final branch = await store.put('d', {'v': 'raced'}, parentRev: rev1);

      expect(revGeneration(branch), 2); // child of the gen-1 parent
      expect(store.revisionedDoc('d', branch)!.revisionIds,
          [revHash(branch), revHash(rev1)]); // grafted under rev1, not rev2
      // Two live leaves — the conflict machinery sees a real conflict.
      final report = store.conflicts().single;
      expect({report.winnerRev, report.losers.single.rev}, {rev2, branch});
      // The winner stays a pure function of the tree (both gen 2 → greater
      // hash) and is exposed cheaply via SyncDoc.rev.
      final expected =
          revHash(rev2).compareTo(revHash(branch)) > 0 ? rev2 : branch;
      expect(store.get('d')!.rev, expected);
      // The branch revision awaits push like any local write.
      expect(store.pendingPushEntries.any((e) => e.rev == branch), isTrue);
    });

    test(
        'a losing branch emits a conflict event but no change event (the '
        'winner did not move)', () async {
      final store = LocalStore();
      final rev1 = await store.put('d', {'v': 1});
      await store.put('d', {'v': 2});
      final rev3 = await store.put('d', {'v': 3});
      final changes = <Change>[];
      final conflicts = <ConflictReport>[];
      store.onChange(changes.add);
      store.onConflict(conflicts.add);

      final branch = await store.put('d', {'v': 'late'}, parentRev: rev1);

      expect(revGeneration(branch), 2); // loses to the gen-3 winner
      expect(store.get('d')!.rev, rev3); // winner unchanged
      expect(changes, isEmpty,
          reason: 'no new winning revision — no change event');
      expect(conflicts.single.winnerRev, rev3);
      expect(conflicts.single.losers.single.rev, branch);
    });

    test('a winning branch emits a change event carrying the new winner',
        () async {
      final store = LocalStore();
      final rev1 = await store.put('d', {'v': 1});
      final rev2 = await store.put('d', {'v': 2});
      final changes = <Change>[];
      store.onChange(changes.add);

      // Extend the branch until it out-generations the old winner.
      final b1 = await store.put('d', {'v': 'b1'}, parentRev: rev1);
      final b2 = await store.put('d', {'v': 'b2'}, parentRev: b1);

      expect(revGeneration(b2), 3);
      expect(store.get('d')!.rev, b2);
      expect(changes.last.doc.rev, b2);
      expect(store.conflicts().single.losers.single.rev, rev2);
    });

    test(
        'parentRev equal to the winner behaves like a plain put — dedup '
        'applies', () async {
      final store = LocalStore();
      await store.put('d', {'v': 1});
      final winner = store.get('d')!.rev!;

      // Identical content on the winner: deduped, nothing minted.
      final deduped = await store.put('d', {'v': 1}, parentRev: winner);
      expect(deduped, winner);
      expect(store.revsOf('d'), hasLength(1));

      // New content on the winner: an ordinary child revision.
      final child = await store.put('d', {'v': 2}, parentRev: winner);
      expect(revGeneration(child), 2);
      expect(store.get('d')!.rev, child);
      expect(store.conflicts(), isEmpty);
    });

    test(
        'dedup does NOT apply to a branching put — identical content still '
        'mints a sibling', () async {
      final store = LocalStore();
      final rev1 = await store.put('d', {'v': 1});
      final rev2 = await store.put('d', {'v': 2});

      // Same body as the current winner, but parented elsewhere: the branch
      // must exist (it represents a divergent edit), never dedup away.
      final branch = await store.put('d', {'v': 2}, parentRev: rev1);

      expect(branch, isNot(rev2));
      expect(store.revsOf('d').toSet(), {rev1, rev2, branch});
      expect(store.conflicts(), hasLength(1));
    });

    test('an unknown parentRev is rejected', () async {
      final store = LocalStore();
      await store.put('d', {'v': 1});

      await expectLater(store.put('d', {'v': 2}, parentRev: '9-${hx('f')}'),
          throwsArgumentError);
      await expectLater(
          store.put('unknown-doc', {'v': 1}, parentRev: '1-${hx('a')}'),
          throwsArgumentError);
      // Nothing was minted by the failed writes.
      expect(store.revsOf('d'), hasLength(1));
      expect(store.get('unknown-doc'), isNull);
    });

    test('the branch conflict replicates and resolves like any other',
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
      final rev2 = await a.store.put('d', {'v': 2});
      final branch = await a.store.put('d', {'v': 'raced'}, parentRev: rev1);
      await a.engine.syncNow();
      await b.engine.syncNow();

      // Both leaves crossed the wire; B sees the same conflict.
      expect(b.store.revsOf('d').toSet().containsAll({rev2, branch}), isTrue);
      final report = b.store.conflicts().single;
      expect(b.store.get('d')!.rev, a.store.get('d')!.rev);

      // Host-driven resolution converges both replicas.
      await b.engine.resolve('d', [for (final l in report.losers) l.rev!]);
      await b.engine.syncNow();
      await a.engine.syncNow();
      expect(a.store.conflicts(), isEmpty);
      expect(b.store.conflicts(), isEmpty);
      expect(a.store.get('d')!.rev, b.store.get('d')!.rev);
    });
  });
}

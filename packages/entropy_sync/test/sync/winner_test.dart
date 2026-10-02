/// `vault_sync` test-spec — "The winner algorithm" (R9).
library;

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('the winner algorithm (R9)', () {
    test('a live leaf beats a deleted leaf of higher generation', () async {
      final store = LocalStore();
      final live = '4-${hx('a')}';
      final deleted = '7-${hx('f')}';
      store.graft(rdoc('d', [live, '3-${hx('1')}'], body: {'live': true}));
      store.graft(rdoc('d', [deleted, '6-${hx('2')}'], deleted: true));

      final winner = store.get('d')!;
      expect(winner.rev, live); // deletedness dominates generation
      expect(winner.deleted, isFalse);
    });

    test('among live leaves, the higher generation wins', () async {
      final store = LocalStore();
      final gen5 = '5-${hx('a')}';
      final gen4 = '4-${hx('f')}';
      store.graft(rdoc('d', [gen5, '4-${hx('1')}'], body: {'g': 5}));
      store.graft(rdoc('d', [gen4, '3-${hx('2')}'], body: {'g': 4}));

      // Generation 5 wins even though its hash is lexicographically lower.
      expect(store.get('d')!.rev, gen5);
    });

    test(
        'an equal-generation tie breaks to the lexicographically greater '
        'hash', () async {
      final store = LocalStore();
      final lower = '4-${hx('00aa')}';
      final higher = '4-${hx('00ab')}';
      store.graft(rdoc('d', [lower, '3-${hx('1')}'], body: {'l': 1}));
      store.graft(rdoc('d', [higher, '3-${hx('1')}'], body: {'h': 1}));

      expect(store.get('d')!.rev, higher);
    });

    test(
        'the winner is identical on every replica regardless of arrival '
        'order', () async {
      final ancestor = '2-${hx('9')}';
      final leaves = [
        rdoc('d', ['3-${hx('a')}', ancestor], body: {'n': 1}),
        rdoc('d', ['3-${hx('c')}', ancestor], body: {'n': 2}),
        rdoc('d', ['4-${hx('b')}', '3-${hx('a')}', ancestor], body: {'n': 3}),
      ];
      final orders = [
        [0, 1, 2],
        [2, 0, 1],
        [1, 2, 0],
      ];
      final winners = <String>{};
      for (final order in orders) {
        final store = LocalStore();
        for (final i in order) {
          store.graft(leaves[i]);
        }
        winners.add(store.get('d')!.rev!);
      }
      // All three name the same revision — the winner is a pure function of
      // the tree, needing no coordination.
      expect(winners, hasLength(1));

      // …and it matches the winner the server reports for the same tree.
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault');
      addTearDown(emulator.stop);
      final exec = IoHttpExec();
      addTearDown(exec.close);
      final transport = CouchTransport(
        baseUrl: emulator.baseUrl,
        database: 'vault',
        exec: exec,
      );
      await transport.bulkDocs(leaves);
      final serverDoc = await transport.getDoc('d');
      expect(serverDoc!['_rev'], winners.single);
    });
  });
}

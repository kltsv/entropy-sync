/// `vault_sync` test-spec — "The opaque document model" (RV1).
library;

import 'dart:convert';

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('the opaque document model (RV1)', () {
    test('a local write stores the opaque body verbatim', () async {
      final store = LocalStore();
      final body = <String, Object?>{
        'v': 1,
        'n': 'ZmFrZS1ub25jZQ==',
        'c': 'ZmFrZS1jaXBoZXJ0ZXh0',
        'nested': {
          'list': [1, 'two', null],
          'path-looking-field': 'notes/daily.md',
        },
      };
      final rev = await store.put('a1b2c3d4e5f6', body);

      expect(rev, matches(RegExp(r'^1-[0-9a-f]{32}$')));
      expect(store.allDocIds, ['a1b2c3d4e5f6']);
      final doc = store.get('a1b2c3d4e5f6')!;
      expect(doc.rev, rev);
      expect(doc.deleted, isFalse);
      // Byte-identical body — no field parsed, normalized, or rewritten.
      expect(jsonEncode(doc.body), jsonEncode(body));
    });

    test(
        'opaque round-trip: the body crosses replica → server → replica '
        'untouched', () async {
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

      final body = <String, Object?>{'v': 1, 'n': 'opaque', 'c': 'payload'};
      final rev = await a.store.put('doc-1', body);
      await a.engine.syncNow();
      await b.engine.syncNow();

      expect(b.changes, hasLength(1));
      final change = b.changes.single;
      expect(change.id, 'doc-1');
      expect(change.origin, ChangeOrigin.remote);
      expect(change.doc.deleted, isFalse);
      expect(jsonEncode(change.doc.body), jsonEncode(body));
      // Grafted, not re-minted: the exact revision id A minted.
      expect(b.store.get('doc-1')!.rev, rev);
      // The server stored the body verbatim.
      expect(jsonEncode(emulator.db('vault').store.get('doc-1')!.body),
          jsonEncode(body));
    });

    test('deletion is a tombstone revision, not removal (R15, C7)', () async {
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
      await a.engine.syncNow();
      await b.engine.syncNow();

      final tombstoneRev = await a.store.delete('d');
      await a.engine.syncNow();
      await b.engine.syncNow();

      expect(tombstoneRev, matches(RegExp(r'^2-[0-9a-f]{32}$')));
      for (final store in [
        a.store,
        b.store,
        emulator.db('vault').store,
      ]) {
        // The id was never purged — the tombstone revision exists everywhere.
        expect(store.allDocIds, contains('d'));
        final doc = store.get('d')!;
        expect(doc.rev, tombstoneRev);
        expect(doc.deleted, isTrue);
        expect(doc.body, isNull); // no content on the tombstone
      }
      final deletion =
          b.changes.where((c) => c.id == 'd' && c.doc.deleted).toList();
      expect(deletion, hasLength(1));
      expect(deletion.single.origin, ChangeOrigin.remote);
    });

    test(
        'the single attachment rests in the blob store, referenced by '
        'digest (R7, N5)', () async {
      final store = LocalStore();
      final bytes = List<int>.generate(4096, (i) => (i * 31) % 256);
      await store.put(
        'doc-att',
        {'meta': 'only'},
        attachment: byteStream(bytes, chunkSize: 512),
      );

      final doc = store.get('doc-att')!;
      final ref = doc.attachment!;
      expect(await store.blobStore.contains(ref.digest), isTrue);
      expect(ref.length, bytes.length);
      expect(await collectBytes(store.blobStore.openRead(ref.digest)), bytes);
      // The body does not contain the bytes (no base64 inflation) …
      expect(jsonEncode(doc.body), jsonEncode({'meta': 'only'}));
      // … and no additional documents were created (no chunking).
      expect(store.allDocIds, hasLength(1));
    });
  });
}

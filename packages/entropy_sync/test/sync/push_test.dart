/// `vault_sync` test-spec — "Push" (RV4).
library;

import 'package:entropy_sync/src/sync/sync.dart';
import 'package:entropy_sync/testing.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  group('push (RV4)', () {
    test('revs-diff transfers only what the server lacks', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault');
      final a = makeReplica(emulator, replicaId: 'A');
      addTearDown(() async {
        await a.dispose();
        await emulator.stop();
      });

      for (var i = 0; i < 100; i++) {
        await a.store.put('doc-$i', {'i': i});
      }
      await a.engine.syncNow(); // server and A synced on the 100-document set

      await a.store.put('doc-42', {'i': 42, 'edited': true});
      emulator.clearLog();
      await a.engine.syncNow();

      final revsDiffs = logFor(emulator, '_revs_diff');
      expect(revsDiffs, hasLength(1));
      expect((revsDiffs.single.jsonBody as Map).keys, ['doc-42']);
      // Exactly one document body crossed; the 99 unchanged were not re-sent.
      final bulkDocs = logFor(emulator, '_bulk_docs');
      expect(bulkDocs, hasLength(1));
      final docs = ((bulkDocs.single.jsonBody as Map)['docs'] as List);
      expect(docs, hasLength(1));
      expect((docs.single as Map)['_id'], 'doc-42');
    });

    test(
        'attachment-less push uses _bulk_docs with new_edits:false and the '
        'full ancestor path', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      final a = makeReplica(emulator, replicaId: 'A');
      addTearDown(() async {
        await a.dispose();
        await emulator.stop();
      });

      final rev1 = await a.store.put('d', {'v': 1});
      final rev2 = await a.store.put('d', {'v': 2});
      emulator.clearLog();
      await a.replicator.pushOnce();

      final request = logFor(emulator, '_bulk_docs').single;
      expect(request.method, 'POST');
      final body = (request.jsonBody as Map).cast<String, Object?>();
      expect(body['new_edits'], isFalse);
      final doc =
          ((body['docs'] as List).single as Map).cast<String, Object?>();
      expect(doc['_rev'], rev2);
      expect((doc['_revisions'] as Map)['start'], 2);
      // The path [a, r] — the full known ancestor chain.
      expect((doc['_revisions'] as Map)['ids'], [revHash(rev2), revHash(rev1)]);
      // The server ends with the identical revision id and tree — no
      // server-minted revision.
      expect(server.store.get('d')!.rev, rev2);
      expect(server.store.revsOf('d').toSet(), {rev1, rev2});
    });

    test(
        'an attachment push is one multipart PUT with ?new_edits=false — '
        'never a separate attachment PUT', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      final server = emulator.db('vault');
      final a = makeReplica(emulator, replicaId: 'A');
      addTearDown(() async {
        await a.dispose();
        await emulator.stop();
      });

      final bytes = List<int>.generate(64 * 1024, (i) => (i * 13) % 256);
      await a.store.put('att', {'kind': 'blob'}, attachment: byteStream(bytes));
      final digest = a.store.get('att')!.attachment!.digest;
      emulator.clearLog();
      await a.replicator.pushOnce();

      // A single PUT /{db}/{id}?new_edits=false with a multipart/related
      // body carrying `_attachments: {data: {follows: true, …}}`.
      final puts = emulator.requestLog
          .where((req) => req.method == 'PUT' && req.path == '/vault/att')
          .toList();
      expect(puts, hasLength(1));
      expect(puts.single.query['new_edits'], 'false');
      expect(puts.single.contentType, contains('multipart/related'));
      // The server never receives a PUT /{db}/{id}/data.
      expect(emulator.requestLog.where((req) => req.path.endsWith('/data')),
          isEmpty);
      expect(logFor(emulator, '_bulk_docs'), isEmpty);
      // The bytes and the document arrived as one revision.
      final serverDoc = server.store.get('att')!;
      expect(serverDoc.rev, a.store.get('att')!.rev);
      expect(serverDoc.attachment!.digest, digest);
      expect(
          await collectBytes(server.store.blobStore.openRead(digest)), bytes);
    });

    test('pending_push survives a restart', () async {
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault');
      final backend = MemoryBackend(); // the durable store

      // First replica instance, server unreachable — writes queue.
      final first = LocalStore(backend: backend);
      await first.put('p1', {'v': 1});
      await first.put('p2', {'v': 2});
      expect(first.pendingPushCount, 2);

      // Tear the instance down; construct a fresh one over the same store.
      final r = makeReplica(emulator, replicaId: 'R', backend: backend);
      addTearDown(() async {
        await r.dispose();
        await emulator.stop();
      });
      expect(r.store.pendingPushCount, 2); // durable state, not memory

      await r.engine.syncNow();

      final server = emulator.db('vault');
      expect(server.store.get('p1'), isNotNull);
      expect(server.store.get('p2'), isNotNull);
      expect(r.store.pendingPushCount, 0);
      await waitUntil(() => r.statuses.any((s) => s.pendingPush == 0),
          reason: 'pendingPush back to 0 on the status stream');
    });

    test('a burst of local writes debounces into one push batch (~2 s)',
        () async {
      final emulator = CouchEmulator();
      await emulator.start();
      emulator.db('vault');
      final a = makeReplica(emulator,
          replicaId: 'A', pushDebounce: const Duration(milliseconds: 150));
      addTearDown(() async {
        await a.dispose();
        await emulator.stop();
      });
      await a.engine.start();
      await waitUntil(() => a.statuses.any((s) => s.online),
          reason: 'engine online');
      emulator.clearLog();

      // Five puts in rapid succession, all inside one debounce window.
      for (var i = 0; i < 5; i++) {
        await a.store.put('burst-$i', {'i': i});
      }
      await waitUntil(() => a.store.pendingPushCount == 0,
          reason: 'burst pushed');

      // One push batch covering all five: one _revs_diff, one transfer.
      expect(logFor(emulator, '_revs_diff'), hasLength(1));
      final bulkDocs = logFor(emulator, '_bulk_docs');
      expect(bulkDocs, hasLength(1));
      expect(((bulkDocs.single.jsonBody as Map)['docs'] as List), hasLength(5));

      // A later put after the window opens a new batch.
      await a.store.put('later', {'i': 99});
      await waitUntil(() => a.store.pendingPushCount == 0,
          reason: 'later put pushed');
      expect(logFor(emulator, '_revs_diff'), hasLength(2));
      await a.engine.stop();
    });
  });
}

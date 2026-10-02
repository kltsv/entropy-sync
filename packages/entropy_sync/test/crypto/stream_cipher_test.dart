/// Realizes `app/vault_crypto.tests.md` — "Streaming attachment encryption
/// (RV3)", plus a few implementation edge cases beyond the agnostic
/// contract.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:entropy_sync/src/crypto/crypto.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// The wire id the streaming fixtures are sealed for — any 64-hex id works;
/// the binding is to the exact string.
const docId =
    'a3f1c2d4e5b6978012345678901234567890123456789012345678901234abcd';

void main() {
  late VaultCrypto vc;

  setUpAll(() async {
    vc = VaultCrypto(await tinyInit());
  });

  group('streaming attachment encryption (RV3)', () {
    test(
        'a multi-segment payload round-trips through the streaming API in '
        'constant memory', () async {
      // More than four 64 KiB segments plus a short tail.
      const tail = 12345;
      final payload = patternBytes(5 * attachmentSegmentSize + tail);

      // Encrypt, fed as a stream of small chunks; the first ciphertext
      // segment must appear before the final plaintext chunk is supplied —
      // the direction never holds more than a segment of lookahead.
      final plainIn = StreamController<List<int>>();
      final cipherOut = BytesBuilder(copy: true);
      final firstCipherSegment = Completer<void>();
      final encDone =
          vc.encryptStream(plainIn.stream, docId: docId).listen((chunk) {
        cipherOut.add(chunk);
        if (!firstCipherSegment.isCompleted &&
            cipherOut.length >= attachmentHeaderSize + attachmentUnitSize) {
          firstCipherSegment.complete();
        }
      });
      final split = 3 * attachmentSegmentSize;
      for (final chunk
          in chunked(Uint8List.sublistView(payload, 0, split), 8192)) {
        plainIn.add(chunk);
      }
      await firstCipherSegment.future; // emitted before the input ended
      for (final chunk
          in chunked(Uint8List.sublistView(payload, split), 8192)) {
        plainIn.add(chunk);
      }
      await plainIn.close();
      await encDone.asFuture<void>();
      final cipher = cipherOut.takeBytes();

      // Layout: 16-byte key salt ‖ 4-byte nonce prefix ‖ per-64 KiB
      // segments, each ciphertext + 16-byte tag, final segment partial.
      expect(cipher.length,
          attachmentHeaderSize + 5 * attachmentUnitSize + tail + 16);
      // The salt and prefix are random per attachment.
      final again = await collectBytes(
          vc.encryptStream(Stream.value(payload), docId: docId));
      expect(again.length, cipher.length);
      expect(again.sublist(0, attachmentHeaderSize),
          isNot(cipher.sublist(0, attachmentHeaderSize)));

      // Decrypt, also incrementally: the first decrypted segment is produced
      // before the final ciphertext chunk is supplied.
      final cipherIn = StreamController<List<int>>();
      final plainOut = BytesBuilder(copy: true);
      final firstPlainSegment = Completer<void>();
      final decDone =
          vc.decryptStream(cipherIn.stream, docId: docId).listen((chunk) {
        plainOut.add(chunk);
        if (!firstPlainSegment.isCompleted &&
            plainOut.length >= attachmentSegmentSize) {
          firstPlainSegment.complete();
        }
      });
      const holdBack = 1000;
      for (final chunk in chunked(
          Uint8List.sublistView(cipher, 0, cipher.length - holdBack), 8192)) {
        cipherIn.add(chunk);
      }
      await firstPlainSegment.future; // produced before the last chunk
      cipherIn.add(cipher.sublist(cipher.length - holdBack));
      await cipherIn.close();
      await decDone.asFuture<void>();

      expect(plainOut.takeBytes(), payload,
          reason: 'byte-identical round trip');
    });

    test('ciphertext decrypts only under the document id it was sealed for',
        () async {
      final payload = patternBytes(2 * attachmentSegmentSize + 5000);
      final cipher = await collectBytes(
          vc.encryptStream(Stream.value(payload), docId: docId));

      // The per-attachment key derivation includes the wire id: the same
      // ciphertext under any other document id derives a different key.
      const otherId =
          'b4e2d3c5f6a7089123456789012345678901234567890123456789012345dcba';
      final result = await drainBytes(
          vc.decryptStream(Stream.value(cipher), docId: otherId));

      expect(result.error, isVaultCrypto(VaultCryptoErrorKind.tampered),
          reason: 'a swapped attachment fails at the first segment');
      expect(result.bytes, isEmpty,
          reason: 'no plaintext of another document is ever emitted');

      // Under the right id it still decrypts.
      expect(
          await collectBytes(
              vc.decryptStream(Stream.value(cipher), docId: docId)),
          payload);
    });

    test('truncation fails loudly', () async {
      final payload = patternBytes(2 * attachmentSegmentSize + 5000);
      final cipher = await collectBytes(
          vc.encryptStream(Stream.value(payload), docId: docId));

      // Cut off trailing bytes mid-segment.
      final truncated = cipher.sublist(0, cipher.length - 100);
      final result = await drainBytes(
          vc.decryptStream(Stream.value(truncated), docId: docId));

      expect(result.error, isVaultCrypto(VaultCryptoErrorKind.tampered),
          reason: 'a typed verification error — not a shorter "valid" '
              'plaintext');
      expect(result.bytes.length, lessThan(payload.length));
    });

    test('segment reorder fails', () async {
      final payload = patternBytes(3 * attachmentSegmentSize + 5000);
      final cipher = await collectBytes(
          vc.encryptStream(Stream.value(payload), docId: docId));

      // Swap the first two whole segments.
      const h = attachmentHeaderSize;
      const u = attachmentUnitSize;
      final swapped = Uint8List.fromList(cipher);
      swapped.setRange(h, h + u, cipher.sublist(h + u, h + 2 * u));
      swapped.setRange(h + u, h + 2 * u, cipher.sublist(h, h + u));

      final result = await drainBytes(
          vc.decryptStream(Stream.value(swapped), docId: docId));

      expect(result.error, isVaultCrypto(VaultCryptoErrorKind.tampered),
          reason: 'the counter embedded in each segment nonce enforces the '
              'sequence');
      expect(result.bytes, isEmpty,
          reason: 'the error hits at the first out-of-order segment');
    });

    test('tampering with a segment fails', () async {
      final payload = patternBytes(3 * attachmentSegmentSize + 5000);
      final cipher = await collectBytes(
          vc.encryptStream(Stream.value(payload), docId: docId));

      // Flip one bit inside the third segment.
      final tampered = Uint8List.fromList(cipher);
      tampered[attachmentHeaderSize + 2 * attachmentUnitSize + 100] ^= 0x01;

      final result = await drainBytes(
          vc.decryptStream(Stream.value(tampered), docId: docId));

      expect(result.error, isVaultCrypto(VaultCryptoErrorKind.tampered));
      expect(result.bytes.length, 2 * attachmentSegmentSize,
          reason: 'no plaintext of the tampered segment is emitted');
      expect(result.bytes, payload.sublist(0, 2 * attachmentSegmentSize));
    });

    test('a missing final segment is an error, not a short file', () async {
      final payload = patternBytes(3 * attachmentSegmentSize + 5000);
      final cipher = await collectBytes(
          vc.encryptStream(Stream.value(payload), docId: docId));

      // Remove the entire final segment: the stream now ends cleanly on a
      // segment boundary.
      final withoutFinal =
          cipher.sublist(0, attachmentHeaderSize + 3 * attachmentUnitSize);
      final result = await drainBytes(
          vc.decryptStream(Stream.value(withoutFinal), docId: docId));

      expect(result.error, isVaultCrypto(VaultCryptoErrorKind.tampered),
          reason: 'the segment carrying the final flag never arrived');
      expect(result.bytes.length, 2 * attachmentSegmentSize,
          reason: 'the last remaining segment must not pass as final');
    });
  });

  group('doc-level streamed encryption (RV3)', () {
    test(
        'encryptStreamed pipes large content chunk-at-a-time — ciphertext '
        'appears before the input ends, and the doc round-trips', () async {
      final tight = VaultCrypto(vc.keys, inlineThreshold: 1024);
      const tail = 4321;
      final payload = patternBytes(2 * attachmentSegmentSize + tail);

      final plainIn = StreamController<List<int>>();
      final enc = await tight.encryptStreamed(
        path: 'img/large.bin',
        mtime: 1788000000777,
        size: payload.length,
        openContent: () => plainIn.stream,
      );
      // The wire doc exists before a single content byte was read: the body
      // frame is built from the header alone.
      expect(enc.wire.body, isNotNull);
      expect(enc.attachment, isNotNull);

      final cipherOut = BytesBuilder(copy: true);
      final firstCipherSegment = Completer<void>();
      final encDone = enc.attachment!.listen((chunk) {
        cipherOut.add(chunk);
        if (!firstCipherSegment.isCompleted &&
            cipherOut.length >= attachmentHeaderSize + attachmentUnitSize) {
          firstCipherSegment.complete();
        }
      });
      final split = attachmentSegmentSize + attachmentSegmentSize ~/ 2;
      for (final chunk
          in chunked(Uint8List.sublistView(payload, 0, split), 8192)) {
        plainIn.add(chunk);
      }
      await firstCipherSegment.future; // observed before the input completed
      for (final chunk
          in chunked(Uint8List.sublistView(payload, split), 8192)) {
        plainIn.add(chunk);
      }
      await plainIn.close();
      await encDone.asFuture<void>();
      final cipher = cipherOut.takeBytes();

      final header = await tight.decryptBody(enc.wire);
      expect(header.header.inline, isFalse);
      expect(header.header.size, payload.length);
      final back = await tight.decrypt(enc.wire,
          openAttachment: () => Stream.value(cipher));
      expect(back.path, 'img/large.bin');
      expect(back.mtime, 1788000000777);
      expect(back.bytes, payload, reason: 'byte-identical round trip');
    });

    test('encryptStreamed inlines small content, identical to encrypt',
        () async {
      final content = patternBytes(2048);
      final enc = await vc.encryptStreamed(
        path: 'notes/small.md',
        mtime: 7,
        size: content.length,
        openContent: () => Stream.fromIterable(chunked(content, 512)),
      );

      expect(enc.attachment, isNull);
      expect(enc.wire.id, vc.idFor('notes/small.md'));
      final back = await vc.decrypt(enc.wire);
      expect(back.bytes, content);
      expect(back.mtime, 7);
    });

    test('a content stream that contradicts the declared size fails', () async {
      final tight = VaultCrypto(vc.keys, inlineThreshold: 1024);
      final payload = patternBytes(attachmentSegmentSize);

      final enc = await tight.encryptStreamed(
        path: 'img/changed.bin',
        mtime: 1,
        size: payload.length + 100, // the file "changed" after stat
        openContent: () => Stream.value(payload),
      );
      final result = await drainBytes(enc.attachment!);

      expect(result.error, isVaultCrypto(VaultCryptoErrorKind.malformed),
          reason: 'the sealed header already promised the declared size');
    });
  });

  group('streaming edge cases (implementation, beyond the agnostic contract)',
      () {
    test('an empty attachment still emits one final segment over 0 bytes',
        () async {
      final cipher = await collectBytes(
          vc.encryptStream(const Stream<List<int>>.empty(), docId: docId));
      expect(cipher.length, attachmentHeaderSize + 16,
          reason: 'salt + prefix + an empty final segment (tag only)');
      expect(
          await collectBytes(
              vc.decryptStream(Stream.value(cipher), docId: docId)),
          isEmpty);
    });

    test('an exact multiple of the segment size round-trips', () async {
      final payload = patternBytes(2 * attachmentSegmentSize);
      final cipher = await collectBytes(
          vc.encryptStream(Stream.value(payload), docId: docId));
      expect(cipher.length, attachmentHeaderSize + 2 * attachmentUnitSize,
          reason: 'the last full unit is the final segment — no empty '
              'trailing segment');
      expect(
          await collectBytes(
              vc.decryptStream(Stream.value(cipher), docId: docId)),
          payload);
    });

    test(
        'a single-chunk whole-payload stream is segmented without a second '
        'whole-input buffer (sub-views, byte-faithful)', () async {
      // The old implementation copied the entire incoming chunk into an
      // internal builder before segmenting — 2x the payload resident. The
      // segmenter now slices sub-views of the caller's chunk; this guards
      // the round trip for the whole-file-as-one-chunk shape both shells
      // used to produce.
      final payload = patternBytes(4 * attachmentSegmentSize + 99);
      final cipher = await collectBytes(
          vc.encryptStream(Stream.value(payload), docId: docId));
      expect(
          await collectBytes(
              vc.decryptStream(Stream.value(cipher), docId: docId)),
          payload);
    });

    test('a ciphertext shorter than the key salt and prefix is malformed',
        () async {
      final result = await drainBytes(
          vc.decryptStream(Stream.value(patternBytes(10)), docId: docId));
      expect(result.error, isVaultCrypto(VaultCryptoErrorKind.malformed));
      expect(result.bytes, isEmpty);
    });
  });
}

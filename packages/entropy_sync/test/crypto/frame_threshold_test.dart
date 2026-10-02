/// Realizes `app/vault_crypto.tests.md` — "The frame and the inline
/// threshold (RV2)".
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:entropy_sync/src/crypto/crypto.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late KeyMaterial km;
  late VaultCrypto vc;

  setUpAll(() async {
    km = await tinyInit();
    vc = VaultCrypto(km);
  });

  group('the frame and the inline threshold (RV2)', () {
    test('the frame layout is u32 BE header length ‖ JSON header ‖ content',
        () async {
      final content = bytesOf('small inline document body');
      final doc = LogicalDoc(
        path: 'a/b.md',
        bytes: content,
        mtime: 1788000000123,
      );
      final wire = (await vc.encrypt(doc)).wire;

      // Decrypt body.c directly with AES-256-GCM under k_body, nonce body.n,
      // AAD = the wire id — the instance's derived keys are readable.
      final nonce = base64Decode(wire.body!['n'] as String);
      final sealed = base64Decode(wire.body!['c'] as String);
      final frame = Uint8List.fromList(await AesGcm.with256bits().decrypt(
        SecretBox(
          sealed.sublist(0, sealed.length - 16),
          nonce: nonce,
          mac: Mac(sealed.sublist(sealed.length - 16)),
        ),
        secretKey: SecretKey(km.kBody),
        aad: utf8.encode(wire.id),
      ));

      final headerLength = ByteData.sublistView(frame, 0, 4).getUint32(0);
      final header = jsonDecode(utf8.decode(frame.sublist(4, 4 + headerLength)))
          as Map<String, dynamic>;
      expect(header, {
        'path': 'a/b.md',
        'mtime': 1788000000123,
        'size': content.length,
        'inline': true,
      });
      final rest = frame.sublist(4 + headerLength);
      expect(rest, content);
      expect(rest.length, header['size']);
    });

    test('the inline threshold is by size, not type — and configurable',
        () async {
      final binary = patternBytes(4 * 1024);
      final text = markdownBytes(2 * 1024 * 1024);

      // Default threshold 1 MiB: the tiny binary is inline…
      final small = await vc
          .encrypt(LogicalDoc(path: 'img/small.bin', bytes: binary, mtime: 1));
      expect(small.attachment, isNull);
      final smallBody = await vc.decryptBody(small.wire);
      expect(smallBody.header.inline, isTrue);
      expect(smallBody.inlineContent, binary,
          reason: 'content rides inside the frame');

      // …while the large text file rides as the attachment.
      final big = await vc
          .encrypt(LogicalDoc(path: 'notes/big.md', bytes: text, mtime: 2));
      expect(big.attachment, isNotNull);
      final bigBody = await vc.decryptBody(big.wire);
      expect(bigBody.header.inline, isFalse);
      expect(bigBody.inlineContent, isNull,
          reason: 'a non-inline frame carries no content bytes');
      final cipher = await collectBytes(big.attachment!);
      final back = await vc.decrypt(big.wire,
          openAttachment: () => Stream.value(cipher));
      expect(back.bytes, text);

      // At a 1 KiB threshold the same 4 KiB file now produces an attachment —
      // the split follows size and configuration only, never content type.
      final tight = VaultCrypto(km, inlineThreshold: 1024);
      final smallAgain = await tight
          .encrypt(LogicalDoc(path: 'img/small.bin', bytes: binary, mtime: 1));
      expect(smallAgain.attachment, isNotNull);
      expect((await tight.decryptBody(smallAgain.wire)).header.inline, isFalse);

      // The threshold is inclusive: exactly-at-threshold stays inline.
      final edge = await tight.encrypt(LogicalDoc(
          path: 'img/edge.bin', bytes: patternBytes(1024), mtime: 1));
      expect(edge.attachment, isNull);
    });

    test('a deleted logical document becomes a wire tombstone with no body',
        () async {
      final enc = await vc
          .encrypt(const LogicalDoc(path: 'notes/gone.md', deleted: true));

      expect(enc.wire.id, vc.idFor('notes/gone.md'),
          reason: 'the same deterministic HMAC id a live notes/gone.md '
              'would have');
      expect(enc.wire.deleted, isTrue);
      expect(enc.wire.body, isNull, reason: 'there is nothing to decrypt');
      expect(enc.attachment, isNull);
    });

    test('the attachment name and content type are fixed', () async {
      final pdf = patternBytes(9000);
      pdf.setRange(0, 5, bytesOf('%PDF-'));
      final tight = VaultCrypto(km, inlineThreshold: 1024);

      final enc = await tight
          .encrypt(LogicalDoc(path: 'img/scan.pdf', bytes: pdf, mtime: 3));

      expect(enc.attachment, isNotNull);
      expect(VaultCrypto.attachmentName, 'data');
      expect(VaultCrypto.attachmentContentType, 'application/octet-stream',
          reason: 'the real file type appears nowhere on the wire');
    });

    test(
        'path, mtime, and size never appear in plaintext outside the '
        'ciphertext', () async {
      const path = 'clients/acme-merger-brief.md';
      const mtime = 1788000123456;
      final content = patternBytes(271828);

      final wire = (await vc
              .encrypt(LogicalDoc(path: path, bytes: content, mtime: mtime)))
          .wire;

      final body = wire.body!;
      expect(body.keys, unorderedEquals(['v', 'n', 'c']),
          reason: 'no plaintext field carries path, mtime, or size');
      // Everything plaintext-visible outside the ciphertext in body.c:
      final visible = jsonEncode({
        '_id': wire.id,
        'deleted': wire.deleted,
        'v': body['v'],
        'n': body['n'],
      });
      expect(visible, isNot(contains(path)));
      expect(visible, isNot(contains('acme')));
      expect(visible, isNot(contains('$mtime')));
      expect(visible, isNot(contains('${content.length}')));
    });
  });
}

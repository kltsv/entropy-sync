/// Realizes `app/vault_crypto.tests.md` — "Logical ⇄ wire round trip (RV2)".
library;

import 'package:entropy_sync/src/crypto/crypto.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late VaultCrypto vc;

  setUpAll(() async {
    vc = VaultCrypto(await tinyInit());
  });

  group('logical ⇄ wire round trip (RV2)', () {
    test('a text file round-trips byte-faithfully', () async {
      final content = bytesOf('# Plan\n\n- do the thing\n- то самое дело\n');
      final doc = LogicalDoc(
        path: 'notes/plan.md',
        bytes: content,
        mtime: 1788000000000,
      );

      final wire = (await vc.encrypt(doc)).wire;
      final back = await vc.decrypt(wire);

      expect(back.path, 'notes/plan.md');
      expect(back.bytes, content);
      expect(back.mtime, 1788000000000);
      expect(back.deleted, isFalse);
    });

    test('binary content with NUL bytes round-trips', () async {
      final content = patternBytes(4096);
      expect(content.where((b) => b == 0x00), isNotEmpty,
          reason: 'the fixture must contain NUL runs');

      final wire = (await vc.encrypt(LogicalDoc(
        path: 'img/logo.png',
        bytes: content,
        mtime: 1700000000001,
      )))
          .wire;
      final back = await vc.decrypt(wire);

      expect(back.bytes, content,
          reason: 'byte-identical, NULs included — nothing was treated as '
              'text or transcoded');
    });

    test('a non-ASCII NFC path round-trips', () async {
      // NFC: é is the precomposed U+00E9, not e + combining accent.
      const path = 'заметки/café.md';

      final wire = (await vc
              .encrypt(LogicalDoc(path: path, bytes: bytesOf('x'), mtime: 1)))
          .wire;
      final back = await vc.decrypt(wire);

      expect(back.path.codeUnits, path.codeUnits,
          reason: 'code-point-identical NFC — case preserved, no '
              'normalization drift');
    });

    test('two encryptions of one document differ, and both decrypt', () async {
      final doc = LogicalDoc(
        path: 'notes/twice.md',
        bytes: bytesOf('same content'),
        mtime: 42,
      );

      final w1 = (await vc.encrypt(doc)).wire;
      final w2 = (await vc.encrypt(doc)).wire;

      // Determinism belongs to the id, randomness to the encryption.
      expect(w1.body!['n'], isNot(w2.body!['n']),
          reason: 'a fresh random 96-bit nonce each time');
      expect(w1.body!['c'], isNot(w2.body!['c']));
      expect(w1.id, w2.id);
      for (final wire in [w1, w2]) {
        final back = await vc.decrypt(wire);
        expect(back.path, doc.path);
        expect(back.bytes, doc.bytes);
        expect(back.mtime, doc.mtime);
        expect(back.deleted, isFalse);
      }
    });
  });
}

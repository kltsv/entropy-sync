/// Realizes `app/vault_crypto.tests.md` — "AAD binding (RV2)".
library;

import 'dart:typed_data';

import 'package:entropy_sync/src/crypto/crypto.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('AAD binding (RV2)', () {
    test('a ciphertext transplanted under another id fails authentication',
        () async {
      final vc = VaultCrypto(await tinyInit());
      final x = (await vc.encrypt(LogicalDoc(
              path: 'x.md', bytes: bytesOf("X's content"), mtime: 1)))
          .wire;
      final y = (await vc.encrypt(LogicalDoc(
              path: 'y.md', bytes: bytesOf("Y's content"), mtime: 2)))
          .wire;

      // A hostile server moves X's valid body under Y's id.
      final forged = WireDoc(id: y.id, body: x.body);

      // The AAD (Y's id) is not the id X's body was sealed with — no partial
      // or garbled logical document is emitted.
      await expectLater(vc.decryptBody(forged),
          throwsVaultCrypto(VaultCryptoErrorKind.tampered));
      await expectLater(
          vc.decrypt(forged), throwsVaultCrypto(VaultCryptoErrorKind.tampered));
    });

    test(
        'equal-size attachments swapped between two documents fail '
        'decryption', () async {
      // The hostile-server swap the length check alone cannot catch: two
      // attachment-bearing documents with byte-identical plaintext SIZES.
      // The per-attachment key derivation includes the wire id, so A's
      // ciphertext served under B derives a different key and fails at the
      // first segment.
      final vc = VaultCrypto(await tinyInit(), inlineThreshold: 1024);
      final size = 512 * 1024; // both above the threshold, same length
      final contentA = patternBytes(size);
      final contentB = Uint8List.fromList(contentA.reversed.toList());

      final a = await vc.encrypt(
          LogicalDoc(path: 'img/passport.jpg', bytes: contentA, mtime: 1));
      final b = await vc.encrypt(
          LogicalDoc(path: 'img/decoy.jpg', bytes: contentB, mtime: 2));
      final cipherA = await collectBytes(a.attachment!);
      final cipherB = await collectBytes(b.attachment!);
      expect(cipherA.length, cipherB.length,
          reason: 'the swap is invisible to any length check');

      // Untampered bodies, swapped attachment blobs — both directions fail.
      await expectLater(
          vc.decrypt(a.wire, openAttachment: () => Stream.value(cipherB)),
          throwsVaultCrypto(VaultCryptoErrorKind.tampered));
      await expectLater(
          vc.decrypt(b.wire, openAttachment: () => Stream.value(cipherA)),
          throwsVaultCrypto(VaultCryptoErrorKind.tampered));

      // Correctly paired, both round-trip.
      expect(
          (await vc.decrypt(a.wire,
                  openAttachment: () => Stream.value(cipherA)))
              .bytes,
          contentA);
      expect(
          (await vc.decrypt(b.wire,
                  openAttachment: () => Stream.value(cipherB)))
              .bytes,
          contentB);
    });
  });
}

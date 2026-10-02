/// Realizes `app/vault_crypto.tests.md` — "The document id (RV2)".
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:entropy_sync/src/crypto/crypto.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('the document id (RV2)', () {
    test('the id is deterministic across independent instances', () async {
      // Two independently constructed instances from the same passphrase
      // and the same meta (hence the same salt), no shared state.
      final kmA = await tinyInit();
      final kmB = await VaultCrypto.init('P', meta: kmA.meta);
      final a = VaultCrypto(kmA);
      final b = VaultCrypto(kmB);

      final idA = a.idFor('notes/plan.md');
      final idB = b.idFor('notes/plan.md');

      expect(idA, matches(RegExp(r'^[0-9a-f]{64}$')),
          reason: '64-character lowercase hex');
      expect(idB, idA);
      expect(
        idA,
        crypto.Hmac(crypto.sha256, kmA.kId)
            .convert(utf8.encode('notes/plan.md'))
            .toString(),
        reason: 'exactly hex(HMAC-SHA256(k_id, UTF-8 path bytes))',
      );
      expect(a.idFor('notes/plam.md'), isNot(idA),
          reason: 'one character off yields an entirely different id');
    });

    test(
        'the id is one-way — the path is recovered only from the decrypted '
        'frame', () async {
      const path = 'notes/plan.md';
      final vc = VaultCrypto(await tinyInit());
      final wire = (await vc.encrypt(
              LogicalDoc(path: path, bytes: bytesOf('secret'), mtime: 5)))
          .wire;

      // Every plaintext-visible part: the id, the body's v and n, deleted.
      final body = wire.body!;
      expect(body.keys, unorderedEquals(['v', 'n', 'c']),
          reason: 'no extra plaintext fields ride on the body');
      expect(wire.id, matches(RegExp(r'^[0-9a-f]{64}$')),
          reason: 'opaque hex — the hex alphabet cannot even spell the path');
      expect(wire.id, isNot(contains('plan')));
      final visible =
          jsonEncode({'_id': wire.id, 'deleted': wire.deleted, 'v': body['v']});
      expect(visible, isNot(contains(path)));
      // The nonce is 12 random bytes — too short to carry the 13-byte UTF-8
      // path in any decodable form.
      expect(base64Decode(body['n'] as String), hasLength(12));

      // The path comes back only from the frame header inside c.
      final back = await vc.decrypt(wire);
      expect(back.path, path);
    });
  });
}

/// Realizes `app/vault_crypto.tests.md` — "Keys and the meta document (RV3)".
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:entropy_sync/src/crypto/crypto.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('keys and the meta document (RV3)', () {
    test(
        'first init generates a salt and writes meta with KDF parameters '
        'and a check value', () async {
      final km = await tinyInit();
      final meta = km.meta;

      expect(meta['v'], 1);
      final kdf = meta['kdf'] as Map<String, Object?>;
      expect(kdf['alg'], 'argon2id');
      expect(base64Decode(kdf['salt'] as String), hasLength(16));
      // The parameters the keys were derived with are stored verbatim.
      expect(kdf['m'], tinyParams.memoryKiB);
      expect(kdf['t'], tinyParams.iterations);
      expect(kdf['p'], tinyParams.parallelism);

      // The check value decrypts under k_body with AAD "meta" to the fixed
      // check plaintext.
      final check = meta['check'] as Map<String, Object?>;
      final nonce = base64Decode(check['n'] as String);
      final sealed = base64Decode(check['c'] as String);
      expect(nonce, hasLength(12));
      final plain = await AesGcm.with256bits().decrypt(
        SecretBox(
          sealed.sublist(0, sealed.length - 16),
          nonce: nonce,
          mac: Mac(sealed.sublist(sealed.length - 16)),
        ),
        secretKey: SecretKey(km.kBody),
        aad: utf8.encode('meta'),
      );
      expect(utf8.decode(plain), 'vault-sync-check');

      // The salt is random per vault: a second init on a different empty
      // database yields a different salt.
      final other = await tinyInit();
      expect((other.meta['kdf'] as Map<String, Object?>)['salt'],
          isNot(kdf['salt']));
    });

    test(
        'the production KDF defaults are m = 64 MiB, t = 3, p = 1 — asserted '
        'without running the KDF', () {
      expect(Argon2Params.production.memoryKiB, 64 * 1024,
          reason: 'm = 65536 KiB blocks = 64 MiB');
      expect(Argon2Params.production.iterations, 3);
      expect(Argon2Params.production.parallelism, 1);
    });

    test(
        'a second device verifies the passphrase from meta before touching '
        'any document', () async {
      final kmA = await tinyInit();
      final deviceA = VaultCrypto(kmA);
      final doc = LogicalDoc(
        path: 'notes/from-a.md',
        bytes: bytesOf('written on device A'),
        mtime: 1788000000007,
      );
      final wire = (await deviceA.encrypt(doc)).wire;

      // B derives keys using only the salt and parameters stored in meta and
      // verifies against the check value — no vault document needed.
      final kmB = await VaultCrypto.init('P', meta: kmA.meta);

      expect(kmB.kId, kmA.kId,
          reason: 'the independently derived keys match A\'s');
      expect(kmB.kBody, kmA.kBody);
      expect(kmB.kAtt, kmA.kAtt);
      final back = await VaultCrypto(kmB).decrypt(wire);
      expect(back.path, doc.path);
      expect(back.bytes, doc.bytes);
      expect(back.mtime, doc.mtime);
    });

    test('the wrong passphrase is a typed error and nothing is decrypted',
        () async {
      final kmA = await tinyInit();

      // The error comes from the check value alone — before any vault
      // document is fetched or decrypted.
      await expectLater(VaultCrypto.init('P-typo', meta: kmA.meta),
          throwsVaultCrypto(VaultCryptoErrorKind.wrongPassphrase));
    });

    test('init against an existing meta refuses to overwrite', () async {
      final kmA = await tinyInit();
      final before = jsonEncode(kmA.meta);

      // A fresh init against the database that already has A's meta — with
      // the same or a different passphrase — is refused.
      await expectLater(
          VaultCrypto.init('P',
              meta: kmA.meta, fresh: true, params: tinyParams),
          throwsVaultCrypto(VaultCryptoErrorKind.metaExists));
      await expectLater(
          VaultCrypto.init('different',
              meta: kmA.meta, fresh: true, params: tinyParams),
          throwsVaultCrypto(VaultCryptoErrorKind.metaExists));

      expect(jsonEncode(kmA.meta), before,
          reason: 'meta is byte-identical to before — never regenerated, '
              'never overwritten');
    });

    test('Argon2id parameters and distinct HKDF subkeys', () async {
      final salt = Uint8List.fromList(List.generate(16, (i) => i));
      final km = await createKeyMaterial('P', params: tinyParams, salt: salt);

      // Independent recomputation straight from the audited primitives:
      // master = Argon2id(P, salt) with the given m/t/p…
      final argon2 = Argon2id(
        memory: tinyParams.memoryKiB,
        iterations: tinyParams.iterations,
        parallelism: tinyParams.parallelism,
        hashLength: 32,
      );
      final master =
          await (await argon2.deriveKeyFromPassword(password: 'P', nonce: salt))
              .extractBytes();
      expect(await deriveMaster('P', salt, tinyParams), master);

      // …and the subkeys via HKDF-SHA256 with infos "id", "body", "att".
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      Future<List<int>> subkey(String info) async => (await hkdf.deriveKey(
              secretKey: SecretKey(master), info: utf8.encode(info)))
          .extractBytes();
      expect(km.kId, await subkey('id'));
      expect(km.kBody, await subkey('body'));
      expect(km.kAtt, await subkey('att'));

      // Pairwise different: possessing one subkey is not possessing another.
      expect(km.kId, isNot(km.kBody));
      expect(km.kId, isNot(km.kAtt));
      expect(km.kBody, isNot(km.kAtt));
    });
  });

  test('an empty passphrase is refused, not treated as "no encryption" (RV3)',
      () async {
    // Fresh database: nothing is generated.
    await expectLater(
      VaultCrypto.init('', params: tinyParams),
      throwsA(
        isA<VaultCryptoException>().having(
          (e) => e.kind,
          'kind',
          VaultCryptoErrorKind.wrongPassphrase,
        ),
      ),
    );

    // Existing database: same refusal, before any verification work.
    final keys = await VaultCrypto.init('real passphrase', params: tinyParams);
    await expectLater(
      VaultCrypto.init('', meta: keys.meta),
      throwsA(isA<VaultCryptoException>()),
    );
  });
}

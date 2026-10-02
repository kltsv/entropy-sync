/// `vault_daemon` test-spec — "Init (D5, RV3, RV10)": the offline-first
/// `meta` flow must not let the untrusted server brick a provisioned device.
/// A corrupt or tampered remote `meta` falls back to the valid local cache
/// (with a warning), while a genuinely wrong passphrase still fails against
/// both.
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_sync/entropy_sync.dart';
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  test(
      'a corrupt remote meta falls back to the valid cached meta instead of '
      'bricking the device (RV3)', () async {
    // A provisioned device: meta on the server AND verified in the cache.
    final mac = h.handleFor('mac');
    mac.write('a.md', 'content\n');
    await h.spawn('mac');
    await mac.shell.reconcile();
    final cacheFile = File(p.join(mac.stateDir, 'meta.json'));
    expect(cacheFile.existsSync(), isTrue);

    // The server (or a middlebox) mangles meta's passphrase check value.
    final metaDoc = h.serverStore().get('meta')!;
    final corrupt =
        (jsonDecode(jsonEncode(metaDoc.body)) as Map).cast<String, Object?>();
    corrupt['check'] = {
      'n': base64Encode(List.filled(12, 0)),
      'c': base64Encode(List.filled(32, 0))
    };
    await h.serverStore().put('meta', corrupt);
    h.emulator.db('vault').touch();

    final transport = CouchTransport(
      baseUrl: Uri.parse(h.endpoint),
      database: 'vault',
      username: 'u',
      password: 'pw',
    );

    // The correct passphrase still resolves — from the cache, with a
    // warning — instead of surfacing a bogus "wrong passphrase".
    final warnings = <String>[];
    final keys = await resolveKeyMaterial(
      transport: transport,
      passphrase: defaultPassphrase,
      cacheFile: cacheFile,
      log: warnings.add,
    );
    expect(keys.meta, isNotEmpty);
    expect(warnings.join('\n'), contains('cached meta'));

    // A genuinely wrong passphrase fails against the cache too and still
    // surfaces as a crypto error.
    await expectLater(
      resolveKeyMaterial(
        transport: transport,
        passphrase: 'typo passphrase',
        cacheFile: cacheFile,
      ),
      throwsA(isA<VaultCryptoException>()),
    );
  });
}

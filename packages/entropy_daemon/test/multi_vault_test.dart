/// `vault_daemon` test-spec — "Multi-vault (R23)".
library;

import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  Daemon makeDaemon() => Daemon(version: 'test', shellFactory: h.daemonShell);

  test('one daemon serves multiple vaults, isolated from each other (R23)',
      () async {
    final daemon = makeDaemon();
    final v1 = h.handleFor('v1');
    final v2 = h.handleFor('v2');
    await daemon.addVault(h.profileFor(v1, database: 'db-one'));
    await daemon.addVault(h.profileFor(v2, database: 'db-two'));

    // Edit a file in V1; pause V2 (which also gets an edit, to prove the
    // pause holds); settle.
    v1.write('same.md', 'from v1\n');
    daemon.pause('v2');
    v2.write('same.md', 'from v2\n');
    await daemon.syncNow();

    // V1's edit synced to its own server DB…
    expect(await h.decryptServerText(v1, 'same.md', database: 'db-one'),
        'from v1\n');
    // …V2 did not sync while paused…
    expect(
      h.serverStore('db-two').allDocIds.where((id) => id != 'meta'),
      isEmpty,
    );
    // …and neither vault's documents leak into the other's database.
    expect(h.serverStore('db-two').get(v1.docId('same.md')), isNull);
    expect(h.serverStore('db-one').get(v2.docId('same.md')), isNull);

    // A pause on one never stops the other: the daemon reports V2 paused,
    // V1 running.
    final byId = {
      for (final v in daemon.status().vaults) v.vaultId: v,
    };
    expect(byId['v1']!.state, SyncState.running);
    expect(byId['v2']!.state, SyncState.paused);

    // Resuming V2 lets its own edit reach its own database.
    daemon.resume('v2');
    await daemon.syncNow('v2');
    expect(await h.decryptServerText(v2, 'same.md', database: 'db-two'),
        'from v2\n');
  });

  test(
      'a second vault targeting the same (endpoint, database) is refused '
      'unless acknowledged (R23)', () async {
    final daemon = makeDaemon();
    final v1 = h.handleFor('v1');
    final p1 = h.profileFor(v1, database: 'shared-db');
    await daemon.addVault(p1);
    final shellBefore = daemon.vaults['v1']!.shell;

    // A *different* vault targeting the same endpoint (spelled differently:
    // scheme case, trailing slash) and the same database.
    final v2 = h.handleFor('v2');
    final p2 = VaultProfile(
      vaultId: 'v2',
      vaultRoot: v2.vaultRoot,
      endpoint: '${h.endpoint.toUpperCase()}/',
      database: 'shared-db',
      serverUser: 'u',
      serverPassword: 'pw',
      passphrase: defaultPassphrase,
    );

    // Without the acknowledgement, registration is rejected with a clear
    // error naming the conflict.
    await expectLater(
      daemon.addVault(p2),
      throwsA(isA<VaultTargetConflict>().having(
        (e) => e.toString(),
        'message',
        allOf(contains('v2'), contains('v1'), contains('shared-db')),
      )),
    );

    // V2 was not added and V1 keeps running unchanged.
    expect(daemon.vaults.keys, ['v1']);
    expect(identical(daemon.vaults['v1']!.shell, shellBefore), isTrue);
    expect(daemon.status().vaults.single.state, SyncState.running);

    // Adding V1 again (the same vault) is the idempotent attach, not a
    // conflict.
    await daemon.addVault(h.profileFor(v1, database: 'shared-db'));
    expect(daemon.vaults.keys, ['v1']);
    expect(identical(daemon.vaults['v1']!.shell, shellBefore), isTrue);
  });

  test('an acknowledged shared database registers both vaults (R23)', () async {
    final daemon = makeDaemon();
    final v1 = h.handleFor('v1');
    final v2 = h.handleFor('v2'); // a different, non-overlapping folder
    await daemon.addVault(h.profileFor(v1, database: 'shared-db'));
    await daemon.addVault(
      h.profileFor(v2, database: 'shared-db'),
      allowSharedDatabase: true,
    );

    // Both are registered and served alongside each other.
    expect(daemon.vaults.keys, unorderedEquals(['v1', 'v2']));
    final byId = {for (final v in daemon.status().vaults) v.vaultId: v};
    expect(byId['v1']!.state, SyncState.running);
    expect(byId['v2']!.state, SyncState.running);

    // The two replicas carry different ids, so neither overwrites the other's
    // checkpoint — the reason one vault in two folders is safe at all.
    const device = 'device-a';
    expect(replicaIdFor('v1', device), isNot(replicaIdFor('v2', device)));

    // And the point of the whole exercise: the folders converge to one
    // content set. A file written in V1 lands in V2's folder.
    v1.write('note.md', 'written in v1\n');
    await daemon.syncNow('v1');
    await daemon.syncNow('v2');
    expect(v2.file('note.md').readAsStringSync(), 'written in v1\n');

    // Neither vault was stopped or re-registered by the other.
    expect(daemon.status().vaults.every((v) => v.state == SyncState.running),
        isTrue);
  });

  test('re-registering keeps the tuning the request did not mention', () async {
    final daemon = makeDaemon();
    final v1 = h.handleFor('v1');
    final tuned = VaultProfile(
      vaultId: 'v1',
      vaultRoot: v1.vaultRoot,
      endpoint: h.endpoint,
      database: 'vault',
      serverUser: 'u',
      serverPassword: 'pw',
      passphrase: defaultPassphrase,
      writerName: 'the-mac',
      exclusions: const ['.DS_Store', 'drafts/'],
      histExtensions: const ['.md', '.json'],
      histIdleMillis: 5000,
      rescanSeconds: 60,
    );
    await daemon.addVault(tuned);

    // A front-end editing the connection sends the connection only.
    await daemon.registerVault(AddVaultRequest(
      profile: tuned.toConnectionJson(),
      passphrase: defaultPassphrase,
      serverPassword: 'pw',
    ));

    final kept = daemon.vaults['v1']!.profile;
    expect(kept.writerName, 'the-mac');
    expect(kept.exclusions, ['.DS_Store', 'drafts/']);
    expect(kept.histExtensions, ['.md', '.json']);
    expect(kept.histIdleMillis, 5000);
    expect(kept.rescanSeconds, 60);
  });

  test('a tuning field the request does supply is applied', () async {
    final daemon = makeDaemon();
    final v1 = h.handleFor('v1');
    final tuned = VaultProfile(
      vaultId: 'v1',
      vaultRoot: v1.vaultRoot,
      endpoint: h.endpoint,
      database: 'vault',
      serverUser: 'u',
      serverPassword: 'pw',
      passphrase: defaultPassphrase,
      writerName: 'the-mac',
      histExtensions: const ['.md'],
      histIdleMillis: 5000,
    );
    await daemon.addVault(tuned);

    await daemon.registerVault(AddVaultRequest(
      profile: {
        ...tuned.toConnectionJson(),
        'history': {
          'extensions': ['*']
        },
      },
      passphrase: defaultPassphrase,
      serverPassword: 'pw',
    ));

    final kept = daemon.vaults['v1']!.profile;
    expect(kept.histExtensions, ['*'], reason: 'a supplied value is applied');
    expect(kept.writerName, 'the-mac', reason: 'the rest is still untouched');
    expect(kept.histIdleMillis, 5000);
  });

  test('a vault the daemon has never seen falls back to the defaults',
      () async {
    final daemon = makeDaemon();
    final v1 = h.handleFor('v1');

    await daemon.registerVault(AddVaultRequest(
      profile: h.profileFor(v1).toConnectionJson(),
      passphrase: defaultPassphrase,
      serverPassword: 'pw',
    ));

    final fresh = daemon.vaults['v1']!.profile;
    expect(fresh.histExtensions, ['.md']);
    expect(fresh.exclusions, VaultProfile.defaultExclusions);
    expect(fresh.histIdleMillis, 60000);
  });

  test('registerVault carries the acknowledgement through to addVault',
      () async {
    // The control-channel path re-checks inside addVault; the flag has to
    // travel with it, or the registration this method just accepted is
    // refused a step later.
    final daemon = makeDaemon();
    final v1 = h.handleFor('v1');
    final v2 = h.handleFor('v2');
    final p1 = h.profileFor(v1, database: 'shared-db');
    await daemon.addVault(p1);

    final p2 = h.profileFor(v2, database: 'shared-db');
    final request = AddVaultRequest(
      profile: p2.toRegistryJson(),
      passphrase: p2.passphrase,
      serverPassword: p2.serverPassword,
      allowSharedDatabase: true,
    );
    // Survives the JSON round-trip the control channel performs.
    await daemon.registerVault(AddVaultRequest.fromJson(request.toJson()));

    expect(daemon.vaults.keys, unorderedEquals(['v1', 'v2']));

    // …and the same request without the flag is still refused.
    final v3 = h.handleFor('v3');
    final bare = AddVaultRequest(
      profile: h.profileFor(v3, database: 'shared-db').toRegistryJson(),
      passphrase: p2.passphrase,
      serverPassword: p2.serverPassword,
    );
    await expectLater(
      daemon.registerVault(AddVaultRequest.fromJson(bare.toJson())),
      throwsA(isA<VaultTargetConflict>()),
    );
    expect(daemon.vaults.containsKey('v3'), isFalse);
  });

  test('a folder collision is refused even when the database is acknowledged',
      () async {
    final daemon = makeDaemon();
    final v1 = h.handleFor('v1');
    final p1 = h.profileFor(v1, database: 'shared-db');
    await daemon.addVault(p1);

    // Same database *and* the same folder, with the acknowledgement set: the
    // acknowledgement covers the database rule only, never the folder rule.
    final p2 = VaultProfile(
      vaultId: 'v2',
      vaultRoot: p1.vaultRoot,
      endpoint: p1.endpoint,
      database: 'shared-db',
      serverUser: p1.serverUser,
      serverPassword: p1.serverPassword,
      passphrase: p1.passphrase,
    );
    await expectLater(
      daemon.addVault(p2, allowSharedDatabase: true),
      throwsA(isA<VaultFolderConflict>()
          .having((e) => e.conflictsWith, 'conflictsWith', 'v1')),
    );

    // Nothing was registered and V1 is untouched.
    expect(daemon.vaults.keys, ['v1']);
    expect(daemon.status().vaults.single.state, SyncState.running);
  });

  test('the database conflict is reported before the folder conflict',
      () async {
    final daemon = makeDaemon();
    final v1 = h.handleFor('v1');
    final p1 = h.profileFor(v1, database: 'shared-db');
    await daemon.addVault(p1);

    // Colliding on both, with no acknowledgement: the database conflict is
    // the one reported, because it is the one the owner can act on.
    final p2 = VaultProfile(
      vaultId: 'v2',
      vaultRoot: p1.vaultRoot,
      endpoint: p1.endpoint,
      database: 'shared-db',
      serverUser: p1.serverUser,
      serverPassword: p1.serverPassword,
      passphrase: p1.passphrase,
    );
    await expectLater(daemon.addVault(p2), throwsA(isA<VaultTargetConflict>()));
    expect(daemon.vaults.keys, ['v1']);
  });

  test('a vault whose folder collides with a served one is refused', () async {
    final daemon = makeDaemon();
    final v1 = h.handleFor('v1');
    await daemon.addVault(h.profileFor(v1, database: 'db-one'));
    final root = h.profileFor(v1).vaultRoot;

    Future<void> refuse(String id, String folder) async {
      final profile = VaultProfile(
        vaultId: id,
        vaultRoot: folder,
        endpoint: h.profileFor(v1).endpoint,
        database: 'db-$id',
        serverUser: h.profileFor(v1).serverUser,
        serverPassword: h.profileFor(v1).serverPassword,
        passphrase: h.profileFor(v1).passphrase,
      );
      await expectLater(
        daemon.addVault(profile),
        throwsA(
          isA<VaultFolderConflict>()
              .having((e) => e.conflictsWith, 'conflictsWith', 'v1'),
        ),
      );
      expect(daemon.vaults.containsKey(id), isFalse);
    }

    await refuse('same', root); // the very same folder
    await refuse('inside', p.join(root, 'notes')); // nested inside it
    await refuse('outside', p.dirname(root)); // containing it

    // The served vault is untouched and re-registering it is the idempotent
    // attach, not a self-collision.
    expect(daemon.vaults.keys, ['v1']);
    await daemon.addVault(h.profileFor(v1, database: 'db-one'));
    expect(daemon.vaults.length, 1);
  });

  test('folder overlap is symmetric and path-normalized', () {
    expect(foldersOverlap('/a/b', '/a/b'), isTrue);
    expect(foldersOverlap('/a/b', '/a/b/c'), isTrue);
    expect(foldersOverlap('/a/b/c', '/a/b'), isTrue);
    expect(foldersOverlap('/a/b', '/a/bc'), isFalse);
    expect(foldersOverlap('/a/b', '/a/c'), isFalse);
  });
}

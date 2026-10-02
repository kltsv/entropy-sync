/// `vault_daemon` test-spec — "Multi-vault (R23)" / "Control channel":
/// the daemon owns each served vault's continuous runtime (shell + watcher +
/// periodic rescan). Registering or editing a vault over the control channel
/// disposes the old runtime and wires a new one — no stale watcher or timer
/// keeps driving a stopped shell — and pause gates the watcher's ingest path:
/// a paused vault neither ingests nor pushes; resume reconciles to catch up.
library;

import 'dart:async';

import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:watcher/watcher.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  test(
      'registerVault replaces the runtime: the old watcher flush stops '
      'driving the stale shell, the new vault ingests (D10, R23)', () async {
    final daemonStateRoot = p.join(h.tmp.path, 'daemon-state');
    final controllers = <StreamController<WatchEvent>>[];
    Stream<WatchEvent> watch(String root) {
      final ctrl = StreamController<WatchEvent>.broadcast();
      controllers.add(ctrl);
      return ctrl.stream;
    }

    final daemon = Daemon(
      version: 'test',
      shellFactory: h.daemonShell,
      registry: VaultRegistry(daemonStateRoot),
      secrets: FileSecretStore(p.join(daemonStateRoot, 'secrets')),
      watchFactory: watch,
    );
    final v1 = h.handleFor('v1');
    await daemon.addVault(h.profileFor(v1, database: 'db-one'));
    await daemon.startContinuous();

    final firstRuntime = daemon.runtimeOf('v1');
    expect(firstRuntime, isNotNull, reason: 'continuous mode owns a runtime');
    expect(controllers, hasLength(1), reason: 'the watcher was wired');
    final firstShell = daemon.vaults['v1']!.shell!;

    // The watcher's debounce flush ingests and pushes.
    v1.write('watched.md', 'via watcher\n');
    await firstRuntime!.flushPath('watched.md');
    expect(await h.decryptServerText(v1, 'watched.md', database: 'db-one'),
        'via watcher\n');

    // A front-end edits the vault over the control channel.
    final edited = h.profileFor(v1, database: 'db-one').toRegistryJson()
      ..['writerName'] = 'renamed-writer';
    await daemon.registerVault(AddVaultRequest(
      profile: edited,
      passphrase: defaultPassphrase,
      serverPassword: 'pw',
    ));

    // The old runtime was disposed and a new one wired to the NEW shell.
    final secondRuntime = daemon.runtimeOf('v1');
    expect(secondRuntime, isNotNull);
    expect(identical(secondRuntime, firstRuntime), isFalse);
    expect(identical(daemon.vaults['v1']!.shell, firstShell), isFalse);
    expect(identical(secondRuntime!.shell, daemon.vaults['v1']!.shell), isTrue);
    expect(controllers, hasLength(2), reason: 'a fresh watcher was wired');

    // The disposed runtime's flush is inert — nothing rides through the
    // stale shell (which used to keep encrypting with the old profile).
    v1.write('after-edit.md', 'to the new shell\n');
    await firstRuntime.flushPath('after-edit.md');
    expect(firstShell.store.pendingPushCount, 0);

    // The live runtime serves the edit.
    await secondRuntime.flushPath('after-edit.md');
    expect(await h.decryptServerText(v1, 'after-edit.md', database: 'db-one'),
        'to the new shell\n');

    await daemon.stopAll();
    expect(daemon.runtimeOf('v1'), isNull);
  });

  test('a watcher event flows through the debounce into a pushed revision',
      () async {
    final ctrl = StreamController<WatchEvent>.broadcast();
    final v1 = h.handleFor('v1');
    final daemon = Daemon(
      version: 'test',
      shellFactory: (profile) async => h.daemonShell(profile),
      watchFactory: (_) => ctrl.stream,
    );
    await daemon
        .addVault(h.profileFor(v1, database: 'db-one', watchDebounceMillis: 1));
    await daemon.startContinuous();

    v1.write('evented.md', 'debounced\n');
    ctrl.add(WatchEvent(ChangeType.ADD, p.join(v1.vaultRoot, 'evented.md')));

    // The per-path debounce (1 ms) flushes and the edit pushes.
    var synced = false;
    for (var i = 0; i < 100 && !synced; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      try {
        synced =
            await h.decryptServerText(v1, 'evented.md', database: 'db-one') ==
                'debounced\n';
      } on StateError {
        // not yet pushed
      }
    }
    expect(synced, isTrue);
    await daemon.stopAll();
    await ctrl.close();
  });

  test(
      'pause gates the watcher ingest path; resume reconciles to catch up '
      '(both directions)', () async {
    final v1 = h.handleFor('v1');
    final daemon = Daemon(
      version: 'test',
      shellFactory: h.daemonShell,
    );
    await daemon.addVault(h.profileFor(v1, database: 'db-one'));
    await daemon.startContinuous();
    final runtime = daemon.runtimeOf('v1')!;
    final shell = daemon.vaults['v1']!.shell!;

    daemon.pause('v1');

    // A paused vault neither ingests nor pushes — neither through the
    // watcher flush nor through the public ingest seam.
    v1.write('during-pause.md', 'bulk surgery in progress\n');
    await runtime.flushPath('during-pause.md');
    await shell.ingestPath('during-pause.md');
    expect(shell.store.pendingPushCount, 0);
    expect(h.serverStore('db-one').get(v1.docId('during-pause.md')), isNull);

    // A remote change lands while paused (the listener drops it).
    await h.seedServerDoc(v1, 'remote.md', 'landed while paused\n'.codeUnits,
        database: 'db-one');

    // Resume runs a catch-up reconcile: the local edit pushes and the
    // dropped remote change materializes.
    daemon.resume('v1');
    await daemon.syncNow('v1');
    expect(await h.decryptServerText(v1, 'during-pause.md', database: 'db-one'),
        'bulk surgery in progress\n');
    expect(v1.file('remote.md').existsSync(), isTrue);
    expect(v1.file('remote.md').readAsStringSync(), 'landed while paused\n');

    await daemon.stopAll();
  });
}

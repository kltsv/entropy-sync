/// `vault_hist` RV6/RV7 — a rename that lands while an edit is still pending.
///
/// The daemon owns the idle window, so an edit can be waiting to be committed
/// when a rename is detected. The rename markers must not be written first:
/// `recordRename` would find the edited content unrecorded, anchor it as a
/// fresh root, and the edit would lose its edge — splitting one file's history
/// into two unrelated lives.
library;

import 'package:entropy_hist/entropy_hist.dart';
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  /// The harness profile, but with a **real** history window, so an edit can
  /// still be pending when the rename arrives (the default 0 flushes at once
  /// and hides the race).
  VaultProfile withIdleWindow(VaultProfile p) => VaultProfile(
        vaultId: p.vaultId,
        vaultRoot: p.vaultRoot,
        endpoint: p.endpoint,
        database: p.database,
        serverUser: p.serverUser,
        serverPassword: p.serverPassword,
        passphrase: p.passphrase,
        writerName: p.writerName,
        exclusions: p.exclusions,
        histIdleMillis: 600000,
        inlineThresholdBytes: p.inlineThresholdBytes,
        watchDebounceMillis: p.watchDebounceMillis,
      );

  test('an edit pending when a rename lands keeps its edge', () async {
    final daemon = Daemon(version: 'test', shellFactory: h.daemonShell);
    final v = h.handleFor('v1');
    v.write('a.md', 'one\n');
    await daemon.addVault(withIdleWindow(h.profileFor(v)));
    await daemon.syncNow();

    // Edit, then rename before the window can expire.
    v.write('a.md', 'two\n');
    await daemon.syncNow();
    v.file('a.md').renameSync(v.file('b.md').path);
    await daemon.syncNow();
    await daemon.stopAll(); // flushes anything still pending

    final store = FsHistStore(v.vaultRoot);
    final old = await store.listHeaders('a.md');
    final one = sha256Hex('one\n'.codeUnits);
    final two = sha256Hex('two\n'.codeUnits);

    // The edit is an edge from "one", not a second root.
    final roots =
        old.where((x) => x.type == HistFileType.snapshot).map((x) => x.version);
    expect(roots, [one],
        reason: 'the edited content must not be anchored as a fresh root — '
            'that would split the file into two unrelated lives');
    final patches = old.where((x) => x.type == HistFileType.patch).toList();
    expect(patches, hasLength(1));
    expect(patches.single.prev, one);
    expect(patches.single.version, two);

    // …and the rename marker still ends the old life at the edited state.
    final deleted = old.singleWhere((x) => x.type == HistFileType.deleted);
    expect(deleted.prev, two);
    expect(deleted.renamedTo, 'b.md');

    // The new name starts from the same content, so the two link up.
    final fresh = await store.listHeaders('b.md');
    expect(fresh.single.type, HistFileType.snapshot);
    expect(fresh.single.version, two);
    expect(fresh.single.renamedFrom, 'a.md');
  });
}

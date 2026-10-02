/// `vault_daemon` test-spec — "Noticing a divergence" (history-surface
/// R16–R18): the divergence count in status, derived from the graphs, kept
/// incrementally, and cleared everywhere by a marker that syncs.
library;

import 'package:entropy_hist/entropy_hist.dart';
import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;
  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  test(
      'a divergent line raises the count on every device, and a marker '
      'settles it everywhere', () async {
    // The file is created on a third device, so whichever of the two
    // concurrent edits wins LWW, the loser's writer is not on the primary
    // line — a line somebody else wrote, still open: divergent (`vault_hist`
    // reader rule 3), on every device alike.
    final tablet = await h.spawn('tablet');
    final mac = await h.spawn('mac');
    final desk = await h.spawn('desk');
    final all = [tablet, mac, desk];
    tablet.write('plan.md', 'A\n');
    await h.settle(all);
    expect(mac.file('plan.md').readAsStringSync(), 'A\n');
    expect(desk.file('plan.md').readAsStringSync(), 'A\n');
    for (final d in all) {
      expect(d.shell.divergent, 0);
    }

    // Concurrent edits: each device commits its own before seeing the other's.
    mac.write('plan.md', 'C\n');
    desk.write('plan.md', 'D\n');
    await mac.shell.reconcile(); // records C, pushes it
    await desk.shell.reconcile(); // records D, pushes it — a real conflict
    await h.settle(all, rounds: 6); // history files converge

    final live = mac.file('plan.md').readAsStringSync();
    for (final d in all) {
      expect(d.file('plan.md').readAsStringSync(), live,
          reason: 'sync converged: one edit won LWW');
      expect(d.shell.divergent, 1,
          reason: '${d.name}: the loser is a divergent line — a count of '
              'files, derived from the graph');
    }
    final daemon = Daemon(version: 't', shellFactory: h.daemonShell);
    daemon.vaults['mac'] =
        VaultEntry(profile: h.profileFor(mac), shell: mac.shell);
    final status = daemon.status().vaults.single;
    expect(status.divergent, 1);
    expect(VaultStatus.fromJson(status.toJson()).divergent, 1,
        reason: 'carried over the wire as data');

    // The history surface's "leave mine as it is" on the mac: a marker naming
    // the losing leaf and the live version, written by the writer straight
    // into .hist/ — exactly what `hist merge --take live` does.
    final graph = await HistReader(FsHistStore(mac.vaultRoot))
        .graph('plan.md', liveHash: sha256OfText(live));
    final loser = graph.branches
        .singleWhere((b) => b.kind == HistBranchKind.divergent)
        .leaf;
    await mac.shell.hist.merge('plan.md', loser, sha256OfText(live));

    await h.settle(all, rounds: 4);
    for (final d in all) {
      expect(d.shell.divergent, 0,
          reason: '${d.name}: the marker propagated — nothing was told to '
              'this device locally');
      expect(d.shell.unsynced, 0);
    }
  });
}

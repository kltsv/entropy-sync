/// `vault_daemon` test-spec — "Local change detection (R10, RV4)": one
/// failing file (unreadable, vanishing mid-scan) must never abort the
/// reconcile pass or crash the daemon — it is skipped with a log line, every
/// other file syncs, and the failing file heals on a later pass.
library;

import 'dart:convert';
import 'dart:io';

import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late Harness h;

  setUp(() async => h = await Harness.start());
  tearDown(() => h.stop());

  test('one failing file never aborts the scan or crashes the daemon (R10)',
      () async {
    final handle = h.handleFor('mac');
    final logPath = p.join(h.tmp.path, 'guard.log');

    // A hasher that blows up on the poisoned content — standing in for an
    // unreadable or mid-scan-vanishing file inside the per-file ingest work.
    final shell = await productionShell(
      h.profileFor(handle),
      stateRoot: handle.stateRoot,
      log: DaemonLog(logPath, mirrorToStderr: false),
      notifier: (title, message) async {},
      hasher: (bytes) {
        if (utf8.decode(bytes, allowMalformed: true).contains('POISON')) {
          throw const FileSystemException('simulated unreadable file');
        }
        return sha256Of(bytes);
      },
    );
    handle.shell = shell;

    handle.write('good.md', 'fine\n');
    handle.write('bad.md', 'POISON\n');

    // The pass completes without throwing; the healthy file syncs.
    await shell.reconcile();
    expect(await h.decryptServerText(handle, 'good.md'), 'fine\n');
    expect(h.serverStore().get(handle.docId('bad.md')), isNull);
    expect(File(logPath).readAsStringSync(), contains('error'));

    // The failing file is retried on the next pass and heals.
    handle.write('bad.md', 'healed\n');
    await shell.reconcile();
    expect(await h.decryptServerText(handle, 'bad.md'), 'healed\n');
    await shell.stop();
  });
}

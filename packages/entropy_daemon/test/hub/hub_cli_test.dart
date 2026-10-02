/// `vault_sync_hub` C3 — headless parity for the verbs that need no host.
///
/// The SSH-dependent verbs are covered at the library level (`hub_test.dart`);
/// what matters here is that the CLI is a real surface over the same state
/// root, so a hub recorded by the console is visible to the CLI and back.
library;

import 'dart:io';

import 'package:entropy_daemon/entropy_daemon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String dill;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('hub-cli-');
    dill = p.join(tmp.path, 'entropy_daemon.dill');
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      p.join(Directory.current.path, 'bin', 'entropyd.dart'),
      '-o',
      dill,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<ProcessResult> cli(List<String> args) =>
      Process.run(Platform.resolvedExecutable, [dill, ...args]);

  test('a hub recorded by the CLI is the same one the library sees', () async {
    final stateRoot = p.join(tmp.path, 'state');

    final added = await cli([
      'hub',
      'add',
      '--state-root',
      stateRoot,
      '--label',
      'home',
      '--ssh',
      'root@203.0.113.10',
      '--domain',
      'sync.example.com',
      '--email',
      'owner@example.com',
    ]);
    expect(added.exitCode, 0, reason: '${added.stderr}');
    // It says plainly that nothing secret was stored (C1).
    expect(added.stdout as String, contains('Nothing secret was stored'));

    // The library reads exactly what the CLI wrote.
    final record = HubRegistry(stateRoot).find('home')!;
    expect(record.sshTarget, 'root@203.0.113.10');
    expect(record.endpoint, 'https://sync.example.com');

    final listed = await cli(['hub', 'list', '--state-root', stateRoot]);
    expect(listed.stdout as String, contains('home'));
    expect(listed.stdout as String, contains('https://sync.example.com'));

    // Forgetting a hub is local only — it never touches the server.
    final removed = await cli(
        ['hub', 'remove', '--state-root', stateRoot, '--label', 'home']);
    expect(removed.stdout as String, contains('server itself is untouched'));
    expect(HubRegistry(stateRoot).all(), isEmpty);
  });

  test('the hub verbs explain themselves and reject incomplete input',
      () async {
    final stateRoot = p.join(tmp.path, 'state2');

    final help = await cli(['hub']);
    expect(help.stdout as String, contains('grant create'));
    expect(help.stdout as String, contains('agent or ~/.ssh/config'));

    // A missing required option is a usage error, and nothing is recorded.
    final partial = await cli([
      'hub',
      'add',
      '--state-root',
      stateRoot,
      '--label',
      'home',
    ]);
    expect(partial.exitCode, 64);
    expect(partial.stderr as String, contains('--ssh'));
    expect(HubRegistry(stateRoot).all(), isEmpty);

    // Operating on a hub that was never recorded says so.
    final none = await cli(
        ['hub', 'db', 'list', '--state-root', stateRoot, '--label', 'nope']);
    expect(none.exitCode, 64);
    expect(none.stderr as String, contains('no hubs recorded'));
  });
}

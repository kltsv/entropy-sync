/// `vault_sync_hub` — the embedded server recipe must not drift.
///
/// `tools/vps-provision/remote-setup.sh` is the source of truth for what a hub
/// is: the shell path (`provision.sh`, the provisioning skill) and the daemon
/// both use it. The binary carries a verbatim copy so it can provision with no
/// repository on hand; this test is what keeps the two the same file.
library;

import 'dart:io';

import 'package:entropy_daemon/src/hub/remote_setup_script.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('the embedded recipe matches tools/vps-provision/remote-setup.sh', () {
    final repoRoot = p.normalize(p.join(Directory.current.path, '..', '..'));
    final source =
        File(p.join(repoRoot, 'tools/vps-provision/remote-setup.sh'));
    expect(
      source.existsSync(),
      isTrue,
      reason: 'the server recipe is missing at ${source.path}',
    );

    expect(
      remoteSetupScript,
      source.readAsStringSync(),
      reason: 'the embedded copy has drifted — run: '
          'dart run tool/sync_remote_setup.dart',
    );
  });

  test('the recipe is idempotent by construction and needs its inputs', () {
    // The two properties the hub relies on, asserted against the recipe itself
    // rather than a comment about it.
    expect(remoteSetupScript, contains('already exists — left as is'));
    expect(remoteSetupScript, contains('COUCH_ADMIN_PASS'));
    expect(remoteSetupScript, contains('SYNC_USER_PASS'));
    expect(remoteSetupScript, contains('require_valid_user'));
  });
}

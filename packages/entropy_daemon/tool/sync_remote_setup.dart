// Regenerate the embedded copy of the server recipe.
//
// `tools/vps-provision/remote-setup.sh` is the source of truth for what a hub
// is; the daemon binary carries a verbatim copy so it can provision one with
// no repository on hand (`vault_sync_hub`). Run this after editing the script:
//
//   dart run tool/sync_remote_setup.dart
//
// `test/hub_script_test.dart` fails if the two ever drift.
import 'dart:io';

import 'package:path/path.dart' as p;

void main() {
  final packageRoot = Directory.current.path;
  final repoRoot = p.normalize(p.join(packageRoot, '..', '..'));
  final source = File(p.join(repoRoot, 'tools/vps-provision/remote-setup.sh'));
  if (!source.existsSync()) {
    stderr.writeln('not found: ${source.path}');
    exit(1);
  }
  final script = source.readAsStringSync();
  if (script.contains("'''")) {
    stderr.writeln('the script contains a Dart raw-string terminator');
    exit(1);
  }
  File(p.join(packageRoot, 'lib/src/hub/remote_setup_script.dart'))
      .writeAsStringSync('''
// GENERATED — do not edit.
//
// A verbatim copy of `tools/vps-provision/remote-setup.sh`, embedded so the
// compiled binary can provision a hub with no repository checkout on hand.
// The shell script remains the source of truth for the server recipe;
// `hub_script_test.dart` fails if this copy drifts from it.
//
// Regenerate: tool/sync_remote_setup.dart
library;

const remoteSetupScript = r\'\'\'
$script\'\'\';
''');
  stdout.writeln('embedded ${script.length} bytes');
}

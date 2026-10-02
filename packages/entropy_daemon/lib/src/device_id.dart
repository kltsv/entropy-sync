import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// A stable, per-**device** identifier, persisted once under [dir].
///
/// The replication checkpoint key is `<direction>:<database>:<replicaId>`
/// (`vault_sync` R8). Two devices syncing the **same** vault (same database)
/// must therefore use **different** replica ids, or they would share — and
/// corrupt — each other's push checkpoint on the server (each device's local
/// sequence space is its own, so reading another device's `last_seq` skips
/// un-pushed changes). Keying the replica id by a per-device id makes that
/// impossible, so the same vault converges cleanly across a Mac, a second
/// desktop and the phone (scenario S1/S7).
String readOrCreateDeviceId(String dir) {
  final file = File(p.join(dir, 'device-id'));
  if (file.existsSync()) {
    final existing = file.readAsStringSync().trim();
    if (existing.isNotEmpty) return existing;
  }
  final id = _randomHex(16);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(id);
  return id;
}

/// The device-scoped replica id for a vault: `<vaultId>@<deviceId>`.
String replicaIdFor(String vaultId, String deviceId) => '$vaultId@$deviceId';

String _randomHex(int bytes) {
  final rng = Random.secure();
  return List.generate(
    bytes,
    (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

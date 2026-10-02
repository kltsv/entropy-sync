/// The headless desktop daemon (`entropyd`) of the entropy-sync stack.
/// `implements: vault_daemon`. A thin shell over the three core modules:
/// it owns each vault folder, composes `vault_crypto` between files and
/// `vault_sync`, records this machine's edits to multi-writer `vault_hist`,
/// and exposes an authenticated localhost control channel.
library;

export 'src/config.dart';
export 'src/control_client.dart';
export 'src/control_protocol.dart';
export 'src/control_server.dart';
export 'src/daemon.dart';
export 'src/device_id.dart';
export 'src/folder/folder_cursor.dart';
export 'src/folder/vault_folder.dart';
export 'src/hist_commit_queue.dart';
export 'src/hub/couch_admin.dart';
export 'src/hub/hub_registry.dart';
export 'src/hub/hub_service.dart';
export 'src/hub/ssh.dart';
export 'src/modules/history_module.dart';
export 'src/modules/sync_module.dart';
export 'src/os_integration.dart';
export 'src/secret_store.dart';
export 'src/transfer_cipher.dart';
export 'src/vault_registry.dart';
export 'src/vault_runtime.dart';
export 'src/vault_shell.dart';

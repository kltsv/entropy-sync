import 'dart:io';

import 'package:path/path.dart' as p;

/// OS-level side effects of the daemon (`vault_daemon` RV4, RV9): moving a
/// remotely-deleted file to the system trash and notifying the owner about a
/// conflict. Injectable so tests substitute fakes.

/// The signature of the trash move, injectable into the shell so tests can
/// force the deterministic fallback directory instead of the user's real
/// `~/.Trash` (`vault_daemon` RV4 — deletions are never irreversible).
typedef TrashFn = Future<String> Function(File file,
    {required String fallbackDir});

/// Move [file] to the user's trash (never irreversible deletion). On macOS this
/// is `~/.Trash`; elsewhere (or on failure) the file goes to [fallbackDir]
/// (the vault's state directory trash). A name collision gets a unique suffix.
Future<String> moveToTrash(File file, {required String fallbackDir}) async {
  final home = Platform.environment['HOME'];
  final trashDir =
      Platform.isMacOS && home != null ? p.join(home, '.Trash') : fallbackDir;
  try {
    return _moveInto(file, trashDir);
  } on FileSystemException {
    return _moveInto(file, fallbackDir);
  }
}

String _moveInto(File file, String dir) {
  Directory(dir).createSync(recursive: true);
  final base = p.basename(file.path);
  var target = p.join(dir, base);
  var n = 1;
  while (File(target).existsSync() || Directory(target).existsSync()) {
    final ext = p.extension(base);
    final stem = p.basenameWithoutExtension(base);
    target =
        p.join(dir, '$stem ${DateTime.now().millisecondsSinceEpoch}-$n$ext');
    n += 1;
  }
  try {
    file.renameSync(target);
  } on FileSystemException {
    // Cross-device: copy + delete.
    file.copySync(target);
    file.deleteSync();
  }
  return target;
}

/// Post an OS user notification (`vault_daemon` RV9 — conflict surfacing).
/// macOS: AppleScript notification; other platforms: no-op (the log still
/// records the event).
typedef Notifier = Future<void> Function(String title, String message);

Future<void> osNotify(String title, String message) async {
  if (!Platform.isMacOS) return;
  String esc(String s) => s.replaceAll('\\', r'\\').replaceAll('"', r'\"');
  await Process.run('/usr/bin/osascript', [
    '-e',
    'display notification "${esc(message)}" with title "${esc(title)}"',
  ]);
}

/// An append-only daemon log in the state directory (`vault_daemon`
/// RV10): sync activity, conflict resolutions, errors. One line per event,
/// ISO-8601 timestamps. Also mirrored to stderr for foreground runs.
class DaemonLog {
  DaemonLog(this.path, {this.mirrorToStderr = true});

  final String path;
  final bool mirrorToStderr;

  void log(String message) {
    final line = '${DateTime.now().toIso8601String()} $message';
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$line\n', mode: FileMode.append);
    } on FileSystemException {
      // Logging must never take the daemon down.
    }
    if (mirrorToStderr) stderr.writeln(line);
  }
}

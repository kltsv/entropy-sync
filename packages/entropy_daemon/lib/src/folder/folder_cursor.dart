import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// What the folder service last saw at one path.
class FolderSeen {
  const FolderSeen({
    required this.hash,
    required this.sizeBytes,
    required this.mtimeMillis,
  });

  final String hash;
  final int sizeBytes;
  final int mtimeMillis;

  Map<String, Object?> toJson() =>
      {'h': hash, 's': sizeBytes, 'm': mtimeMillis};

  static FolderSeen fromJson(Map<String, Object?> json) => FolderSeen(
        hash: json['h'] as String,
        sizeBytes: (json['s'] as num).toInt(),
        mtimeMillis: (json['m'] as num).toInt(),
      );
}

/// The folder service's **own** record of what it last saw
/// (`vault_folder` R6).
///
/// Deliberately not any module's state: change detection must work identically
/// with one module enabled, both, or none — a vault running history alone has
/// no replication cursor to borrow, and enabling a module later must not reset
/// or corrupt the other's view of the folder.
///
/// Size and modification time are the fast path; content is hashed only when
/// they differ.
class FolderCursor {
  FolderCursor(this.filePath);

  /// In-memory only — used by tests and ephemeral hosts.
  FolderCursor.inMemory() : filePath = null;

  final String? filePath;
  Map<String, FolderSeen>? _entries;

  Map<String, FolderSeen> get _all {
    final cached = _entries;
    if (cached != null) return cached;
    final path = filePath;
    if (path == null) return _entries = {};
    final file = File(path);
    if (!file.existsSync()) return _entries = {};
    try {
      final raw =
          (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
      return _entries = {
        for (final e in raw.entries)
          e.key: FolderSeen.fromJson((e.value as Map).cast<String, Object?>()),
      };
    } catch (_) {
      return _entries = {}; // a corrupt record behaves like "nothing seen"
    }
  }

  /// Every path the service currently has a record for.
  Iterable<String> get paths => _all.keys;

  /// What was last seen at [path], if anything.
  FolderSeen? seen(String path) => _all[path];

  bool get isEmpty => _all.isEmpty;

  /// Whether [hash] is exactly what we last saw at [path] (null = absent).
  bool matches(String path, String? hash) {
    final seen = _all[path];
    if (hash == null) return seen == null;
    return seen != null && seen.hash == hash;
  }

  /// Whether [file]'s size and mtime still match what we recorded — the fast
  /// path that avoids hashing an unchanged file.
  bool unchangedByStat(String path, File file) {
    final seen = _all[path];
    if (seen == null || !file.existsSync()) return false;
    final stat = file.statSync();
    return stat.size == seen.sizeBytes &&
        stat.modified.millisecondsSinceEpoch == seen.mtimeMillis;
  }

  FolderSeen record(String path, File file, String hash) {
    final stat = file.statSync();
    final seen = FolderSeen(
      hash: hash,
      sizeBytes: stat.size,
      mtimeMillis: stat.modified.millisecondsSinceEpoch,
    );
    _all[path] = seen;
    _flush();
    return seen;
  }

  void forget(String path) {
    if (_all.remove(path) != null) _flush();
  }

  /// Adopt records the service did not observe itself — restoring a state a
  /// consumer failed to apply (`VaultFolder.replay`).
  void seed(Map<String, FolderSeen> entries) {
    if (entries.isEmpty) return;
    _all.addAll(entries);
    _flush();
  }

  void _flush() {
    final path = filePath;
    if (path == null) return;
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({for (final e in _all.entries) e.key: e.value.toJson()}),
    );
  }

  /// Where a vault's cursor lives under the daemon's per-vault state dir.
  static String pathIn(String stateDir) => p.join(stateDir, 'folder.json');
}

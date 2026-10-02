import 'dart:convert';
import 'dart:io';

/// The daemon's per-vault reconciliation cursor (`vault_daemon` RV4):
/// for every path, the content hash + mtime + size the daemon last brought
/// into agreement with the replica — written after each ingest and each
/// materialization — plus the replica revision that agreement corresponds to
/// ([rev]): the parent a racing local edit is ingested against, and the skip
/// key that lets a reconcile pass leave already-materialized winners
/// undecrypted. The mtime+size pair is the cheap fast path of change
/// detection; the hash is the truth. Persisted in the vault's state directory
/// so a restart resumes instead of re-hashing blindly, and so edits made while
/// the daemon was down are detected as local changes.
class LastSyncedEntry {
  const LastSyncedEntry({
    required this.hash,
    required this.mtime,
    required this.size,
    this.rev,
  });

  final String hash;
  final int mtime;
  final int size;

  /// The replica revision this path's on-disk content corresponds to (the
  /// revision last ingested or materialized); `null` while the path has no
  /// replica revision yet.
  final String? rev;

  Map<String, Object?> toJson() => {
        'h': hash,
        'm': mtime,
        's': size,
        if (rev != null) 'r': rev,
      };

  static LastSyncedEntry fromJson(Map<String, Object?> json) => LastSyncedEntry(
        hash: json['h'] as String,
        mtime: (json['m'] as num).toInt(),
        size: (json['s'] as num).toInt(),
        rev: json['r'] as String?,
      );
}

class LastSyncedIndex {
  LastSyncedIndex(this.filePath) {
    _load();
  }

  final String filePath;
  final Map<String, LastSyncedEntry> _entries = {};

  Iterable<String> get paths => _entries.keys;

  LastSyncedEntry? operator [](String path) => _entries[path];

  void set(String path, LastSyncedEntry entry) {
    _entries[path] = entry;
    _save();
  }

  void remove(String path) {
    if (_entries.remove(path) != null) _save();
  }

  void _load() {
    final file = File(filePath);
    if (!file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      json.forEach((path, value) {
        _entries[path] =
            LastSyncedEntry.fromJson((value as Map).cast<String, Object?>());
      });
    } catch (_) {
      // A corrupt or wrong-shape cursor (truncated write, foreign JSON) is
      // not fatal: the next rescan re-hashes everything.
      _entries.clear();
    }
  }

  /// Atomic persist: temp file in the same directory + rename, so a crash
  /// mid-write can never leave a truncated cursor behind (a lost cursor
  /// forces a full re-hash and can resurrect remotely-deleted files).
  void _save() {
    final file = File(filePath);
    file.parent.createSync(recursive: true);
    final temp = File('$filePath.tmp');
    temp.writeAsStringSync(
      jsonEncode({for (final e in _entries.entries) e.key: e.value.toJson()}),
      flush: true,
    );
    temp.renameSync(filePath);
  }
}

import 'dart:io';

/// Durable key→JSON storage the host supplies to a [LocalStore]. The store keeps
/// its working state in memory and writes through to this backend on every
/// mutation, so a restart rebuilds the exact same replica. An in-memory backend
/// is used in tests; a file-backed one persists on device.
abstract interface class StorageBackend {
  /// Load every key→value pair (the whole store) at construction.
  Map<String, String> loadAll();

  /// Write (or overwrite) one key.
  void put(String key, String value);

  /// Delete one key.
  void remove(String key);
}

/// A volatile [StorageBackend] backed by a plain map — the default for tests and
/// for a replica that need not survive a restart.
class MemoryBackend implements StorageBackend {
  MemoryBackend([Map<String, String>? seed]) : _data = {...?seed};

  final Map<String, String> _data;

  @override
  Map<String, String> loadAll() => Map<String, String>.from(_data);

  @override
  void put(String key, String value) => _data[key] = value;

  @override
  void remove(String key) => _data.remove(key);
}

/// A durable [StorageBackend] that keeps one file per key under a directory, so a
/// replica survives a restart. The daemon uses this to persist each vault's
/// replica on device. Keys are URL-encoded to flat filenames.
class FileBackend implements StorageBackend {
  FileBackend(String directoryPath) : _dir = Directory(directoryPath) {
    _dir.createSync(recursive: true);
  }

  final Directory _dir;

  @override
  Map<String, String> loadAll() {
    final out = <String, String>{};
    for (final entity in _dir.listSync()) {
      if (entity is File) {
        final key = Uri.decodeComponent(entity.uri.pathSegments.last);
        out[key] = entity.readAsStringSync();
      }
    }
    return out;
  }

  @override
  void put(String key, String value) {
    _fileFor(key).writeAsStringSync(value);
  }

  @override
  void remove(String key) {
    final f = _fileFor(key);
    if (f.existsSync()) f.deleteSync();
  }

  File _fileFor(String key) =>
      File('${_dir.path}${Platform.pathSeparator}${Uri.encodeComponent(key)}');
}

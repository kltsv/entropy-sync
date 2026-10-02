/// The injected blob store of `vault_sync` (RV4): attachment bytes rest here,
/// keyed by content digest. Attachments **stream** through the module — they
/// are never held whole in memory or inside the structured replica state.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The result of streaming bytes into a [BlobStore]: the content [digest] the
/// bytes now rest under and their total [length].
class BlobHandle {
  const BlobHandle({required this.digest, required this.length});

  final String digest;
  final int length;

  @override
  String toString() => 'BlobHandle($digest, $length bytes)';
}

/// Digest-keyed storage for attachment bytes (`vault_sync` RV4). The host
/// injects one per replica; the daemon backs it with files in its state
/// directory, tests with memory. Content-addressed: identical bytes land
/// under the identical digest on every replica.
abstract interface class BlobStore {
  /// Stream [bytes] in, computing the content digest incrementally, and
  /// return the handle. The stream is consumed chunk by chunk — the store
  /// must not require the whole attachment in memory.
  Future<BlobHandle> put(Stream<List<int>> bytes);

  /// Stream the bytes stored under [digest] back out.
  Stream<List<int>> openRead(String digest);

  /// Whether bytes rest under [digest].
  Future<bool> contains(String digest);

  /// Total length of the bytes under [digest].
  Future<int> length(String digest);
}

/// The digest format shared by every [BlobStore]: `sha256-<64 lowercase hex>`
/// of the attachment bytes.
String blobDigestOf(Digest digest) => 'sha256-$digest';

/// A volatile [BlobStore] backed by a map — for tests and replicas that need
/// not survive a restart.
class MemoryBlobStore implements BlobStore {
  final Map<String, Uint8List> _blobs = {};

  @override
  Future<BlobHandle> put(Stream<List<int>> bytes) async {
    final builder = BytesBuilder(copy: false);
    final sink = _DigestSink();
    final hasher = sha256.startChunkedConversion(sink);
    await for (final chunk in bytes) {
      hasher.add(chunk);
      builder.add(chunk);
    }
    hasher.close();
    final digest = blobDigestOf(sink.events.single);
    final data = builder.takeBytes();
    _blobs[digest] = data;
    return BlobHandle(digest: digest, length: data.length);
  }

  @override
  Stream<List<int>> openRead(String digest) async* {
    final data = _blobs[digest];
    if (data == null) {
      throw StateError('no blob under $digest');
    }
    const chunkSize = 64 * 1024;
    for (var i = 0; i < data.length; i += chunkSize) {
      yield Uint8List.sublistView(
          data, i, i + chunkSize > data.length ? data.length : i + chunkSize);
    }
    if (data.isEmpty) yield Uint8List(0);
  }

  @override
  Future<bool> contains(String digest) async => _blobs.containsKey(digest);

  @override
  Future<int> length(String digest) async {
    final data = _blobs[digest];
    if (data == null) throw StateError('no blob under $digest');
    return data.length;
  }
}

/// A durable [BlobStore] keeping one file per digest under a directory — the
/// daemon's production store. Bytes stream into a temp file while the digest
/// is computed, then rename into place, so peak memory is one chunk (RV4).
class FsBlobStore implements BlobStore {
  FsBlobStore(String dir) : _dir = Directory(dir) {
    _dir.createSync(recursive: true);
  }

  final Directory _dir;
  int _tmpCounter = 0;

  File _fileFor(String digest) => File(p.join(_dir.path, digest));

  @override
  Future<BlobHandle> put(Stream<List<int>> bytes) async {
    final temp = File(p.join(
        _dir.path,
        '.tmp-${DateTime.now().microsecondsSinceEpoch}-'
        '${_tmpCounter++}'));
    final sink = _DigestSink();
    final hasher = sha256.startChunkedConversion(sink);
    var length = 0;
    final out = temp.openWrite();
    try {
      await for (final chunk in bytes) {
        hasher.add(chunk);
        length += chunk.length;
        out.add(chunk);
      }
      await out.flush();
    } finally {
      await out.close();
    }
    hasher.close();
    final digest = blobDigestOf(sink.events.single);
    final target = _fileFor(digest);
    if (target.existsSync()) {
      // Content-addressed: identical bytes already rest here.
      temp.deleteSync();
    } else {
      temp.renameSync(target.path);
    }
    return BlobHandle(digest: digest, length: length);
  }

  @override
  Stream<List<int>> openRead(String digest) => _fileFor(digest).openRead();

  @override
  Future<bool> contains(String digest) async => _fileFor(digest).existsSync();

  @override
  Future<int> length(String digest) async => _fileFor(digest).lengthSync();
}

/// A tiny sink collecting the chunked sha256 conversion's single digest.
class _DigestSink implements Sink<Digest> {
  final List<Digest> events = [];

  @override
  void add(Digest data) => events.add(data);

  @override
  void close() {}
}

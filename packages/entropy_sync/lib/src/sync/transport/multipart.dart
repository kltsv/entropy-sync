/// Minimal `multipart/related` writer and streaming parser (`vault_sync`
/// RV4) — attachment transfer never buffers the bytes whole: the writer
/// splices a blob-store stream between boundary frames, and the reader emits
/// each part's body incrementally while scanning for the `\r\n--boundary`
/// delimiter. No external dependencies.
///
/// Frame shape (exactly what CouchDB's own replicator speaks):
///
/// ```
/// --{boundary}\r\n
/// Content-Type: application/json\r\n
/// \r\n
/// {document JSON}\r\n
/// --{boundary}\r\n
/// Content-Type: application/octet-stream\r\n
/// \r\n
/// {raw attachment bytes}\r\n
/// --{boundary}--\r\n
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

final Random _random = Random();

/// Mint a random multipart boundary.
String mintBoundary() {
  final buf = StringBuffer('entropy-sync-');
  for (var i = 0; i < 24; i++) {
    buf.write('0123456789abcdef'[_random.nextInt(16)]);
  }
  return buf.toString();
}

/// Extract the `boundary` parameter from a `multipart/related; boundary=…`
/// content-type header value, or `null` when absent.
String? boundaryOf(String? contentType) {
  if (contentType == null) return null;
  for (final part in contentType.split(';')) {
    final trimmed = part.trim();
    if (trimmed.toLowerCase().startsWith('boundary=')) {
      var value = trimmed.substring('boundary='.length);
      if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
        value = value.substring(1, value.length - 1);
      }
      return value;
    }
  }
  return null;
}

List<int> _jsonPartHeader(String boundary) =>
    ascii.encode('--$boundary\r\nContent-Type: application/json\r\n\r\n');

List<int> _attachmentPartHeader(String boundary) => ascii.encode(
    '\r\n--$boundary\r\nContent-Type: application/octet-stream\r\n\r\n');

List<int> _closing(String boundary) => ascii.encode('\r\n--$boundary--\r\n');

/// The exact byte length the [multipartRelatedBody] stream will produce —
/// lets uploads carry a `Content-Length` while still streaming.
int multipartRelatedLength({
  required int docJsonLength,
  required int attachmentLength,
  required String boundary,
}) =>
    _jsonPartHeader(boundary).length +
    docJsonLength +
    _attachmentPartHeader(boundary).length +
    attachmentLength +
    _closing(boundary).length;

/// Frame a document JSON and a streamed attachment as `multipart/related`
/// (RV4). The attachment stream is spliced through chunk by chunk.
Stream<List<int>> multipartRelatedBody({
  required List<int> docJson,
  required Stream<List<int>> attachment,
  required String boundary,
}) async* {
  yield _jsonPartHeader(boundary);
  yield docJson;
  yield _attachmentPartHeader(boundary);
  yield* attachment;
  yield _closing(boundary);
}

/// One parsed part: its headers and a body stream that must be fully drained
/// before [MultipartReader.nextPart] is called again.
class MultipartPart {
  MultipartPart(this.headers, this.body);

  /// Header names lowercased.
  final Map<String, String> headers;
  final Stream<List<int>> body;
}

/// A streaming `multipart/related` parser: parts come out in order, each
/// body as an incremental stream — the attachment part flows straight into
/// the blob store while the transport is still receiving bytes (RV4).
///
/// Throws [FormatException] on malformed framing.
class MultipartReader {
  MultipartReader(Stream<List<int>> source, String boundary)
      : _source = StreamIterator(source),
        _delimiter = ascii.encode('\r\n--$boundary') {
    // A virtual leading CRLF lets the very first `--boundary` line match the
    // same `\r\n--boundary` delimiter as every later one.
    _buffer.addAll(const [13, 10]);
  }

  final StreamIterator<List<int>> _source;
  final List<int> _delimiter;
  final List<int> _buffer = [];
  int _start = 0;
  bool _done = false;
  bool _first = true;
  bool _inPart = false;

  int get _available => _buffer.length - _start;

  Future<bool> _fill() async {
    if (_start > 64 * 1024) {
      _buffer.removeRange(0, _start);
      _start = 0;
    }
    if (!await _source.moveNext()) return false;
    _buffer.addAll(_source.current);
    return true;
  }

  Future<void> _ensure(int n) async {
    while (_available < n) {
      if (!await _fill()) {
        throw const FormatException('truncated multipart body');
      }
    }
  }

  Uint8List _take(int n) {
    final out = Uint8List.fromList(_buffer.sublist(_start, _start + n));
    _start += n;
    return out;
  }

  void _skip(int n) => _start += n;

  /// Index (relative to the unread window) of the delimiter, or -1.
  int _indexOfDelimiter() {
    final limit = _buffer.length - _delimiter.length;
    outer:
    for (var i = _start; i <= limit; i++) {
      for (var j = 0; j < _delimiter.length; j++) {
        if (_buffer[i + j] != _delimiter[j]) continue outer;
      }
      return i - _start;
    }
    return -1;
  }

  Future<void> _skipToDelimiter() async {
    while (true) {
      final idx = _indexOfDelimiter();
      if (idx >= 0) {
        _skip(idx + _delimiter.length);
        return;
      }
      // Drop everything that cannot be a delimiter prefix.
      final keep = _delimiter.length - 1;
      if (_available > keep) _skip(_available - keep);
      if (!await _fill()) {
        throw const FormatException('multipart boundary never found');
      }
    }
  }

  /// Consume the rest of the source stream (the closing `--boundary--`
  /// tail / epilogue) to end-of-stream. Without this the underlying HTTP
  /// response is never fully drained, so its connection cannot return to the
  /// keep-alive pool — one stranded socket per multipart fetch (RV4).
  Future<void> drainEpilogue() async {
    if (_inPart) {
      throw StateError('previous multipart body not fully drained');
    }
    while (await _source.moveNext()) {}
    _buffer.clear();
    _start = 0;
    _done = true;
  }

  /// Cancel the underlying source subscription — the error-path counterpart
  /// of [drainEpilogue]: releases the connection without reading the rest.
  Future<void> cancel() async {
    _done = true;
    await _source.cancel();
  }

  /// The next part, or `null` after the closing boundary. The previous
  /// part's body must have been drained.
  Future<MultipartPart?> nextPart() async {
    if (_done) return null;
    if (_inPart) {
      throw StateError('previous multipart body not fully drained');
    }
    if (_first) {
      _first = false;
      await _skipToDelimiter();
    }
    await _ensure(2);
    if (_buffer[_start] == 0x2d && _buffer[_start + 1] == 0x2d) {
      _done = true; // closing `--boundary--`
      return null;
    }
    if (_buffer[_start] != 13 || _buffer[_start + 1] != 10) {
      throw const FormatException('malformed bytes after multipart boundary');
    }
    _skip(2);
    final headers = await _readHeaders();
    _inPart = true;
    return MultipartPart(headers, _partBody());
  }

  Future<Map<String, String>> _readHeaders() async {
    const crlfcrlf = [13, 10, 13, 10];
    while (true) {
      final limit = _buffer.length - crlfcrlf.length;
      var found = -1;
      outer:
      for (var i = _start; i <= limit; i++) {
        for (var j = 0; j < crlfcrlf.length; j++) {
          if (_buffer[i + j] != crlfcrlf[j]) continue outer;
        }
        found = i;
        break;
      }
      if (found >= 0) {
        final raw = ascii.decode(_take(found - _start));
        _skip(crlfcrlf.length);
        final headers = <String, String>{};
        for (final line in raw.split('\r\n')) {
          final colon = line.indexOf(':');
          if (colon <= 0) continue;
          headers[line.substring(0, colon).trim().toLowerCase()] =
              line.substring(colon + 1).trim();
        }
        return headers;
      }
      if (!await _fill()) {
        throw const FormatException('truncated multipart headers');
      }
    }
  }

  Stream<List<int>> _partBody() async* {
    while (true) {
      final idx = _indexOfDelimiter();
      if (idx >= 0) {
        if (idx > 0) yield _take(idx);
        _skip(_delimiter.length);
        _inPart = false;
        return;
      }
      final emit = _available - (_delimiter.length - 1);
      if (emit > 0) {
        yield _take(emit);
      }
      if (!await _fill()) {
        throw const FormatException('truncated multipart part body');
      }
    }
  }
}

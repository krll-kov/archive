import 'dart:async';
import 'dart:convert';

import '../../archive/archive_file.dart';
import '../../util/cancellable_stream.dart';
import '../../util/chunked_sink.dart';
import '../zip_encoder.dart';
import '../zlib/deflate.dart';

/// zip as a `Stream`, writing only. Reading needs the central directory, which
/// sits at the end of the archive, so a forward-only source cannot be read
class ZipCodec {
  final int level;
  final String? password;
  final Encoding filenameEncoding;

  /// See [ZipChunkedEncoder.streamed]
  final bool streamed;

  const ZipCodec(
      {this.level = DeflateLevel.bestSpeed,
      this.password,
      this.filenameEncoding = const Utf8Codec(),
      this.streamed = true});

  ZipStreamEncoder get encoder => ZipStreamEncoder(
      level: level,
      password: password,
      filenameEncoding: filenameEncoding,
      streamed: streamed);
}

/// The codec with its defaults, for `entries.transform(zipCodec.encoder)`
const zipCodec = ZipCodec();

/// [ZipChunkedEncoder] behind the shape the other codecs use
class ZipStreamEncoder extends StreamTransformerBase<ArchiveFile, List<int>> {
  final int level;
  final String? password;
  final Encoding filenameEncoding;
  final bool streamed;

  const ZipStreamEncoder(
      {this.level = DeflateLevel.bestSpeed,
      this.password,
      this.filenameEncoding = const Utf8Codec(),
      this.streamed = true});

  @override
  Stream<List<int>> bind(Stream<ArchiveFile> stream) =>
      cancellableStream<ArchiveFile, List<int>>(
          stream, (input, signal) => _write(input, signal));

  Stream<List<int>> _write(
      StreamIterator<ArchiveFile> input, CancelSignal signal) async* {
    final held = <List<int>>[];
    final encoder = ZipChunkedEncoder(_Pieces(held),
        level: level,
        password: password,
        filenameEncoding: filenameEncoding,
        streamed: streamed);
    while (await input.moveNext()) {
      encoder.add(input.current);
      while (held.isNotEmpty) {
        yield held.removeAt(0);
      }
    }
    if (signal.cancelled) {
      return;
    }
    encoder.close();
    while (held.isNotEmpty) {
      yield held.removeAt(0);
    }
  }
}

class _Pieces implements Sink<List<int>> {
  _Pieces(this._held);

  final List<List<int>> _held;

  @override
  void add(List<int> data) => _held.add(data);

  @override
  void close() {}
}

/// Writes a zip into a `Sink` an entry at a time, reading nothing back. One
/// entry is held, since a local header carries the check and the compressed
/// size ahead of the bytes they describe, unless [streamed] moves them behind
class ZipChunkedEncoder {
  /// Where the archive goes. [close] closes it, which flushes a codec under it
  final Sink<List<int>> output;

  /// Deflates an entry straight into [output], its check and sizes behind the
  /// data, so the peak is one deflate buffer rather than the largest entry.
  /// Turn it off to get the bytes `ZipEncoder.encodeBytes` writes
  final bool streamed;

  ZipChunkedEncoder(this.output,
      {int level = DeflateLevel.bestSpeed,
      String? password,
      Encoding filenameEncoding = const Utf8Codec(),
      DateTime? modified,
      this.streamed = true})
      : _encoder = ZipEncoder(
            password: password,
            filenameEncoding: filenameEncoding,
            streamed: streamed) {
    _encoder.startEncode(_out, level: level, modified: modified);
  }

  final ZipEncoder _encoder;
  late final _out = SinkOutputStream(output);
  var _closed = false;

  void add(ArchiveFile entry) {
    if (_closed) {
      throw StateError('Cannot add to a closed encoder');
    }
    _encoder.add(entry);
  }

  /// The central directory and the record that points at it, then the sink
  void close({String? comment = ''}) {
    if (_closed) {
      return;
    }
    _closed = true;
    _encoder.endEncode(comment: comment);
    output.close();
  }
}

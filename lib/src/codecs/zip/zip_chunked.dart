import 'dart:async';
import 'dart:convert';

import '../../archive/archive_file.dart';
import '../../util/cancellable_stream.dart';
import '../../util/chunked_sink.dart';
import '../zip_encoder.dart';
import '../zlib/deflate.dart';

/// zip through `transform`, writing only. The encoder takes entries and not
/// bytes. That makes it a `StreamTransformer`. There is no decoder, since
/// reading needs the central directory at the end of the archive
class ZipCodec {
  final int level;
  final String? password;
  final Encoding filenameEncoding;

  /// See [ZipChunkedEncoder.streamed]
  final bool streamed;

  /// See [ZipEncoderTransformer.autoClose]
  final bool autoClose;

  const ZipCodec(
      {this.level = DeflateLevel.bestSpeed,
      this.password,
      this.filenameEncoding = const Utf8Codec(),
      this.streamed = true,
      this.autoClose = false});

  ZipEncoderTransformer get encoder => ZipEncoderTransformer(
      level: level,
      password: password,
      filenameEncoding: filenameEncoding,
      streamed: streamed,
      autoClose: autoClose);
}

/// The codec with its defaults, for `entries.transform(zipCodec.encoder)`
const zipCodec = ZipCodec();

/// [ZipChunkedEncoder] behind `zipCodec.encoder`. It takes entries and writes
/// bytes. That makes it a `StreamTransformer` and not a `Converter`
class ZipEncoderTransformer
    extends StreamTransformerBase<ArchiveFile, List<int>> {
  final int level;
  final String? password;
  final Encoding filenameEncoding;
  final bool streamed;

  /// Closes each entry once it is written, the way `ZipEncoder.add` does. Off
  /// by default, as it is on `ZipEncoder.encodeStream`. The entries belong to
  /// whoever opened them, and whoever opened a file closes it
  final bool autoClose;

  const ZipEncoderTransformer(
      {this.level = DeflateLevel.bestSpeed,
      this.password,
      this.filenameEncoding = const Utf8Codec(),
      this.streamed = true,
      this.autoClose = false});

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
      final entry = input.current;
      try {
        // Header first, then the content in pieces. A reader gets the first
        // bytes before the entry is fully deflated. On the web the body is one
        // step, because deflate there only runs whole
        final body = encoder.addHeader(entry);
        while (held.isNotEmpty) {
          yield held.removeAt(0);
        }
        if (body == null) {
          continue;
        }
        try {
          while (body.step()) {
            while (held.isNotEmpty) {
              yield held.removeAt(0);
            }
          }
          body.finish();
          while (held.isNotEmpty) {
            yield held.removeAt(0);
          }
        } finally {
          // A cancel stops at one of the yields above and finish never ran
          body.cancel();
        }
      } finally {
        // A cancel lands on a yield above. That is why this is a finally
        if (autoClose) {
          entry.closeSync();
        }
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
  /// Where the archive goes. [close] closes it and flushes a codec under it
  final Sink<List<int>> output;

  /// Deflates an entry straight into [output], its check and sizes behind the
  /// data. The peak is then one deflate buffer rather than the largest entry.
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

  /// Writes [entry]'s local header and returns its body. Null if the entry is
  /// already written whole. The entry is left open for whoever owns it
  ZipEntryBody? addHeader(ArchiveFile entry) {
    if (_closed) {
      throw StateError('Cannot add to a closed encoder');
    }
    return _encoder.addHeader(entry, autoClose: false);
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

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../util/adler32.dart';
import '../../util/archive_exception.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_zlib_decoder_base.dart';
import '_zlib_encoder_base.dart';

const platformZLibDecoder = _ZLibDecoder();

/// Decompress data with the zlib format decoder.
class _ZLibDecoder extends ZLibDecoderBase {
  const _ZLibDecoder();

  @override
  Uint8List decodeBytes(List<int> data,
      {bool verify = false, bool raw = false, bool throwOnError = false}) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final trailerLength = raw ? 0 : 4;
    if (!raw && bytes.length < trailerLength + 2) {
      _fail(verify || throwOnError);
      return Uint8List(0);
    }
    final Uint8List out;
    try {
      out = ZLibCodec(raw: raw).decode(
              Uint8List.sublistView(bytes, 0, bytes.length - trailerLength))
          as Uint8List;
    } catch (error) {
      _fail(verify || throwOnError, error);
      return Uint8List(0);
    }
    if (verify && !raw) {
      _checkAdler(
          Uint8List.sublistView(bytes, bytes.length - 4), getAdler32(out));
    }
    return out;
  }

  @override
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool raw = false, bool throwOnError = false}) {
    // dart:io reports a wrong checksum and damaged data with one message, so
    // it never gets the Adler-32 and we check it ourselves
    final trailerLength = raw ? 0 : 4;
    final seen = input.length;
    if (!raw && seen < trailerLength + 2) {
      return _fail(verify || throwOnError);
    }
    final outSink = ZLibOutputSink(output);
    if (verify && !raw) {
      outSink
        ..value = 1
        ..update = getAdler32;
    }
    try {
      final inSink =
          ZLibCodec(raw: raw).decoder.startChunkedConversion(outSink);
      var left = seen - trailerLength;
      while (left > 0) {
        final chunk = input.readBytes(min(8 * 1024, left)).toUint8List();
        if (chunk.isEmpty) {
          break;
        }
        inSink.add(chunk);
        left -= chunk.length;
      }
      inSink.close();
    } catch (error) {
      return _fail(verify || throwOnError, error);
    }
    if (raw) {
      return true;
    }
    final trailer = input.readBytes(4).toUint8List();
    if (verify) {
      _checkAdler(trailer, outSink.value);
    }
    return true;
  }

  static bool _fail(bool strict, [Object? error]) {
    if (strict) {
      throw ArchiveException(
          error == null ? 'Invalid zlib data' : 'Invalid zlib data: $error');
    }
    return false;
  }

  static void _checkAdler(Uint8List trailer, int sum) {
    final adler = (trailer[0] << 24) |
        (trailer[1] << 16) |
        (trailer[2] << 8) |
        trailer[3];
    if (sum != adler) {
      throw ArchiveChecksumException('Invalid zlib checksum');
    }
  }
}

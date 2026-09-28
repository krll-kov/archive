import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../util/adler32.dart';
import '../../util/archive_exception.dart';
import '../../util/decode_guard.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
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
    var out = Uint8List(0);
    final partial = OutputMemoryStream();
    guardDecode('zlib', verify, throwOnError, () {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      final trailerLength = raw ? 0 : 4;
      if (!raw && bytes.length < trailerLength + 2) {
        return false;
      }
      out = convertKeepingPartial(
          ZLibCodec(raw: raw).decoder,
          [Uint8List.sublistView(bytes, 0, bytes.length - trailerLength)],
          partial);
      if (verify && !raw) {
        checkZlibAdler(
            Uint8List.sublistView(
                bytes, max(0, bytes.length - 4 - zlibAdlerWindow)),
            getAdler32(out));
      }
      return true;
    });
    if (partial.length > 0) {
      out = partial.getBytes();
    }
    return out;
  }

  @override
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool raw = false, bool throwOnError = false}) {
    return guardDecode('zlib', verify, throwOnError,
        () => _decodeStream(input, output, verify, raw));
  }

  bool _decodeStream(
      InputStream input, OutputStream output, bool verify, bool raw) {
    // dart:io reports a wrong checksum and damaged data with one message, so
    // it never gets the Adler-32 and we check it ourselves
    final trailerLength = raw ? 0 : 4;
    final seen = input.length;
    if (!raw && seen < trailerLength + 2) {
      return false;
    }
    final outSink = ZLibOutputSink(output);
    if (verify && !raw) {
      outSink
        ..value = 1
        ..update = getAdler32;
    }
    final inSink = ZLibCodec(raw: raw).decoder.startChunkedConversion(outSink);
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
    if (raw) {
      return true;
    }
    if (!verify) {
      input.skip(4);
      return true;
    }
    final back = min(zlibAdlerWindow, seen - trailerLength - left);
    input.rewind(back);
    checkZlibAdler(input.readBytes(back + 4).toUint8List(), outSink.value);
    return true;
  }
}

const zlibAdlerWindow = 4096;

void checkZlibAdler(Uint8List tail, int sum) {
  for (var at = tail.length - 4; at >= 0; at--) {
    final adler = (tail[at] << 24) |
        (tail[at + 1] << 16) |
        (tail[at + 2] << 8) |
        tail[at + 3];
    if (sum == adler) {
      return;
    }
  }
  throw ArchiveChecksumException('Invalid zlib checksum');
}

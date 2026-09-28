import 'dart:typed_data';

import '../../util/adler32.dart';
import '../../util/archive_exception.dart';
import '../../util/byte_order.dart';
import '../../util/decode_guard.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '_zlib_decoder_base.dart';
import 'inflate.dart';

const platformZLibDecoder = _ZLibDecoder();

/// Decompress data with the zlib format decoder.
class _ZLibDecoder extends ZLibDecoderBase {
  static const deflate = 8;

  const _ZLibDecoder();

  @override
  Uint8List decodeBytes(List<int> data,
      {bool verify = false, bool raw = false, bool throwOnError = false}) {
    final output = OutputMemoryStream();
    decodeStream(
        InputMemoryStream(data, byteOrder: ByteOrder.bigEndian), output,
        verify: verify, raw: raw, throwOnError: throwOnError);
    return output.getBytes();
  }

  @override
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool raw = false, bool throwOnError = false}) {
    final held = input.byteOrder;
    input.byteOrder = ByteOrder.bigEndian;
    try {
      return guardDecode('zlib', verify, throwOnError,
          () => _decode(input, output, verify, raw));
    } finally {
      input.byteOrder = held;
    }
  }

  bool _decode(InputStream input, OutputStream output, bool verify, bool raw) {
    Uint8List? buffer;

    if (input.isEOS) {
      return false;
    }

    while (!input.isEOS) {
      if (buffer != null) {
        output.writeBytes(buffer);
      }

      /*
       * The zlib format has the following structure:
       * CMF  1 byte
       * FLG 1 byte
       * [DICT_ID 4 bytes]? (if FLAG has FDICT (bit 5) set)
       * <compressed data>
       * ADLER32 4 bytes
       * ----
       * CMF:
       *    bits [0, 3] Compression Method, DEFLATE = 8
       *    bits [4, 7] Compression Info, base-2 logarithm of the LZ77 window
       *                size, minus eight (CINFO=7 indicates a 32K window size).
       * FLG:
       *    bits [0, 4] FCHECK (check bits for CMF and FLG)
       *    bits [5]    FDICT (preset dictionary)
       *    bits [6, 7] FLEVEL (compression level)
       */
      if (!raw) {
        // Both reads below are unchecked
        if (input.length < 2) {
          return buffer != null;
        }
        final cmf = input.readByte();
        final flg = input.readByte();

        final method = cmf & 8;
        final cinfo = (cmf >> 3) & 8; // ignore: unused_local_variable

        if (method != deflate) {
          //throw ArchiveException('Only DEFLATE compression supported: $method');
          return buffer != null;
        }

        final fcheck = flg & 16; // ignore: unused_local_variable
        final fdict = (flg & 32) >> 5;
        final flevel = (flg & 64) >> 6; // ignore: unused_local_variable

        // FCHECK is set such that (cmf * 256 + flag) must be a multiple of 31.
        if (((cmf * 256) + flg) % 31 != 0) {
          //throw ArchiveException('Invalid FCHECK');
          return buffer != null;
        }

        if (fdict != 0) {
          /*dictid =*/ input.readUint32();
          //throw ArchiveException('FDICT Encoding not currently supported');
          return false;
        }
      }

      // Inflate
      final inflate = Inflate.stream(input);
      buffer = inflate.getBytes();
      if (raw && !inflate.isFinished) {
        output.writeBytes(buffer);
        return false;
      }

      // verify adler-32
      if (!raw) {
        if (input.length < 4) {
          return false;
        }
        final adler32 = input.readUint32();
        if (verify) {
          final a = getAdler32(buffer);
          if (adler32 != a) {
            throw ArchiveChecksumException('Invalid zlib checksum');
          }
        }
      }
    }

    if (buffer != null) {
      output.writeBytes(buffer);
    }

    return true;
  }
}

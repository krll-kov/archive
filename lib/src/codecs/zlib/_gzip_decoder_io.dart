import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../util/adler32.dart';
import '../../util/archive_exception.dart';
import '../../util/crc32.dart';
import '../../util/decode_guard.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import '_gzip_decoder_web.dart' as web;
import '_zlib_decoder_base.dart';
import '_zlib_decoder_io.dart';
import '_zlib_encoder_base.dart';

const platformGZipDecoder = _GZipDecoder();

/// Decompress data with the zlib format decoder.
class _GZipDecoder extends ZLibDecoderBase {
  const _GZipDecoder();

  @override
  Uint8List decodeBytes(List<int> data,
      {bool verify = false, bool raw = false, bool throwOnError = false}) {
    var out = Uint8List(0);
    guardDecode('gzip', verify, throwOnError, () {
      if (!_nativeConcatenated &&
          (verify ||
              throwOnError ||
              _hasAdditionalMember(InputMemoryStream(data)))) {
        out = web.nativeGZipDecoder
            .decodeBytes(data, verify: verify, throwOnError: throwOnError);
        return true;
      }
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      final seen = bytes.length;
      final isGZip = seen >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
      final trailerLength = isGZip ? 8 : 4;
      if (seen < trailerLength + 2) {
        return false;
      }
      FormatException? trailerError;
      final body = Uint8List.sublistView(bytes, 0, seen - trailerLength);
      try {
        out = GZipCodec().decode(verify && isGZip ? bytes : body) as Uint8List;
      } on FormatException catch (error) {
        if (!verify || !isGZip) {
          rethrow;
        }
        trailerError = error;
        out = GZipCodec().decode(body) as Uint8List;
      }
      final sum = !verify
          ? 0
          : isGZip
              ? getCrc32(out)
              : getAdler32(out);
      final start = isGZip
          ? seen - trailerLength
          : max(0, seen - trailerLength - zlibAdlerWindow);
      final valid = _checkTrailer(Uint8List.sublistView(bytes, start), seen,
          out.length, sum, isGZip, verify);
      if (trailerError != null) {
        throw trailerError;
      }
      return valid;
    });
    return out;
  }

  @override
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool raw = false, bool throwOnError = false}) {
    return guardDecode('gzip', verify, throwOnError, () {
      if (!_nativeConcatenated &&
          (verify || throwOnError || _hasAdditionalMember(input))) {
        return web.nativeGZipDecoder.decodeStream(input, output,
            verify: verify, throwOnError: throwOnError);
      }
      return _decodeStream(input, output, verify);
    });
  }

  bool _decodeStream(InputStream input, OutputStream output, bool verify) {
    final seen = input.length;
    // Whether the input opened with the gzip signature, which decides whether
    // the trailer check below applies at all.
    final head = seen >= 2 ? input.peekBytes(2).toUint8List() : null;
    final isGZip = head != null && head[0] == 0x1f && head[1] == 0x8b;
    // dart:io reports a wrong checksum and damaged data with one message, so
    // we check the trailer ourselves before reporting its error
    final trailerLength = isGZip ? 8 : 4;
    // Nothing at all is not a gzip stream, and not a zlib one either: the
    // shortest of those is two bytes.
    if (seen < trailerLength + 2) {
      return false;
    }

    final outSink = ZLibOutputSink(output);
    if (verify) {
      outSink
        ..value = isGZip ? 0 : 1
        ..update = isGZip ? getCrc32 : getAdler32;
    }
    final inSink = GZipCodec().decoder.startChunkedConversion(outSink);
    var left = seen - trailerLength;
    while (left > 0) {
      final chunk = input.readBytes(min(8 * 1024, left)).toUint8List();
      if (chunk.isEmpty) {
        break;
      }
      inSink.add(chunk);
      left -= chunk.length;
    }
    var trailer = input.readBytes(trailerLength).toUint8List();
    if (!isGZip && verify) {
      final back = min(zlibAdlerWindow, seen - trailerLength - left);
      input.rewind(back + trailerLength);
      trailer = input.readBytes(back + trailerLength).toUint8List();
    }

    FormatException? trailerError;
    try {
      if (verify && isGZip) {
        inSink.add(trailer);
      }
      inSink.close();
    } on FormatException catch (error) {
      trailerError = error;
    }
    final valid = _checkTrailer(
        trailer, seen, outSink.written, outSink.value, isGZip, verify);
    if (trailerError != null) {
      throw trailerError;
    }
    return valid;
  }

  static bool _checkTrailer(Uint8List trailer, int seen, int written, int sum,
      bool isGZip, bool verify) {
    // The decoder underneath checks the CRC and the length of every member
    // whose trailer it reaches, and rejects trailing bytes that do not begin
    // another member. What it does not reject is a member cut short before its
    // trailer: that decodes to a short result and reports success, which is a
    // truncated archive silently losing files.
    //
    // A member's last four bytes are its uncompressed length modulo 2^32, so
    // for a whole stream it cannot exceed what was written: equal for the one
    // member that a .gz or .tar.gz holds, less when members are concatenated.
    // In a truncated stream those four bytes are compressed data instead, and
    // land above the total unless they happen to read as a number the output
    // is long enough to cover, which for an output of n bytes is a chance of
    // n / 2^32. Past 4 GB of output the comparison stops saying anything,
    // since every value is then in range.
    //
    // None of this applies to an input that never had a gzip header: the
    // decoder underneath accepts a plain zlib stream too, and its trailer is
    // four bytes of Adler-32 that would fail this on sight. That trailer is
    // checked with verify instead.
    if (!isGZip) {
      if (verify) {
        checkZlibAdler(trailer, sum);
      }
      return true;
    }
    // 10 header + 2 deflate + 8 trailer. Below that the last eight bytes are
    // header, not the trailer read next
    if (seen < 20) {
      return false;
    }
    final crc = trailer[0] |
        (trailer[1] << 8) |
        (trailer[2] << 16) |
        (trailer[3] << 24);
    final declared = trailer[4] |
        (trailer[5] << 8) |
        (trailer[6] << 16) |
        (trailer[7] << 24);
    if (written % 0x100000000 == declared) {
      if (verify && sum != crc) {
        throw ArchiveChecksumException('Invalid gzip checksum');
      }
      return true;
    }
    if (written >= 0x100000000 || declared < written) {
      return true;
    }
    return false;
  }
}

final _nativeConcatenated = _supportsConcatenated();

bool _supportsConcatenated() {
  final member = GZipCodec().encode(const [0]);
  try {
    return GZipCodec().decode([...member, ...member]).length == 2;
  } on FormatException {
    return false;
  }
}

bool _hasAdditionalMember(InputStream input) {
  final start = input.position;
  try {
    if (input.length < 6 ||
        input.readByte() != 0x1f ||
        input.readByte() != 0x8b ||
        input.readByte() != 8) {
      return false;
    }
    final buffer = Uint8List(8192);
    var marker = 0;
    while (!input.isEOS) {
      final count = input.readInto(buffer, 0, buffer.length);
      if (count <= 0) {
        break;
      }
      for (var at = 0; at < count; at++) {
        marker = ((marker << 8) | buffer[at]) & 0xffffff;
        if (marker == 0x1f8b08) {
          return true;
        }
      }
    }
    return false;
  } finally {
    input.setPosition(start);
  }
}

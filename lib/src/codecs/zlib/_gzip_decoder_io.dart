import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../util/adler32.dart';
import '../../util/archive_exception.dart';
import '../../util/crc32.dart';
import '../../util/decode_guard.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
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
    final partial = OutputMemoryStream();
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
      try {
        out = _convertMembers(
            bytes, seen - trailerLength, isGZip, verify && isGZip, partial);
      } on FormatException catch (error) {
        if (!verify || !isGZip) {
          rethrow;
        }
        trailerError = error;
        out = partial.getBytes();
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
      // Output above ISIZE comes from crafted input or member over 4 GiB.
      // Checking it inflates whole input again in Dart, as `_completeDeflate`
      // in zlib does, which made verify 3.4x slower, so check stays off
      // if (valid &&
      //     isGZip &&
      //     (verify || throwOnError) &&
      //     out.length > _gzipDeclaredSize(bytes, seen - 4)) {
      //   return _validateAdditionalMembers(
      //       InputMemoryStream(data), out.length, verify, throwOnError);
      // }
      return valid;
    });
    if (partial.length > 0) {
      out = partial.getBytes();
    }
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
      return _decodeStream(input, output, verify, throwOnError);
    });
  }

  bool _decodeStream(
      InputStream input, OutputStream output, bool verify, bool throwOnError) {
    // final startPos = input.position;
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
    var inSink = GZipCodec().decoder.startChunkedConversion(outSink);
    var left = seen - trailerLength;
    final bodyEnd = input.position + left;
    var split = false;
    var fed = _none;
    var fedAt = 0;
    var fedBefore = _none;
    var last8 = _none;
    void restart(int position) {
      inSink = GZipCodec().decoder.startChunkedConversion(outSink);
      input.setPosition(position);
      left = bodyEnd - position;
      last8 = Uint8List(8);
      split = true;
    }

    while (true) {
      while (left > 0) {
        final at = input.position;
        var chunk = input.readBytes(min(8 * 1024, left)).toUint8List();
        if (chunk.isEmpty) {
          break;
        }
        left -= chunk.length;
        final next = left > 0 ? _toNextMember(input, left) : -1;
        if (next > 0) {
          chunk = Uint8List(chunk.length + next)
            ..setRange(0, chunk.length, chunk)
            ..setRange(chunk.length, chunk.length + next,
                input.readBytes(next).toUint8List());
          left -= next;
        }
        if (split) {
          final after =
              left > 0 ? input.peekBytes(min(2, left)).toUint8List() : _none;
          var from = 0;
          for (var i = _afterEmptyMember(last8, chunk, after, 1);
              i >= 0;
              i = _afterEmptyMember(last8, chunk, after, i + 1)) {
            inSink.add(Uint8List.sublistView(chunk, from, i));
            from = i;
          }
          inSink.add(Uint8List.sublistView(chunk, from));
          last8 = _lastBytes(last8, chunk);
          continue;
        }
        try {
          inSink.add(chunk);
        } on FormatException {
          final empty =
              isGZip ? _afterEmptyMember(fedBefore, fed, chunk, 1) : -1;
          if (empty < 0) {
            rethrow;
          }
          restart(fedAt + empty);
          continue;
        }
        fedBefore = last8;
        fed = chunk;
        fedAt = at;
        last8 = _lastBytes(last8, chunk);
        if (isGZip && next >= 0) {
          final empty = _afterEmptyMember(fedBefore, fed, _none, 1);
          if (empty >= 0) {
            restart(fedAt + empty);
          }
        }
      }
      if (split || !isGZip) {
        break;
      }
      final empty = _afterEmptyMember(fedBefore, fed, _none, 1);
      if (empty < 0) {
        break;
      }
      restart(fedAt + empty);
    }
    final tail = input.readBytes(trailerLength).toUint8List();
    var trailer = tail;
    if (!isGZip && verify) {
      final back = min(zlibAdlerWindow, seen - trailerLength - left);
      input.rewind(back + trailerLength);
      trailer = input.readBytes(back + trailerLength).toUint8List();
    }

    FormatException? trailerError;
    try {
      if (verify && isGZip) {
        inSink.add(trailer);
      } else {
        addTrailerUnchecked(inSink, tail);
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
    // This ISIZE check also inflates input second time, so it stays off
    // if (valid &&
    //     isGZip &&
    //     (verify || throwOnError) &&
    //     outSink.written > _gzipDeclaredSize(trailer, trailer.length - 4)) {
    //   final endPos = input.position;
    //   input.setPosition(startPos);
    //   try {
    //     return _validateAdditionalMembers(
    //         input, outSink.written, verify, throwOnError);
    //   } finally {
    //     input.setPosition(endPos);
    //   }
    // }
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

// int _gzipDeclaredSize(Uint8List bytes, int at) =>
//     bytes[at] |
//     (bytes[at + 1] << 8) |
//     (bytes[at + 2] << 16) |
//     (bytes[at + 3] << 24);
//
// bool _validateAdditionalMembers(
//     InputStream input, int expectedLength, bool verify, bool throwOnError) {
//   if (!_hasAdditionalMember(input)) {
//     return false;
//   }
//   final output = SinkOutputStream(_DiscardSink());
//   return web.nativeGZipDecoder.decodeStream(input, output,
//           verify: verify, throwOnError: throwOnError) &&
//       output.length == expectedLength;
// }
//
// class _DiscardSink implements Sink<List<int>> {
//   @override
//   void add(List<int> data) {}
//
//   @override
//   void close() {}
// }

/// dart:io gzip decoder fails when read splits last 9 bytes of member that
/// another member follows, so chunk is extended to next member header
int _toNextMember(InputStream input, int left) {
  final ahead = input.peekBytes(min(12, left)).toUint8List();
  for (var k = 0; k <= 9 && k + 2 < ahead.length; k++) {
    if (ahead[k] == 0x1f && ahead[k + 1] == 0x8b && ahead[k + 2] == 8) {
      return k;
    }
  }
  return -1;
}

Uint8List _convertMembers(Uint8List bytes, int end, bool isGZip, bool checked,
    OutputMemoryStream partial) {
  final output = ZLibOutputSink(partial);
  var sink = GZipCodec().decoder.startChunkedConversion(output);
  final body = Uint8List.sublistView(bytes, 0, end);
  final trailer = Uint8List.sublistView(bytes, end);
  sink.add(body);
  try {
    sink.add(trailer);
  } on FormatException {
    var from = isGZip ? _afterEmptyMember(_none, body, trailer, 1) : -1;
    if (from < 0) {
      if (checked) {
        rethrow;
      }
      sink.close();
      return partial.getBytes();
    }
    sink = GZipCodec().decoder.startChunkedConversion(output);
    for (var next = _afterEmptyMember(_none, body, trailer, from + 1);
        next >= 0;
        next = _afterEmptyMember(_none, body, trailer, next + 1)) {
      sink.add(Uint8List.sublistView(body, from, next));
      from = next;
    }
    sink.add(Uint8List.sublistView(body, from));
    if (checked) {
      sink.add(trailer);
    } else {
      addTrailerUnchecked(sink, trailer);
    }
  }
  sink.close();
  return partial.getBytes();
}

final _none = Uint8List(0);

/// dart:io drops input after empty gzip member in ZLibInflateFilter, see
/// https://github.com/dart-lang/sdk/blob/ab942a8bcf/runtime/bin/filter.cc#L419
/// so we find each empty member and feed input again from its end
int _afterEmptyMember(
    Uint8List before, Uint8List chunk, Uint8List after, int from) {
  int byteAt(int i) => i < 0
      ? (before.length + i >= 0 ? before[before.length + i] : -1)
      : i < chunk.length
          ? chunk[i]
          : (i - chunk.length < after.length ? after[i - chunk.length] : -1);
  bool matches(int i) {
    if (byteAt(i) != 0x1f || byteAt(i + 1) != 0x8b || byteAt(i + 2) != 8) {
      return false;
    }
    for (var k = 1; k <= 8; k++) {
      if (byteAt(i - k) != 0) {
        return false;
      }
    }
    return true;
  }

  final end = chunk.length;
  var i = from;
  for (; i < end && i < 8; i++) {
    if (matches(i)) {
      return i;
    }
  }
  while (i + 2 < end) {
    final c = chunk[i + 2];
    if (c == 8) {
      if (matches(i)) {
        return i;
      }
      i += 11;
    } else {
      i += c == 0
          ? 3
          : c == 0x1f
              ? 2
              : c == 0x8b
                  ? 1
                  : 11;
    }
  }
  for (; i < end; i++) {
    if (matches(i)) {
      return i;
    }
  }
  return -1;
}

Uint8List _lastBytes(Uint8List before, Uint8List chunk) {
  if (chunk.length >= 8) {
    return Uint8List.sublistView(chunk, chunk.length - 8);
  }
  final keep = min(8 - chunk.length, before.length);
  return Uint8List(keep + chunk.length)
    ..setRange(0, keep, before, before.length - keep)
    ..setRange(keep, keep + chunk.length, chunk);
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

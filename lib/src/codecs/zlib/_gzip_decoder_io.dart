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
    var declared = 0;
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
      if (isGZip) {
        declared = min(
            bytes[seen - 4] |
                bytes[seen - 3] << 8 |
                bytes[seen - 2] << 16 |
                bytes[seen - 1] << 24,
            seen * 1032);
        // In cut file last 4 bytes are deflate data, not ISIZE, so reserve
        // may take GBs. We skip it on OutOfMemoryError and copy output shorter
        // than ISIZE into exact buffer, so result does not hold that memory
        try {
          partial.reserve(declared);
        } on OutOfMemoryError {
          declared = 0;
        }
      }
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
          ? max(0, seen - trailerLength - _junkWindow)
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
    if (out.length < declared || out.length < out.buffer.lengthInBytes >> 1) {
      out = Uint8List.fromList(out);
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
    final bodyStart = input.position;
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

    void addPieces(Uint8List chunk) {
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
    }

    int emptyMemberIn(Uint8List after) {
      final position = input.position;
      try {
        for (var i = _afterEmptyMember(fedBefore, fed, after, 1);
            i >= 0;
            i = _afterEmptyMember(fedBefore, fed, after, i + 1)) {
          final from = max(bodyStart, fedAt + i - _emptyMemberWindow);
          input.setPosition(from);
          final bytes = input.readBytes(fedAt + i - from).toUint8List();
          if (_endsEmptyMember(bytes, bytes.length)) {
            return i;
          }
        }
        return -1;
      } finally {
        input.setPosition(position);
      }
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
          addPieces(chunk);
          last8 = _lastBytes(last8, chunk);
          continue;
        }
        final pieces = isGZip && (next >= 0 || left == 0);
        try {
          if (pieces) {
            addPieces(chunk);
          } else {
            inSink.add(chunk);
          }
        } on FormatException {
          final empty = isGZip ? emptyMemberIn(chunk) : -1;
          if (empty < 0) {
            rethrow;
          }
          restart(fedAt + empty);
          continue;
        }
        fedBefore = last8;
        fed = pieces ? _none : chunk;
        fedAt = at;
        last8 = _lastBytes(last8, chunk);
      }
      if (split || !isGZip) {
        break;
      }
      final empty = emptyMemberIn(_none);
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
    var checked = trailer;
    if (isGZip && verify) {
      final back = min(_junkWindow, seen - trailerLength - left);
      input.rewind(back + trailerLength);
      checked = input.readBytes(back + trailerLength).toUint8List();
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
        checked, seen, outSink.written, outSink.value, isGZip, verify);
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
    // dart:io drops input after empty member, so decodeBytes accepted cut
    // header of next member in last 9 bytes. Any member takes at least 20
    // bytes, so with verify we reject header that starts in last 9 bytes
    if (verify && _afterEmptyMember(_none, trailer, _none, 8) >= 0) {
      return false;
    }
    final at = trailer.length - 8;
    final crc = _uint32(trailer, at);
    final declared = _uint32(trailer, at + 4);
    if (written % 0x100000000 == declared) {
      if (verify && sum != crc) {
        throw ArchiveChecksumException('Invalid gzip checksum');
      }
      return true;
    }
    if (written >= 0x100000000 || declared < written) {
      // dart:io accepts cut header of 1 to 9 bytes after last member, and then
      // trailer read at end looks like concatenated member. Member takes 20
      // bytes or more, so whole output trailer 1 to 9 bytes from end means junk
      if (verify) {
        for (var i = at - 1; i >= 0; i--) {
          if (_uint32(trailer, i) == sum &&
              _uint32(trailer, i + 4) == written % 0x100000000) {
            return false;
          }
        }
      }
      return true;
    }
    return false;
  }

  static int _uint32(Uint8List bytes, int at) =>
      bytes[at] |
      (bytes[at + 1] << 8) |
      (bytes[at + 2] << 16) |
      (bytes[at + 3] << 24);
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

/// dart:io gzip decoder fails when read splits last 18 bytes of member that
/// another member follows, so chunk is extended to next member header. We
/// look 32 bytes ahead, since we measured only zlib and this package encoders
int _toNextMember(InputStream input, int left) {
  final ahead = input.peekBytes(min(35, left)).toUint8List();
  for (var k = 0; k <= 32 && k + 2 < ahead.length; k++) {
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
  // dart:io drops output of failing inflate call, up to 64 KiB before damage.
  // Feeding 8 KiB pieces keeps that output but costs 15-17% on text and 80% on
  // random data, and second decode after error reads input twice
  sink.addSlice(bytes, 0, end, false);
  try {
    sink.add(trailer);
  } on FormatException {
    var from = isGZip ? _afterEmptyMember(_none, body, trailer, 1) : -1;
    while (from >= 0 && !_endsEmptyMember(body, from)) {
      from = _afterEmptyMember(_none, body, trailer, from + 1);
    }
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

const _junkWindow = 9;

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

const _emptyMemberWindow = 1024;

/// dart:io drops input after empty member and gives no offset. So level 0
/// member holding .gz file with empty member inside looks like real boundary,
/// and we decode that .gz into output. Only second decode could fix this
bool _endsEmptyMember(Uint8List bytes, int end) {
  for (var start = end - 20;
      start >= max(0, end - _emptyMemberWindow);
      start--) {
    if (bytes[start] == 0x1f &&
        bytes[start + 1] == 0x8b &&
        bytes[start + 2] == 8 &&
        _isEmptyMember(bytes, start, end)) {
      return true;
    }
  }
  return false;
}

bool _isEmptyMember(Uint8List bytes, int start, int end) {
  final stop = end - 8;
  final flags = bytes[start + 3];
  var at = start + 10;
  if (flags & 4 != 0) {
    if (at + 2 > stop) {
      return false;
    }
    at += 2 + (bytes[at] | (bytes[at + 1] << 8));
  }
  for (final flag in const [8, 16]) {
    if (flags & flag != 0) {
      while (at < stop && bytes[at] != 0) {
        at++;
      }
      at++;
    }
  }
  if (flags & 2 != 0) {
    at += 2;
  }
  final limit = stop * 8;
  var bit = at * 8;
  int read(int count) {
    if (bit + count > limit) {
      return -1;
    }
    var value = 0;
    for (var k = 0; k < count; k++, bit++) {
      value |= ((bytes[bit >> 3] >> (bit & 7)) & 1) << k;
    }
    return value;
  }

  while (true) {
    final last = read(1);
    final type = read(2);
    if (type == 0) {
      bit = (bit + 7) & ~7;
      if (read(16) != 0 || read(16) != 0xffff) {
        return false;
      }
    } else if (type != 1 || read(7) != 0) {
      return false;
    }
    if (last == 1) {
      return (bit + 7) >> 3 == stop;
    }
  }
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

/// dart:io reads concatenated gzip members only from Dart 3.5.0, and package
/// supports Dart 3.0.0, so older SDK falls back to web decoder
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

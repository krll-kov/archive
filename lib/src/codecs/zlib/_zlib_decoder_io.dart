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
      // Computed Adler-32 fed as trailer lets dart:io reject crafted deflate
      // with matching checksum, but Adler-32 on every input made throwOnError
      // 12-20% slower on 100 and 500 MB, so it stays off
      // var adler = 1;
      // if (!raw && (verify || throwOnError)) {
      //   final outSink = ZLibOutputSink(partial)
      //     ..value = 1
      //     ..update = getAdler32;
      //   final inSink = ZLibCodec().decoder.startChunkedConversion(outSink);
      //   inSink.add(
      //       Uint8List.sublistView(bytes, 0, bytes.length - trailerLength));
      //   inSink.add(_adlerTrailer(outSink.value));
      //   inSink.close();
      //   out = partial.getBytes();
      //   adler = outSink.value;
      // } else {
      out = convertKeepingPartial(
          ZLibCodec(raw: raw).decoder,
          [Uint8List.sublistView(bytes, 0, bytes.length - trailerLength)],
          partial);
      // }
      if (verify && !raw) {
        checkZlibAdler(
            Uint8List.sublistView(
                bytes, max(0, bytes.length - 4 - zlibAdlerWindow)),
            getAdler32(out));
        // if (!_completeDeflate(InputMemoryStream(bytes), 0, bytes.length)) {
        //   return false;
        // }
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
        () => _decodeStream(input, output, verify, raw, throwOnError));
  }

  bool _decodeStream(InputStream input, OutputStream output, bool verify,
      bool raw, bool throwOnError) {
    // dart:io reports a wrong checksum and damaged data with one message, so
    // it never gets the Adler-32 and we check it ourselves
    final trailerLength = raw ? 0 : 4;
    final seen = input.length;
    if (!raw && seen < trailerLength + 2) {
      return false;
    }
    // final start = input.position;
    final outSink = ZLibOutputSink(output);
    // if (!raw && (verify || throwOnError)) {
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
    // Computed Adler-32 trailer made throwOnError 12-20% slower on 100 and
    // 500 MB for crafted streams only, so it stays off as in decodeBytes
    // if (!raw && (verify || throwOnError)) {
    //   inSink.add(_adlerTrailer(outSink.value));
    // }
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
    // if (!_completeDeflate(input, start, seen)) {
    //   return false;
    // }
    return true;
  }
}

// Second inflate pass in Dart made verify on 100 MB enwik8 take 645 ms,
// not 191 ms, and catches only crafted streams, so this check stays off
// dart:io can accept a block without BFINAL when its Adler-32 matches,
// so validate the DEFLATE terminator separately
// bool _completeDeflate(InputStream input, int start, int seen) {
//   final held = input.position;
//   try {
//     input.setPosition(start + 1);
//     final flags = input.readByte();
//     if (flags & 0x20 != 0) {
//       if (input.length < 4) {
//         return false;
//       }
//       input.skip(4);
//     }
//     final deflateStart = input.position;
//     final end = start + seen - 4;
//     while (input.position < end) {
//       final header = input.readByte();
//       if (header & 6 != 0) {
//         input.setPosition(deflateStart);
//         break;
//       }
//       if (input.position + 4 > end) {
//         return false;
//       }
//       final length = input.readByte() | (input.readByte() << 8);
//       final inverse = input.readByte() | (input.readByte() << 8);
//       if ((length ^ inverse) != 0xffff || input.position + length > end) {
//         return false;
//       }
//       input.skip(length);
//       if (header & 1 != 0) {
//         return true;
//       }
//     }
//     if (input.position >= end) {
//       return false;
//     }
//     final inflate = Inflate.stream(input, output: _CountOutputStream());
//     return inflate.isFinished && input.position <= start + seen - 4;
//   } finally {
//     input.setPosition(held);
//   }
// }
//
// class _CountOutputStream extends OutputMemoryStream {
//   _CountOutputStream() : super(size: 0);
//
//   @override
//   void writeByte(int value) {
//     length++;
//   }
//
//   @override
//   void writeBytes(List<int> bytes, {int? length}) {
//     this.length += length ?? bytes.length;
//   }
//
//   @override
//   void writeStream(InputStream stream) {
//     length += stream.length;
//   }
//
//   @override
//   void writeBackReference(int distance, int count) {
//     length += count;
//   }
// }

// Uint8List _adlerTrailer(int value) => Uint8List.fromList([
//       value >> 24 & 0xff,
//       value >> 16 & 0xff,
//       value >> 8 & 0xff,
//       value & 0xff,
//     ]);

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

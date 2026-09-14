import 'dart:io';
import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_dictionary.dart';
import 'package:archive/src/codecs/zstd/zstd_frame_decoder.dart';
import 'package:archive/src/codecs/zstd/zstd_window.dart';
import 'package:archive/src/codecs/zstd_decoder.dart';
import 'package:archive/src/codecs/zstd_encoder.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:archive/src/util/input_memory_stream.dart';
import 'package:archive/src/util/output_memory_stream.dart';
import 'package:archive/src/util/xxh64.dart';
import 'package:test/test.dart';

// Vectors written by zstd 1.5.7. Only the compressed side is stored: each row
// carries the length and CRC-32 of what it must decode to, which is enough to
// catch any difference without keeping the originals in the repository.
const _vectors = <List<Object>>[
  ['text-empty-l1.zst', 0, 0],
  ['text-empty-l19.zst', 0, 0],
  ['text-empty-nocheck.zst', 0, 0],
  ['text-1-l1.zst', 1, 2564639436],
  ['text-1-l19.zst', 1, 2564639436],
  ['text-1-nocheck.zst', 1, 2564639436],
  ['text-7-l1.zst', 7, 82448416],
  ['text-7-l19.zst', 7, 82448416],
  ['text-7-nocheck.zst', 7, 82448416],
  ['text-8-l1.zst', 8, 4206782857],
  ['text-8-l19.zst', 8, 4206782857],
  ['text-8-nocheck.zst', 8, 4206782857],
  ['text-65-l1.zst', 65, 1524059729],
  ['text-65-l19.zst', 65, 1524059729],
  ['text-65-nocheck.zst', 65, 1524059729],
  ['text-1k-l1.zst', 1000, 2004545584],
  ['text-1k-l19.zst', 1000, 2004545584],
  ['text-1k-nocheck.zst', 1000, 2004545584],
  ['text-block-edge-l1.zst', 131073, 2188447095],
  ['text-block-edge-l19.zst', 131073, 2188447095],
  ['text-block-edge-nocheck.zst', 131073, 2188447095],
  ['text-200k-l1.zst', 200000, 3355992480],
  ['text-200k-l19.zst', 200000, 3355992480],
  ['text-200k-nocheck.zst', 200000, 3355992480],
  ['rle-1-l1.zst', 1, 476252946],
  ['rle-1-l19.zst', 1, 476252946],
  ['rle-1-nocheck.zst', 1, 476252946],
  ['rle-1k-l1.zst', 1000, 2810990746],
  ['rle-1k-l19.zst', 1000, 2810990746],
  ['rle-1k-nocheck.zst', 1000, 2810990746],
  ['rle-200k-l1.zst', 200000, 1803209211],
  ['rle-200k-l19.zst', 200000, 1803209211],
  ['rle-200k-nocheck.zst', 200000, 1803209211],
  ['random-1-l1.zst', 1, 3624026538],
  ['random-1-l19.zst', 1, 3624026538],
  ['random-1-nocheck.zst', 1, 3624026538],
  ['random-100-l1.zst', 100, 917727960],
  ['random-100-l19.zst', 100, 917727960],
  ['random-100-nocheck.zst', 100, 917727960],
  ['random-4k-l1.zst', 4096, 1699625419],
  ['random-4k-l19.zst', 4096, 1699625419],
  ['random-4k-nocheck.zst', 4096, 1699625419],
  ['mix-1k-l1.zst', 1000, 1204304730],
  ['mix-1k-l19.zst', 1000, 1204304730],
  ['mix-1k-nocheck.zst', 1000, 1204304730],
  ['mix-70k-l1.zst', 70000, 1811542865],
  ['mix-70k-l19.zst', 70000, 1811542865],
  ['mix-70k-nocheck.zst', 70000, 1811542865],
  ['mix-200k-l1.zst', 200000, 1110379402],
  ['mix-200k-l19.zst', 200000, 1110379402],
  ['mix-200k-nocheck.zst', 200000, 1110379402],
  ['multi-frame.zst', 85097, 1639112962],
  ['skippable-lead.zst', 200000, 1110379402],
  ['sources-slice-l3.zst', 400000, 948042585],
  ['sources-slice-l19.zst', 400000, 948042585],
  ['domains-slice-l19.zst', 400000, 1576664692],
];

void main() {
  final directory = Directory('test/_data/zstd');

  group('zstd', () {
    for (final vector in _vectors) {
      final name = vector[0] as String;
      final length = vector[1] as int;
      final crc = vector[2] as int;
      final bytes = File('${directory.path}/$name').readAsBytesSync();

      test('$name decodes in one piece', () {
        final decoded =
            ZstdDecoder().decodeBytes(bytes, verify: true, throwOnError: true);
        expect(decoded.length, length);
        expect(getCrc32(decoded), crc);
      });

      test('$name decodes through a stream', () {
        final output = OutputMemoryStream();
        final ok = ZstdDecoder().decodeStream(InputMemoryStream(bytes), output,
            verify: true, throwOnError: true);
        expect(ok, isTrue);
        final decoded = output.getBytes();
        expect(decoded.length, length);
        expect(getCrc32(decoded), crc);
      });

      test('$name reports a content size it can honour', () {
        final size = ZstdDecoder().uncompressedSize(bytes);
        if (size != null) {
          expect(size, length);
        }
      });
    }

    test('a truncated frame is rejected', () {
      final bytes = File('${directory.path}/mix-70k-l19.zst').readAsBytesSync();
      for (final cut in [4, 8, 20, bytes.length ~/ 2, bytes.length - 1]) {
        expect(
            () => ZstdDecoder().decodeBytes(
                Uint8List.sublistView(bytes, 0, cut),
                verify: true,
                throwOnError: true),
            throwsA(anything),
            reason: 'cut to $cut bytes');
      }
    });

    test('a corrupt byte is caught by the checksum', () {
      final bytes = File('${directory.path}/mix-70k-l19.zst').readAsBytesSync();
      var caught = 0;
      for (var at = 20; at < bytes.length - 4; at += 997) {
        final broken = Uint8List.fromList(bytes);
        broken[at] ^= 0x40;
        try {
          final decoded = ZstdDecoder()
              .decodeBytes(broken, verify: true, throwOnError: true);
          if (getCrc32(decoded) != 1811542865) {
            fail('byte $at changed the output without being reported');
          }
        } catch (_) {
          caught++;
        }
      }
      expect(caught, greaterThan(0));
    });

    test('data that is not zstd is rejected', () {
      expect(
          () => ZstdDecoder().decodeBytes(
              Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
              throwOnError: true),
          throwsA(anything));
      expect(
          ZstdDecoder().decodeBytes(Uint8List.fromList([1, 2, 3, 4])), isEmpty);
    });

    test('a window above the limit is rejected', () {
      final bytes =
          File('${directory.path}/mix-200k-l19.zst').readAsBytesSync();
      expect(
          () => ZstdDecoder(windowSizeLimit: 1024)
              .decodeBytes(bytes, throwOnError: true),
          throwsA(anything));
    });
  });

  // A frame is rejected by whichever part of it stops making sense first, and
  // each of those parts reports on its own. A checksum catches what gets that
  // far, so a corruption has to be aimed to reach the tables at all
  group('zstd rejects', () {
    final frame = File('${directory.path}/mix-70k-l19.zst').readAsBytesSync();
    final short = File('${directory.path}/text-1k-l19.zst').readAsBytesSync();

    Uint8List broken(Uint8List from, int at, int value) =>
        Uint8List.fromList(from)..[at] = value;

    void reject(Uint8List bytes, String reason) {
      expect(() => ZstdDecoder().decodeBytes(bytes, throwOnError: true),
          throwsA(anything),
          reason: reason);
    }

    test('bytes after a zero sequence count', () {
      const valid = [40, 181, 47, 253, 0, 0, 29, 0, 0, 8, 97, 0];
      final trailing =
          Uint8List.fromList([40, 181, 47, 253, 0, 0, 37, 0, 0, 8, 97, 0, 153]);
      expect(ZstdDecoder().decodeBytes(valid, throwOnError: true), [97]);
      reject(trailing, 'the zero sequence count must end the block');
    });

    test('a frame cut at any length', () {
      for (var cut = 1; cut < frame.length; cut++) {
        expect(
            () => ZstdDecoder().decodeBytes(
                Uint8List.sublistView(frame, 0, cut),
                verify: true,
                throwOnError: true),
            throwsA(anything),
            reason: 'cut to $cut bytes');
      }
    });

    test('a frame cut inside its first block', () {
      for (var cut = 1; cut < short.length; cut++) {
        expect(
            () => ZstdDecoder().decodeBytes(
                Uint8List.sublistView(short, 0, cut),
                verify: true,
                throwOnError: true),
            throwsA(anything),
            reason: 'cut to $cut bytes');
      }
    });

    test('every byte of a frame, changed, is caught or harmless', () {
      final whole =
          ZstdDecoder().decodeBytes(short, verify: true, throwOnError: true);
      final crc = getCrc32(whole);
      for (var at = 4; at < short.length; at++) {
        for (final mask in [0x01, 0x55, 0x80]) {
          final bytes = Uint8List.fromList(short);
          bytes[at] ^= mask;
          Uint8List? decoded;
          try {
            decoded = ZstdDecoder()
                .decodeBytes(bytes, verify: true, throwOnError: true);
          } catch (_) {
            continue;
          }
          expect(getCrc32(decoded), crc,
              reason: 'byte $at with $mask changed the output silently');
        }
      }
    });

    // Block type three is reserved, and the header is the three bytes after
    // the frame header, which for this file is five bytes long
    test('a reserved block type', () {
      final header = _firstBlockAt(short);
      reject(broken(short, header, short[header] | 6), 'reserved block type');
    });

    test('a block that claims more than a block', () {
      final header = _firstBlockAt(short);
      final bytes = Uint8List.fromList(short);
      // Size sits in the top twenty one bits of the three byte header
      bytes[header] |= 0xf8;
      bytes[header + 1] = 0xff;
      bytes[header + 2] = 0xff;
      reject(bytes, 'block larger than the limit');
    });

    test('a literals section that claims more than a block', () {
      final at = _firstBlockAt(short) + 3;
      final bytes = Uint8List.fromList(short);
      // Type two, size format three, so the header is five bytes wide
      bytes[at] = 0x0e;
      bytes[at + 1] = 0xff;
      bytes[at + 2] = 0xff;
      bytes[at + 3] = 0xff;
      bytes[at + 4] = 0xff;
      reject(bytes, 'literals larger than a block');
    });

    test('treeless literals in the first block', () {
      final at = _firstBlockAt(short) + 3;
      // Type three reuses the tree of an earlier block, and there is none
      reject(
          broken(short, at, (short[at] & ~3) | 3), 'treeless without a tree');
    });

    test('an empty archive', () {
      expect(() => ZstdDecoder().decodeBytes(Uint8List(0), throwOnError: true),
          throwsA(anything));
      final out = OutputMemoryStream();
      expect(
          () => ZstdDecoder().decodeStream(InputMemoryStream(Uint8List(0)), out,
              throwOnError: true),
          throwsA(anything));
    });

    test('a skippable frame that runs off the end', () {
      final bytes = Uint8List.fromList(
          [0x50, 0x2a, 0x4d, 0x18, 0xff, 0xff, 0xff, 0x7f, 1, 2, 3]);
      reject(bytes, 'skippable frame is truncated');
    });

    test('a frame header that stops inside its content size', () {
      reject(Uint8List.fromList([0x28, 0xb5, 0x2f, 0xfd, 0xa0]),
          'content size is truncated');
    });

    // The tables of a block are read before anything is written, so a change
    // there is reported by whichever table stops making sense, not by the
    // checksum. The first few hundred bytes of a block are those tables
    test('every bit of the tables of a block, flipped', () {
      final whole =
          ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true);
      final crc = getCrc32(whole);
      final from = _firstBlockAt(frame) + 3;
      final to = from + 400 < frame.length ? from + 400 : frame.length;
      for (var at = from; at < to; at++) {
        for (var bit = 0; bit < 8; bit++) {
          final bytes = Uint8List.fromList(frame);
          bytes[at] ^= 1 << bit;
          Uint8List? decoded;
          try {
            decoded = ZstdDecoder()
                .decodeBytes(bytes, verify: true, throwOnError: true);
          } catch (_) {
            continue;
          }
          expect(getCrc32(decoded), crc,
              reason: 'bit $bit of byte $at changed the output silently');
        }
      }
    });
  });

  group('zstd concatenated windows', () {
    final source = Uint8List.fromList(
        List.generate(32 << 10, (i) => (i * 7 + (i >> 9)) & 255));
    final frame = _rawWindowFrame(source);
    final prefix = Uint8List.fromList([1, 2, 3]);
    final first = const ZstdEncoder().encodeBytes(prefix);

    test('buffer blocks keep the decoding window bounded', () {
      final header = readFrameHeader(frame, 4, frame.length, 1024);
      final sink = OutputMemoryStream();
      final window = ZstdWindow(header.windowSize, output: sink);
      ZstdFrameDecoder().decodeBlocks(
          frame, 4 + header.size, frame.length, window, header, true, null);
      expect(window.capacity,
          lessThanOrEqualTo(header.windowSize + 2 * header.blockReserve));
      window.finish();
      expect(sink.getBytes(), source);
    });

    test('concatenated frames preserve output across window wraps', () {
      final joined = Uint8List.fromList([...first, ...frame, ...first]);
      expect(
          ZstdDecoder().decodeBytes(joined, verify: true, throwOnError: true),
          [...prefix, ...source, ...prefix]);
    });

    for (final failure in ['checksum', 'block']) {
      test('a late $failure failure returns only completed frames', () {
        final broken = Uint8List.fromList(frame);
        if (failure == 'checksum') {
          broken[broken.length - 1] ^= 1;
        } else {
          broken[6 + 31 * 1027] |= 6;
        }
        final joined = Uint8List.fromList([...first, ...broken]);
        expect(ZstdDecoder().decodeBytes(joined, verify: true), prefix);
        expect(
            () => ZstdDecoder()
                .decodeBytes(joined, verify: true, throwOnError: true),
            throwsA(anything));
      });
    }
  });

  group('zstd wraps its window', () {
    final source = Uint8List(3 << 20);
    for (var at = 0; at < source.length; at++) {
      source[at] = 0x20 + ((at * 7 + (at >> 9)) % 90);
    }

    for (final level in [1, 3, 6]) {
      test('level $level round trips through a window it outgrows', () {
        final encoded = ZstdEncoder(level: level).encodeBytes(source);
        final out = OutputMemoryStream();
        final ok = ZstdDecoder().decodeStream(InputMemoryStream(encoded), out,
            verify: true, throwOnError: true);
        expect(ok, isTrue);
        final decoded = out.getBytes();
        expect(decoded.length, source.length);
        expect(getCrc32(decoded), getCrc32(source));
      });
    }

    test('a frame with a dictionary wraps the same way', () {
      final dictionary = ZstdDictionary(Uint8List.fromList(
          List.generate(1 << 16, (i) => 0x20 + (i * 11 % 90))));
      final encoded =
          ZstdEncoder(level: 3, dictionary: dictionary).encodeBytes(source);
      final out = OutputMemoryStream();
      ZstdDecoder(dictionary: dictionary).decodeStream(
          InputMemoryStream(encoded), out,
          verify: true, throwOnError: true);
      expect(getCrc32(out.getBytes()), getCrc32(source));
    });
  });
}

Uint8List _rawWindowFrame(Uint8List source) {
  final bytes = BytesBuilder()..add([0x28, 0xb5, 0x2f, 0xfd, 4, 0]);
  for (var at = 0; at < source.length; at += 1024) {
    final end = at + 1024 < source.length ? at + 1024 : source.length;
    final header = ((end - at) << 3) | (end == source.length ? 1 : 0);
    bytes.add([header & 255, (header >> 8) & 255, header >> 16]);
    bytes.add(Uint8List.sublistView(source, at, end));
  }
  final hash = Xxh64()..update(source, 0, source.length);
  final checksum = ByteData(4)..setUint32(0, hash.digestLow, Endian.little);
  bytes.add(checksum.buffer.asUint8List());
  return bytes.takeBytes();
}

/// Where the first block header sits: the magic, the descriptor, and whatever
/// widths the descriptor asks of the window, the dictionary id and the size
int _firstBlockAt(Uint8List frame) {
  final descriptor = frame[4];
  final sizeFlag = descriptor >> 6;
  final single = (descriptor & 0x20) != 0;
  final idBytes = const [0, 1, 2, 4][descriptor & 3];
  final sizeBytes = sizeFlag == 0 ? (single ? 1 : 0) : 1 << sizeFlag;
  return 5 + (single ? 0 : 1) + idBytes + sizeBytes;
}

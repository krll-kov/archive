import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_level_params.dart';
import 'package:archive/src/codecs/zstd_decoder.dart';
import 'package:archive/src/codecs/zstd_encoder.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:archive/src/util/input_memory_stream.dart';
import 'package:archive/src/util/output_memory_stream.dart';
import 'package:test/test.dart';

Uint8List _pattern(int length, int Function(int) byte) =>
    Uint8List.fromList(List.generate(length, byte));

/// Words drawn at random from a small vocabulary, which is the shape a deeper
/// search pays off on where a plain repeat does not
Uint8List _words(int length) {
  const words = [
    'zstd',
    'window',
    'sequence',
    'literal',
    'offset',
    'match',
    'table',
    'block',
    'frame',
    'stream',
    'header',
    'entropy'
  ];
  var seed = 7;
  final text = StringBuffer();
  while (text.length < length) {
    seed = (seed * 1103515245 + 12345) & 0x3fffffff;
    text.write(words[seed % words.length]);
    text.write(seed % 11 == 0 ? '\n' : ' ');
  }
  return Uint8List.fromList(text.toString().codeUnits);
}

void main() {
  final cases = <String, Uint8List>{
    'empty': Uint8List(0),
    'one byte': Uint8List.fromList([100]),
    'eight bytes': Uint8List.fromList('epsilon '.codeUnits),
    'a byte repeated': Uint8List(5000)..fillRange(0, 5000, 0x41),
    'one block short': _pattern(131071, (i) => (i * 7) & 0xff),
    'exactly one block': _pattern(131072, (i) => (i * 7) & 0xff),
    'one byte over a block': _pattern(131073, (i) => (i * 7) & 0xff),
    'several blocks': _pattern(500000, (i) => 0x20 + (i * 7 + (i >> 5)) % 90),
    'past a single segment': _pattern(300000, (i) => (i * 2654435761) & 0xff),
    'a short phrase over and over': Uint8List.fromList(
        List.filled(400, 'the quick brown fox ').join().codeUnits),
    'text with long repeats': Uint8List.fromList(
        (List.generate(2000, (i) => 'line ${i} of a file that repeats itself\n')
                    .join() *
                3)
            .codeUnits),
    'matches across a block edge': _pattern(
        400000, (i) => 0x41 + ((i ~/ 97) % 3) * 7 + (i % 97 == 0 ? 1 : 0)),
    'incompressible':
        _pattern(200000, (i) => (i * 1103515245 + 12345) >> 7 & 0xff),
    'words drawn at random': _words(300000),
  };

  group('zstd encoder', () {
    for (final entry in cases.entries) {
      final source = entry.value;
      final crc = getCrc32(source);

      test('${entry.key} round trips', () {
        final encoded = const ZstdEncoder().encodeBytes(source);
        final decoded = ZstdDecoder()
            .decodeBytes(encoded, verify: true, throwOnError: true);
        expect(decoded.length, source.length);
        expect(getCrc32(decoded), crc);
      });

      test('${entry.key} round trips through a stream', () {
        final out = OutputMemoryStream();
        const ZstdEncoder().encodeStream(InputMemoryStream(source), out);
        final decoded = ZstdDecoder()
            .decodeBytes(out.getBytes(), verify: true, throwOnError: true);
        expect(getCrc32(decoded), crc);
      });

      test('${entry.key} reports the size it wrote', () {
        final encoded = const ZstdEncoder().encodeBytes(source);
        expect(ZstdDecoder().uncompressedSize(encoded), source.length);
      });
    }

    test('a frame without a checksum still round trips', () {
      final source = cases['several blocks']!;
      final encoded = const ZstdEncoder(checksum: false).encodeBytes(source);
      final decoded =
          ZstdDecoder().decodeBytes(encoded, verify: true, throwOnError: true);
      expect(getCrc32(decoded), getCrc32(source));
    });

    // A frame never opens with a repeated byte block, which older decoders
    // read as the frame ending early, so the first one is coded instead
    test('a repeated byte costs a handful of bytes a block', () {
      final encoded =
          const ZstdEncoder(checksum: false).encodeBytes(Uint8List(70000));
      expect(encoded.length, lessThan(24));
    });

    test('a repeating phrase compresses hard', () {
      final source = cases['a short phrase over and over']!;
      final encoded = const ZstdEncoder(checksum: false).encodeBytes(source);
      expect(encoded.length * 20, lessThan(source.length));
    });

    test('every sequence is accounted for', () {
      for (final entry in cases.entries) {
        final source = entry.value;
        final encoded = const ZstdEncoder().encodeBytes(source);
        final decoded = ZstdDecoder()
            .decodeBytes(encoded, verify: true, throwOnError: true);
        expect(decoded.length, source.length, reason: entry.key);
        expect(getCrc32(decoded), getCrc32(source), reason: entry.key);
      }
    });

    // A short source on purpose: the deepest levels search hard enough that a
    // few hundred kilobytes would dominate the whole suite
    test('every level round trips', () {
      final source = _words(30000);
      final crc = getCrc32(source);
      var first = 0;
      var last = 0;
      for (var level = 1; level <= zstdMaxLevel; level++) {
        final encoded =
            ZstdEncoder(checksum: false, level: level).encodeBytes(source);
        final decoded = ZstdDecoder().decodeBytes(encoded, throwOnError: true);
        expect(getCrc32(decoded), crc, reason: 'level $level');
        expect(encoded.length, lessThan(source.length >> 2),
            reason: 'level $level');
        if (level == 1) {
          first = encoded.length;
        }
        last = encoded.length;
      }
      // Only the two ends are compared: the table a source this small selects
      // is not monotone in the reference either, where level 2 reads worse
      // than level 1 and level 13 worse than level 12
      expect(last, lessThan(first * 3 ~/ 5));
    });

    test('a level out of range is clamped', () {
      final source = cases['text with long repeats']!;
      expect(ZstdEncoder(level: 99).encodeBytes(source).length,
          ZstdEncoder(level: zstdMaxLevel).encodeBytes(source).length);
      expect(ZstdEncoder(level: -5).encodeBytes(source).length,
          ZstdEncoder(level: 1).encodeBytes(source).length);
    });

    test('a higher level is not larger on real text', () {
      final source = cases['words drawn at random']!;
      final low = ZstdEncoder(checksum: false, level: 1).encodeBytes(source);
      final high = ZstdEncoder(checksum: false, level: 9).encodeBytes(source);
      expect(high.length * 3, lessThan(low.length * 2));
    });

    test('the top level function agrees with the class', () {
      final source = cases['eight bytes']!;
      expect(zstdEncode(source), const ZstdEncoder().encodeBytes(source));
    });
  });
}

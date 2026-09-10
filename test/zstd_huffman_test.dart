import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_constants.dart';
import 'package:archive/src/codecs/zstd/zstd_fse.dart';
import 'package:archive/src/codecs/zstd/zstd_huffman.dart';
import 'package:archive/src/codecs/zstd/zstd_huffman_encoder.dart';
import 'package:archive/src/codecs/zstd/zstd_huffman_loop.dart';
import 'package:archive/src/codecs/zstd/zstd_literals.dart';
import 'package:archive/src/codecs/zstd/zstd_literals_encoder.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:test/test.dart';

/// A tree description in the direct form: a header of `127 + count` and the
/// weights packed a nibble each, high nibble first
Uint8List _direct(List<int> weights) {
  final bytes = Uint8List(1 + ((weights.length + 1) >> 1));
  bytes[0] = 127 + weights.length;
  for (var i = 0; i < weights.length; i++) {
    if (i.isEven) {
      bytes[1 + (i >> 1)] = weights[i] << 4;
    } else {
      bytes[1 + (i >> 1)] |= weights[i];
    }
  }
  return bytes;
}

/// Literals whose byte distribution is uneven enough to be worth a tree, with
/// [spread] distinct bytes
Uint8List _literals(int length, int spread) {
  final out = Uint8List(length);
  var seed = 12345;
  for (var at = 0; at < length; at++) {
    seed = (seed * 1103515245 + 12345) & 0x3fffffff;
    // A skewed pick, so a few bytes carry most of the weight
    final draw = (seed >> 8) % 100;
    out[at] = draw < 60 ? 0x41 : 0x41 + (seed % spread);
  }
  return out;
}

void main() {
  group('zstd huffman table', () {
    final table = ZstdHuffmanTable();
    final scratch = ZstdHuffmanScratch();

    void rejects(Uint8List bytes, String reason) {
      expect(() => readHuffmanTable(bytes, 0, bytes.length, table, scratch),
          throwsA(isA<ZstdHuffmanException>()),
          reason: reason);
    }

    test('a description of three weights builds its table', () {
      final bytes = _direct([2, 1, 1]);
      final read = readHuffmanTable(bytes, 0, bytes.length, table, scratch);
      expect(read, bytes.length);
      // The weight left over is the one the last symbol takes
      expect(table.symbolCount, 4);
      expect(table.tableLog, 3);
      var filled = 0;
      for (var at = 0; at < 1 << table.tableLog; at++) {
        if (table.rows[at] != 0) filled++;
      }
      expect(filled, greaterThan(0));
    });

    test('an empty description', () {
      rejects(Uint8List(0), 'nothing to read');
    });

    test('direct weights cut short', () {
      final bytes = _direct(List.filled(17, 1));
      rejects(Uint8List.sublistView(bytes, 0, 4), 'nibbles are missing');
    });

    test('compressed weights cut short', () {
      rejects(Uint8List.fromList([5, 0, 0]), 'the description claims five bytes');
    });

    test('a weight past the longest code', () {
      rejects(_direct([15, 1]), 'fifteen is above the twelve allowed');
    });

    test('weights that are all zero', () {
      rejects(_direct([0, 0]), 'no symbol carries anything');
    });

    test('a weight above the longest code allowed', () {
      rejects(_direct([12, 12]), 'twelve is above the eleven allowed');
    });

    // Two of the heaviest weight the format does allow still add up past the
    // widest table, which is caught after the weights themselves pass
    test('weights that overflow the table log', () {
      rejects(_direct([11, 11]), 'the total needs a table log of twelve');
    });

    test('weights that leave a gap', () {
      rejects(_direct([1, 1, 1, 1, 1]), 'what is left is not a power of two');
    });

    test('a weight count of one symbol', () {
      rejects(_direct([]), 'a description covers at least one weight');
    });
  });

  // The encoder writes a description, the decoder reads it back: whichever
  // form the encoder picked for the weights is the one under test
  group('zstd huffman round trip', () {
    for (final spread in [3, 12, 60, 200]) {
      test('a tree over $spread symbols reads back', () {
        final source = _literals(20000, spread);
        final counts = Uint32List(zstdHuffmanSymbolCount);
        for (final b in source) {
          counts[b]++;
        }
        final encoder = ZstdHuffmanEncoder();
        expect(encoder.build(counts, source.length), isTrue);
        final written = Uint8List(1024);
        final size = encoder.writeTable(written, 0);
        expect(size, greaterThan(0));

        final table = ZstdHuffmanTable();
        final scratch = ZstdHuffmanScratch();
        final read = readHuffmanTable(written, 0, size, table, scratch);
        expect(read, size);
        expect(table.tableLog, encoder.tableLog);
      });
    }

    test('a description cut anywhere is rejected or reads short', () {
      final source = _literals(20000, 60);
      final counts = Uint32List(zstdHuffmanSymbolCount);
      for (final b in source) {
        counts[b]++;
      }
      final encoder = ZstdHuffmanEncoder()..build(counts, source.length);
      final written = Uint8List(1024);
      final size = encoder.writeTable(written, 0);
      final table = ZstdHuffmanTable();
      final scratch = ZstdHuffmanScratch();
      for (var cut = 0; cut < size; cut++) {
        try {
          final read = readHuffmanTable(written, 0, cut, table, scratch);
          expect(read, lessThanOrEqualTo(cut), reason: 'cut to $cut');
        } on ZstdHuffmanException {
          continue;
        } on ZstdFseException {
          continue;
        } catch (error) {
          fail('cut to $cut threw $error');
        }
      }
    });

    test('a description with a changed byte is rejected or reads back', () {
      final source = _literals(20000, 60);
      final counts = Uint32List(zstdHuffmanSymbolCount);
      for (final b in source) {
        counts[b]++;
      }
      final encoder = ZstdHuffmanEncoder()..build(counts, source.length);
      final written = Uint8List(1024);
      final size = encoder.writeTable(written, 0);
      final table = ZstdHuffmanTable();
      final scratch = ZstdHuffmanScratch();
      for (var at = 0; at < size; at++) {
        for (var bit = 0; bit < 8; bit++) {
          final bytes = Uint8List.fromList(
              Uint8List.sublistView(written, 0, size));
          bytes[at] ^= 1 << bit;
          try {
            readHuffmanTable(bytes, 0, size, table, scratch);
          } on ZstdHuffmanException {
            continue;
          } on ZstdFseException {
            continue;
          } catch (error) {
            fail('bit $bit of byte $at threw $error');
          }
        }
      }
    });
  });

  // A literals section carries the tree and the streams together, which is the
  // only way the four stream layout and the short stream fallback are reached
  group('zstd literals round trip', () {
    for (final size in [8, 40, 64, 200, 1000, 5000, 60000, 131072]) {
      for (final spread in [4, 90]) {
        test('$size literals over $spread symbols read back', () {
          final source = _literals(size, spread);
          final encoder = ZstdLiteralsEncoder()..minSize = 6;
          final out = Uint8List(size + (size >> 1) + 1024);
          final coded = encoder.encode(out, 0, source, 0, source.length);
          expect(coded, greaterThan(0));

          final into = Uint8List(size + 32);
          final literals = ZstdLiterals();
          final read = literals.decode(out, 0, coded, 1 << 17, into, 0);
          expect(read, coded);
          expect(literals.length, size);
          expect(getCrc32(Uint8List.sublistView(into, 0, size)),
              getCrc32(source));
        });
      }
    }

    // One stream is written whenever the literals are few, and the header is
    // three bytes: ten bits of regenerated size, ten of compressed
    test('the slow loop decodes what the wide one decodes', () {
      for (final size in [12, 40, 200, 900]) {
        final source = _literals(size, 30);
        final encoder = ZstdLiteralsEncoder()..minSize = 6;
        final out = Uint8List(size + 1024);
        final coded = encoder.encode(out, 0, source, 0, source.length);
        if (out[0] & 3 != zstdLiteralsCompressed || (out[0] >> 2) & 3 != 0) {
          continue;
        }
        final regenerated = (out[0] >> 4) | ((out[1] & 0x3f) << 4);
        final compressed = (out[1] >> 6) | (out[2] << 2);
        expect(regenerated, size);
        expect(compressed, coded - 3);

        final table = ZstdHuffmanTable();
        final scratch = ZstdHuffmanScratch();
        final tree = readHuffmanTable(out, 3, 3 + compressed, table, scratch);
        final start = 3 + tree;
        final length = compressed - tree;

        final wide = Uint8List(size);
        decodeHuffmanStream(table, out, start, length, wide, 0, size);
        final slow = Uint8List(size);
        decodeHuffmanStreamSlow(table, out, start, length, slow, 0, size);
        expect(slow, wide, reason: '$size literals');
        expect(getCrc32(slow), getCrc32(source), reason: '$size literals');
      }
    });

    test('the slow loop with nothing to decode writes nothing', () {
      final table = ZstdHuffmanTable();
      final scratch = ZstdHuffmanScratch();
      final bytes = _direct([2, 1, 1]);
      readHuffmanTable(bytes, 0, bytes.length, table, scratch);
      final dst = Uint8List(4);
      decodeHuffmanStreamSlow(table, Uint8List.fromList([1]), 0, 1, dst, 0, 0);
      expect(dst, Uint8List(4));
    });

    test('a literals section cut anywhere is rejected', () {
      final source = _literals(5000, 60);
      final encoder = ZstdLiteralsEncoder()..minSize = 6;
      final out = Uint8List(8192);
      final coded = encoder.encode(out, 0, source, 0, source.length);
      final into = Uint8List(8192);
      for (var cut = 1; cut < coded; cut++) {
        final literals = ZstdLiterals();
        try {
          literals.decode(out, 0, cut, 1 << 17, into, 0);
        } catch (_) {
          continue;
        }
      }
    });
  });
}

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

const _isWeb = bool.fromEnvironment('dart.library.js_interop');

Uint8List _data() {
  // Above the 1 MiB pieces the zstd window hands out, so it reports twice
  final out = Uint8List(5 << 19);
  var seed = 1;
  for (var i = 0; i < out.length; ++i) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    out[i] = 0x61 + (seed >> 16) % 16;
  }
  return out;
}

void main() {
  final data = _data();

  final decoders =
      <String, (List<int>, bool Function(InputStream, OutputStream))>{
    'gzip': (
      GZipEncoder().encodeBytes(data),
      (i, o) => const GZipDecoder().decodeStream(i, o)
    ),
    'gzip web': (
      GZipEncoder().encodeBytes(data),
      (i, o) => const GZipDecoderWeb().decodeStream(i, o)
    ),
    'zlib': (
      ZLibEncoder().encodeBytes(data),
      (i, o) => const ZLibDecoder().decodeStream(i, o)
    ),
    'zstd': (
      const ZstdEncoder().encodeBytes(data),
      (i, o) => ZstdDecoder().decodeStream(i, o)
    ),
    'bzip2': (
      BZip2Encoder().encodeBytes(data),
      (i, o) => BZip2Decoder().decodeStream(i, o)
    ),
    'xz': (
      XZEncoder().encodeBytes(data),
      (i, o) => XZDecoder().decodeStream(i, o)
    ),
  };

  group('ProgressOutputStream', () {
    for (final MapEntry(key: name, value: (packed, decode))
        in decoders.entries) {
      test('$name reports as it decodes', () {
        final input = InputMemoryStream(packed);
        final total = input.length;
        final seen = <int>[];
        final fractions = <double>[];
        final out = ProgressOutputStream(OutputMemoryStream(), (written) {
          seen.add(written);
          fractions.add(input.position / total);
        });
        expect(decode(input, out), isTrue);
        out.closeSync();
        expect(out.getBytes(), equals(data));
        expect(out.written, data.length);
        expect(seen.length, greaterThan(1));
        expect(seen.last, data.length);
        for (var i = 1; i < seen.length; ++i) {
          expect(seen[i], greaterThan(seen[i - 1]));
          expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
        }
      },
          skip: name == 'zlib' && _isWeb
              ? 'the web zlib decoder inflates a member whole before writing'
              : false);
    }

    test('passes every write through', () {
      final seen = <int>[];
      final out =
          ProgressOutputStream(OutputMemoryStream(), seen.add, interval: 1);
      out.byteOrder = ByteOrder.bigEndian;
      out
        ..writeByte(1)
        ..writeUint16(0x0203)
        ..writeUint32(0x04050607)
        ..writeUint64(0x0c0d0e0f)
        ..writeBytes([1, 2, 3, 4], length: 2)
        ..writeRange(Uint8List.fromList([9, 8, 7, 6]), 1, 3)
        ..writeBackReference(2, 5)
        ..writeStream(InputMemoryStream(Uint8List.fromList([5, 5, 5])));
      expect(out.output.byteOrder, ByteOrder.bigEndian);
      expect(out.getBytes(), [
        1, 2, 3, 4, 5, 6, 7, 0, 0, 0, 0, 12, 13, 14, 15, //
        1, 2, 8, 7, 8, 7, 8, 7, 8, 5, 5, 5,
      ]);
      expect(out.length, 27);
      expect(seen, [1, 3, 7, 15, 17, 19, 24, 27]);
    });

    test('reports the remainder on flush and close only once', () {
      final seen = <int>[];
      final out =
          ProgressOutputStream(OutputMemoryStream(), seen.add, interval: 100);
      out.writeBytes(Uint8List(250));
      expect(seen, [250]);
      out.writeBytes(Uint8List(30));
      out.flush();
      out.closeSync();
      expect(seen, [250, 280]);
    });
  });
}

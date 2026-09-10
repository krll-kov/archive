import 'dart:io';
import 'dart:typed_data';

import 'package:archive/src/codecs/zstd_decoder.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:archive/src/util/input_memory_stream.dart';
import 'package:archive/src/util/output_memory_stream.dart';
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
            () => ZstdDecoder()
                .decodeBytes(Uint8List.sublistView(bytes, 0, cut),
                    verify: true, throwOnError: true),
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
          () => ZstdDecoder()
              .decodeBytes(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
                  throwOnError: true),
          throwsA(anything));
      expect(ZstdDecoder().decodeBytes(Uint8List.fromList([1, 2, 3, 4])),
          isEmpty);
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
}

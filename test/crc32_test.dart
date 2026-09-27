import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

void main() {
  group('crc32', () {
    test('empty', () {
      final crcVal = getCrc32([]);
      expect(crcVal, 0);
    });
    test('1 byte', () {
      final crcVal = getCrc32([1]);
      expect(crcVal, 0xA505DF1B);
    });
    test('10 bytes', () {
      final crcVal = getCrc32([1, 2, 3, 4, 5, 6, 7, 8, 9, 0]);
      expect(crcVal, 0xC5F5BE65);
    });
    test('100000 bytes', () {
      var crcVal = getCrc32([]);
      for (var i = 0; i < 10000; i++) {
        crcVal = getCrc32([1, 2, 3, 4, 5, 6, 7, 8, 9, 0], crcVal);
      }
      expect(crcVal, 0x3AC67C2B);
    });
    test('typed views agree with bytewise CRC32 at every tail length', () {
      final random = Random(417);
      final data =
          Uint8List.fromList(List.generate(8200, (_) => random.nextInt(256)));
      for (var offset = 0; offset < 8; offset++) {
        for (var size = 0; size <= 4096; size++) {
          final view = Uint8List.sublistView(data, offset, offset + size);
          final seed = random.nextInt(0x100000000);
          expect(getCrc32(view, seed), getCrc32(view.toList(), seed),
              reason: 'offset $offset, size $size, seed $seed');
        }
      }
    });
  });
}

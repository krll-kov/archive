import 'dart:typed_data';

import 'package:archive/src/codecs/xz/xz_chunked.dart';
import 'package:test/test.dart';

// dart2js truncates every bitwise operator to 32 bits, so this file holds what
// the xz codec does above that. It reads no fixture and runs under `-p node`

void main() {
  group('xz web', () {
    test('the index records a size that does not fit in 32 bits', () {
      // XzChunkedEncoder writes a stream of 4 GiB as one block, so the index
      // holds this record. `>>` gave 0x80 0x00, the encoding of zero
      expect(xzMultibyteInteger(4294967296),
          equals(Uint8List.fromList([0x80, 0x80, 0x80, 0x80, 0x10])));
      expect(xzMultibyteInteger(4294967297),
          equals(Uint8List.fromList([0x81, 0x80, 0x80, 0x80, 0x10])));
      // 1 << 40 as a literal, since dart2js gives zero for a shift past 31
      expect(xzMultibyteInteger(1099511627776),
          equals(Uint8List.fromList([0x80, 0x80, 0x80, 0x80, 0x80, 0x20])));
    });

    test('the index records a size that fits in 32 bits', () {
      expect(xzMultibyteInteger(0), equals(Uint8List.fromList([0])));
      expect(xzMultibyteInteger(127), equals(Uint8List.fromList([0x7f])));
      expect(xzMultibyteInteger(128), equals(Uint8List.fromList([0x80, 0x01])));
      expect(xzMultibyteInteger(4294967295),
          equals(Uint8List.fromList([0xff, 0xff, 0xff, 0xff, 0x0f])));
    });
  });
}

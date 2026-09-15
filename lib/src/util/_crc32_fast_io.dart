import 'dart:typed_data';

bool isCrc32FastSupported_() => true;

/// Slice-by-eight tables built from the byte at a time one. Table k holds the
/// contribution of a byte sitting k places from the end of the eight byte
/// window. The eight lookups are independent that way, and the loop folds eight
/// bytes at once
Uint32List? _tables;

Uint32List _buildTables(List<int> base) {
  final tables = Uint32List(8 * 256);
  for (var i = 0; i < 256; i++) {
    tables[i] = base[i];
  }
  for (var k = 1; k < 8; k++) {
    for (var i = 0; i < 256; i++) {
      final p = tables[(k - 1) * 256 + i];
      tables[k * 256 + i] = (p >>> 8) ^ tables[p & 0xff];
    }
  }
  return tables;
}

int crc32Fast_(Uint8List array, int crc, List<int> base) {
  final tables = _tables ??= _buildTables(base);
  final length = array.length;
  if (length < 16) {
    return -1;
  }
  final bytes = ByteData.view(array.buffer, array.offsetInBytes, length);
  var value = crc ^ 0xffffffff;
  var i = 0;
  final limit = length - 8;
  while (i <= limit) {
    final word = bytes.getUint64(i, Endian.little);
    final low = (value ^ word) & 0xffffffff;
    final high = word >>> 32;
    value = tables[0x700 + (low & 0xff)] ^
        tables[0x600 + ((low >>> 8) & 0xff)] ^
        tables[0x500 + ((low >>> 16) & 0xff)] ^
        tables[0x400 + (low >>> 24)] ^
        tables[0x300 + (high & 0xff)] ^
        tables[0x200 + ((high >>> 8) & 0xff)] ^
        tables[0x100 + ((high >>> 16) & 0xff)] ^
        tables[high >>> 24];
    i += 8;
  }
  while (i < length) {
    value = tables[(value ^ array[i++]) & 0xff] ^ (value >>> 8);
  }
  return value ^ 0xffffffff;
}

import 'dart:typed_data';

bool isCrc64Supported_() => false;

int getCrc64_(List<int> array, [int crc = 0]) {
  throw UnsupportedError('Crc64 is not support on html');
}

/// The reflected ECMA-182 polynomial, the halves of 0xc96c5795d7870f42
const _polynomialHigh = 0xc96c5795;
const _polynomialLow = 0xd7870f42;

/// Built rather than written out: the sixty-four bit literals the other backend
/// holds cannot be spelled where an int stops at fifty-three
final Uint32List _tableHigh = _buildTable(true);
final Uint32List _tableLow = _buildTable(false);

Uint32List _buildTable(bool wantHigh) {
  final out = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var low = i;
    var high = 0;
    for (var bit = 0; bit < 8; bit++) {
      final carry = low & 1;
      low = ((low >>> 1) | ((high & 1) << 31)) & 0xffffffff;
      high = high >>> 1;
      if (carry != 0) {
        low ^= _polynomialLow;
        high ^= _polynomialHigh;
      }
    }
    out[i] = wantHigh ? high : low;
  }
  return out;
}

/// A running CRC-64 held as two thirty-two bit halves, which is the only shape
/// that survives a backend whose int is not sixty-four bits wide
class Crc64Core {
  var _high = 0;
  var _low = 0;

  void reset() {
    _high = 0;
    _low = 0;
  }

  /// The state is the finished value, so the initial and final inversions go
  /// on and come off around each call, the way [getCrc64_] chains
  void update(List<int> array) {
    final tableHigh = _tableHigh;
    final tableLow = _tableLow;
    var high = _high ^ 0xffffffff;
    var low = _low ^ 0xffffffff;
    for (var i = 0; i < array.length; i++) {
      final index = (low ^ array[i]) & 0xff;
      final shiftedLow = ((low >>> 8) | ((high & 0xff) << 24)) & 0xffffffff;
      low = (shiftedLow ^ tableLow[index]) & 0xffffffff;
      high = ((high >>> 8) ^ tableHigh[index]) & 0xffffffff;
    }
    _high = high ^ 0xffffffff;
    _low = low ^ 0xffffffff;
  }

  int get high32 => _high;

  int get low32 => _low;
}

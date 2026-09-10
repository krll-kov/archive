import 'dart:typed_data';

/// Writes the bitstreams the format reads backwards. At most 63 bits stand
/// unflushed, which is what makes the shift masks below no-ops
class ZstdBitWriter {
  final ByteData view;

  int _container = 0;
  int _bits = 0;
  int _at;

  ZstdBitWriter(this.view, [int start = 0]) : _at = start;

  /// Counts are masked so the shift carries no range guard and no slow path
  @pragma('vm:prefer-inline')
  void add(int value, int count) {
    _container |= (value & ((1 << (count & 63)) - 1)) << (_bits & 63);
    _bits += count;
  }

  /// [value] must have nothing set above [count]
  @pragma('vm:prefer-inline')
  void addClean(int value, int count) {
    _container |= value << (_bits & 63);
    _bits += count;
  }

  @pragma('vm:prefer-inline')
  void flush() {
    final bytes = _bits >> 3;
    view.setUint64(_at, _container, Endian.little);
    _at += bytes;
    _bits &= 7;
    _container >>>= (bytes << 3) & 63;
  }

  /// Adds the marker bit the reader looks for
  int close() {
    addClean(1, 1);
    flush();
    return _at + (_bits > 0 ? 1 : 0);
  }
}

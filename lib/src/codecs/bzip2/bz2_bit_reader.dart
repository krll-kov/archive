import '../../util/input_stream.dart';

/// Internal class used by [BZip2Decoder]
class Bz2BitReader {
  InputStream input;

  Bz2BitReader(this.input);

  int readByte() => readBits(8);

  /// Bits still unread in the byte being taken apart. A caller resuming at a
  /// bit that is not on a byte boundary accounts for them
  int get bitsLeft => _bitPos;

  /// Set once a read went past the end of the input. An archive cut inside a
  /// block asks for bytes that are not there, and the two input streams answer
  /// differently: a file reads zeros past its end, memory throws. So we stop
  /// here instead and the decoder returns a failure either way
  bool get overrun => _overrun;

  int _nextByte() {
    if (input.isEOS) {
      _overrun = true;
      return 0;
    }
    return input.readByte();
  }

  /// Read a number of bits from the input stream.
  int readBits(int numBits) {
    if (numBits == 0) {
      return 0;
    }

    if (_bitPos == 0) {
      _bitPos = 8;
      _bitBuffer = _nextByte();
    }

    var value = 0;

    while (numBits > _bitPos) {
      value = (value << _bitPos) + (_bitBuffer & _bitMask[_bitPos]);
      numBits -= _bitPos;
      _bitPos = 8;
      _bitBuffer = _nextByte();
    }

    if (numBits > 0) {
      if (_bitPos == 0) {
        _bitPos = 8;
        _bitBuffer = _nextByte();
      }

      value = (value << numBits) +
          (_bitBuffer >> (_bitPos - numBits) & _bitMask[numBits]);

      _bitPos -= numBits;
    }

    return value;
  }

  int _bitBuffer = 0;
  int _bitPos = 0;
  var _overrun = false;

  static const List<int> _bitMask = [0, 1, 3, 7, 15, 31, 63, 127, 255];
}

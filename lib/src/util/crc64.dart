// [getCrc64] returns the check as one int. Only a backend whose int is a real
// 64 bit integer has that, and [isCrc64Supported] reports false elsewhere.
// [Crc64] keeps two halves instead and hands them back as bytes. xz wants
// bytes anyway.
//
// The condition below picks on integer width, not on dart:io. dart:isolate
// exists on exactly the VM and wasm. dart.library.html is false on dart2js
// targeting Node. Node then took the 64 bit table and failed to compile on
// literals like 0xb32e4cbe03a75f6f.
import 'dart:typed_data';

import '_crc64_html.dart' if (dart.library.isolate) '_crc64_io.dart';

int getCrc64(List<int> array, [int crc = 0]) => getCrc64_(array, crc);

bool isCrc64Supported() => isCrc64Supported_();

/// A running CRC-64 over however many pieces the bytes arrive in, on every
/// backend. The value leaves as eight little endian bytes. An int does not
/// hold it where dart2js compiles
class Crc64 {
  final Crc64Core _core = Crc64Core();

  void reset() => _core.reset();

  void update(List<int> array) => _core.update(array);

  /// The check as the format stores it, eight bytes little endian
  Uint8List get bytes {
    final low = _core.low32;
    final high = _core.high32;
    return Uint8List.fromList([
      low & 0xff,
      (low >>> 8) & 0xff,
      (low >>> 16) & 0xff,
      (low >>> 24) & 0xff,
      high & 0xff,
      (high >>> 8) & 0xff,
      (high >>> 16) & 0xff,
      (high >>> 24) & 0xff,
    ]);
  }

  /// Whether the eight bytes of [stored] starting at [at] are this check
  bool matches(List<int> stored, int at) {
    if (at + 8 > stored.length) {
      return false;
    }
    final want = bytes;
    for (var i = 0; i < 8; i++) {
      if (stored[at + i] != want[i]) {
        return false;
      }
    }
    return true;
  }
}

/// The check over [array] whole, for a caller with nothing to keep between
/// pieces
Uint8List crc64Bytes(List<int> array) => (Crc64()..update(array)).bytes;

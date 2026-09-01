import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// This file deliberately avoids dart:io so that it can be run on the web
// targets as well as the VM, with `dart test -p chrome` or `-p node`. The
// thing being guarded here is a per platform choice, so a test that only ever
// runs on the VM would not guard much.

// 'hello\n' compressed with xz, small enough to embed. Decoding it exercises
// the range decoder that the platform selected.
const _helloXz =
    '/Td6WFoAAATm1rRGAgAhARYAAAB0L+WjAQAFaGVsbG8KAAAApWCX8ZT2/eAAAR4GwS'
    '+kHR+2830BAAAAAARZWg==';

void main() {
  group('lzma range decoder', () {
    test('picks the implementation this platform can run', () {
      // An int is a JavaScript number exactly where 1 and 1.0 are identical,
      // and that is exactly where the branchless 64 bit implementation gives
      // wrong answers rather than slow ones. Everywhere else it is both
      // correct and faster, so the two have to line up.
      //
      // The conditional export in range_decoder.dart is easy to get subtly
      // wrong. Selecting the branching implementation on wasm breaks nothing
      // visible, it only gives up about a sixth of the decoding speed, which
      // is exactly the kind of regression that survives a green test suite.
      final jsNumbers = identical(1, 1.0);
      expect(rangeDecoderImplementation, jsNumbers ? 'web' : 'native');
    });

    test('decodes the same bytes whichever implementation was selected', () {
      final compressed = base64.decode(_helloXz);
      expect(
          XZDecoder().decodeBytes(compressed), equals(utf8.encode('hello\n')));
    });
  });
}

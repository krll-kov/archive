import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// Sizes the encoder used to get wrong. Every archive here is read back with
// the checks on, which is what catches an index or a chunk that does not
// describe the block it belongs to.

Uint8List _sample(int size) {
  final data = Uint8List(size);
  for (var i = 0; i < size; i++) {
    data[i] = (i * 7 + (i >> 8)) & 0xff;
  }
  return data;
}

void main() {
  group('xz encoder', () {
    // A block's unpadded length passes 127 at about a hundred bytes of input,
    // which is where the index needs a second byte, and it passes 16383 two
    // hundred bytes later. A chunk fills at 64 KiB
    const sizes = [
      0,
      1,
      6,
      100,
      104,
      110,
      1000,
      16383,
      16384,
      65535,
      65536,
      65537,
      200000,
    ];
    for (final size in sizes) {
      test('$size bytes come back byte for byte', () {
        final source = _sample(size);
        final archive = XZEncoder().encodeBytes(source);
        expect(XZDecoder().decodeBytes(archive, verify: true, throwOnError: true),
            source);
      });
    }

    for (final check in XZCheck.values) {
      test('a $check archive of 1000 bytes reads back', () {
        final source = _sample(1000);
        final archive = XZEncoder().encodeBytes(source, check: check);
        expect(XZDecoder().decodeBytes(archive, verify: true, throwOnError: true),
            source);
      });
    }
  });

  group('xz chunked encoder', () {
    Uint8List encode(Uint8List source, int piece, {XZCheck? check}) {
      final held = _Held();
      final encoder = check == null
          ? XzChunkedEncoder(held)
          : XzChunkedEncoder(held, check: check);
      for (var at = 0; at < source.length; at += piece) {
        final end = at + piece < source.length ? at + piece : source.length;
        encoder.add(Uint8List.sublistView(source, at, end));
      }
      encoder.close();
      return held.bytes;
    }

    for (final size in [0, 6, 1000, 65535, 65536, 65537, 200000]) {
      test('$size bytes give the archive the whole input would', () {
        final source = _sample(size);
        // The pieces the input arrives in must not reach the archive
        final whole = XZEncoder().encodeBytes(source);
        for (final piece in [1, 7, 4096, 65536, size + 1]) {
          expect(encode(source, piece), whole, reason: 'piece size $piece');
        }
      });
    }

    for (final check in [XZCheck.none, XZCheck.crc32, XZCheck.crc64]) {
      test('a $check archive reads back', () {
        final source = _sample(5000);
        final archive = encode(source, 700, check: check);
        expect(XZDecoder().decodeBytes(archive, verify: true, throwOnError: true),
            source);
      });
    }

    test('a SHA-256 check is refused rather than written wrong', () {
      expect(() => encode(_sample(100), 100, check: XZCheck.sha256),
          throwsA(isA<ArchiveException>()));
    });

    test('a SHA-256 check is refused before any byte reaches the sink', () {
      // Refused at close, the header and every block had already gone out
      final held = _Held();
      expect(
          () => const XzCodec(check: XZCheck.sha256)
              .encoder
              .startChunkedConversion(held),
          throwsA(isA<ArchiveException>()));
      expect(held.bytes, isEmpty);
    });

    test('any sizes and any cuts give an archive that reads back', () {
      final random = Random(20260911);
      for (var round = 0; round < 60; round++) {
        final size = random.nextInt(200000);
        final source = _sample(size);
        final held = _Held();
        final encoder = XzChunkedEncoder(held);
        var at = 0;
        while (at < size) {
          // Pieces of no particular size, the way a source hands them over
          final take = 1 + random.nextInt(70000);
          final end = at + take < size ? at + take : size;
          encoder.addSlice(source, at, end, false);
          at = end;
        }
        encoder.close();
        final archive = held.bytes;
        expect(XZDecoder().decodeBytes(archive, verify: true, throwOnError: true),
            source,
            reason: 'size $size');
        expect(archive, XZEncoder().encodeBytes(source), reason: 'size $size');
      }
    });

    test('a Stream encodes and decodes back through the two converters',
        () async {
      final source = _sample(300000);
      final pieces = <List<int>>[];
      for (var at = 0; at < source.length; at += 8192) {
        final end = at + 8192 < source.length ? at + 8192 : source.length;
        pieces.add(Uint8List.sublistView(source, at, end));
      }
      final got = <int>[];
      await for (final piece in Stream<List<int>>.fromIterable(pieces)
          .transform(xzCodec.encoder)
          .transform(xzCodec.decoder)) {
        got.addAll(piece);
      }
      expect(got, source);
    });
  });
}

class _Held implements Sink<List<int>> {
  final _pieces = <List<int>>[];
  var _length = 0;

  @override
  void add(List<int> data) {
    _pieces.add(data);
    _length += data.length;
  }

  @override
  void close() {}

  Uint8List get bytes {
    final out = Uint8List(_length);
    var at = 0;
    for (final piece in _pieces) {
      out.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return out;
  }
}

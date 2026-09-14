import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// bzip2 is a bit stream: a block starts wherever the last one ended, not on a
// byte boundary, and carries no length. So the chunked decoder has to find the
// marker that ends a block before it can decode it, and the thing to check is
// that where the input is cut makes no difference to what comes out.

Uint8List _source(int length, int seed) {
  final bytes = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    // Runs of one byte, which is what the format's own run coding is for
    bytes[i] = (state >> 16) % 7 == 0 ? 0x41 : (state >> 8) & 0xff;
  }
  return bytes;
}

Uint8List _encode(Uint8List source, int piece, {int blockSize100k = 9}) {
  final held = _Held();
  final encoder = BZip2ChunkedEncoder(held, blockSize100k: blockSize100k);
  for (var at = 0; at < source.length; at += piece) {
    final end = at + piece < source.length ? at + piece : source.length;
    encoder.addSlice(source, at, end, false);
  }
  encoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

Uint8List _decode(Uint8List archive, int piece, {bool verify = true}) {
  final held = _Held();
  final decoder = BZip2ChunkedDecoder(held, verify: verify);
  for (var at = 0; at < archive.length; at += piece) {
    final end = at + piece < archive.length ? at + piece : archive.length;
    decoder.addSlice(archive, at, end, false);
  }
  decoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

void main() {
  final small = File('test/_data/bzip2/test.bz2').readAsBytesSync();

  group('bzip2 chunked decoder', () {
    test('an archive decodes the same whatever the pieces', () {
      final want = BZip2Decoder().decodeBytes(small, verify: true);
      for (final piece in [1, 3, 64, 813, 1 << 16]) {
        expect(_decode(small, piece), want, reason: 'piece $piece');
      }
    });

    test('a block that is not the first reads back', () {
      // Small blocks, so a few hundred kilobytes spans several of them
      final source = _source(400000, 7);
      final archive = _encode(source, 1 << 16, blockSize100k: 1);
      for (final piece in [1, 101, 4096, archive.length]) {
        expect(_decode(archive, piece), source, reason: 'piece $piece');
      }
    });

    test('two archives one after the other read as one', () {
      final source = _source(50000, 11);
      final one = _encode(source, 4096, blockSize100k: 1);
      final joined = Uint8List(one.length * 2)
        ..setRange(0, one.length, one)
        ..setRange(one.length, one.length * 2, one);
      final want = Uint8List(source.length * 2)
        ..setRange(0, source.length, source)
        ..setRange(source.length, source.length * 2, source);
      for (final piece in [7, 1024, joined.length]) {
        expect(_decode(joined, piece), want, reason: 'piece $piece');
      }
    });

    test('an archive cut short is refused', () {
      expect(
          () => _decode(Uint8List.sublistView(small, 0, small.length - 4), 8),
          throwsA(isA<ArchiveException>()));
    });

    test('input that is not bzip2 is refused', () {
      final bogus = Uint8List.fromList('not an archive at all'.codeUnits);
      expect(() => _decode(bogus, 4), throwsA(isA<ArchiveException>()));
    });

    test('an empty input is refused', () {
      expect(() => _decode(Uint8List(0), 1), throwsA(isA<ArchiveException>()));
    });

    test('a block whose check was changed is caught', () {
      final broken = Uint8List.fromList(small);
      // The stored block check sits right behind the 48 bit marker, which the
      // signature puts on a byte boundary for the first block
      broken[10] ^= 0xff;
      expect(() => _decode(broken, 16), throwsA(isA<ArchiveException>()));
      expect(() => _decode(broken, 16, verify: false), returnsNormally);
    });
  });

  group('bzip2 chunked encoder', () {
    test('it writes what one buffer writes', () {
      for (final length in [0, 1, 999, 200000]) {
        final source = _source(length, length + 3);
        final want = BZip2Encoder().encodeBytes(source);
        for (final piece in [1, 13, 4096, 1 << 20]) {
          expect(_encode(source, piece < 1 ? 1 : piece), want,
              reason: 'length $length piece $piece');
        }
      }
    });

    test('an input spanning blocks reads back', () {
      final source = _source(700000, 23);
      for (final blockSize100k in [1, 3, 9]) {
        final archive = _encode(source, 8192, blockSize100k: blockSize100k);
        expect(BZip2Decoder().decodeBytes(archive, verify: true), source,
            reason: 'blockSize100k $blockSize100k');
        expect(_decode(archive, 1024), source,
            reason: 'blockSize100k $blockSize100k');
      }
    });

    test('a length landing on a block edge reads back', () {
      // The block fills at this many positions, and run coding means a block
      // can hold more raw bytes than that, so both sides of the edge matter
      const blockMax = 100000 - 19;
      for (final length in [
        blockMax - 1,
        blockMax,
        blockMax + 1,
        blockMax * 2,
        blockMax * 2 + 1,
      ]) {
        final source = _source(length, length);
        final want = BZip2Encoder().encodeBytes(source, blockSize100k: 1);
        for (final piece in [1, 4095, length]) {
          expect(_encode(source, piece, blockSize100k: 1), want,
              reason: 'length $length piece $piece');
        }
        expect(_decode(want, 1023), source, reason: 'length $length');
      }
    });

    test('a run longer than the format codes in one go reads back', () {
      // 255 is where the run coding starts over, and a block then holds far
      // more raw bytes than it has positions
      for (final length in [254, 255, 256, 257, 300000]) {
        final source = Uint8List(length)..fillRange(0, length, 0x5a);
        expect(_encode(source, 997, blockSize100k: 1),
            BZip2Encoder().encodeBytes(source, blockSize100k: 1),
            reason: 'run $length');
        expect(_decode(_encode(source, 997, blockSize100k: 1), 64), source,
            reason: 'run $length');
      }
    });

    test('an empty input still writes an archive', () {
      final held = _Held();
      BZip2ChunkedEncoder(held).close();
      expect(held.closed, isTrue);
      expect(held.bytes, BZip2Encoder().encodeBytes(Uint8List(0)));
      expect(_decode(held.bytes, 1), isEmpty);
    });

    test('a block size outside one to nine is refused', () {
      expect(() => BZip2ChunkedEncoder(_Held(), blockSize100k: 0),
          throwsA(isA<ArchiveException>()));
      expect(() => BZip2ChunkedEncoder(_Held(), blockSize100k: 10),
          throwsA(isA<ArchiveException>()));
    });
  });

  group('bzip2 codec', () {
    test('convert goes through the chunked path both ways', () {
      final source = _source(120000, 31);
      final archive = bzip2Codec.encode(source);
      expect(archive, BZip2Encoder().encodeBytes(source));
      expect(bzip2Codec.decode(archive), source);
    });

    test('a stream transforms', () async {
      final source = _source(150000, 37);
      final pieces = <List<int>>[];
      for (var at = 0; at < source.length; at += 9999) {
        final end = at + 9999 < source.length ? at + 9999 : source.length;
        pieces.add(Uint8List.sublistView(source, at, end));
      }
      final archive = await Stream.fromIterable(pieces)
          .transform(bzip2Codec.encoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      final back = await Stream.fromIterable([archive])
          .transform(bzip2Codec.decoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      expect(back, source);
    });

    // The input may stop sending without closing, as dart:io's gzip is
    // expected to cope with: what cannot be bzip2 fails at once, and a whole
    // archive is out before the input closes
    test('a byte no archive starts with is refused at once', () async {
      final source = StreamController<List<int>>();
      final failed = Completer<Object>();
      final subscription = source.stream
          .transform(bzip2Codec.decoder)
          .listen((_) {}, onError: failed.complete);
      source.add([0x42, 0x5a, 0x69]);
      expect(await failed.future.timeout(const Duration(seconds: 5)),
          isA<ArchiveException>());
      await subscription.cancel();
      await source.close();
    });

    test('a whole archive comes out before the input closes', () async {
      final content = _source(3000, 41);
      final source = StreamController<List<int>>();
      final got = <int>[];
      final arrived = Completer<void>();
      final subscription =
          source.stream.transform(bzip2Codec.decoder).listen((piece) {
        got.addAll(piece);
        if (got.length >= content.length && !arrived.isCompleted) {
          arrived.complete();
        }
      });
      source.add(BZip2Encoder().encodeBytes(content));
      await arrived.future.timeout(const Duration(seconds: 5));
      expect(got, content);
      await subscription.cancel();
      expect(source.hasListener, isFalse);
      await source.close();
    });
  });
}

class _Held implements Sink<List<int>> {
  final _pieces = <List<int>>[];
  var _length = 0;
  var closed = false;

  @override
  void add(List<int> data) {
    _pieces.add(data);
    _length += data.length;
  }

  @override
  void close() {
    closed = true;
  }

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

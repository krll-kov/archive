import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The chunked decoder is the pull decoder turned inside out, so what it must
// do is agree with it on every archive whatever the input is cut into. The
// archives are the ones the pull decoder is already tested against.

Uint8List _archive(String name) =>
    File(p.join('test/_data/xz', name)).readAsBytesSync();

Uint8List _decode(Uint8List src, int piece, {bool verify = true}) {
  final held = _Held();
  final decoder = XzChunkedDecoder(held, verify: verify);
  for (var at = 0; at < src.length; at += piece) {
    final end = at + piece < src.length ? at + piece : src.length;
    decoder.add(Uint8List.sublistView(src, at, end));
  }
  decoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

void main() {
  const archives = [
    'cat.jpg.xz',
    'concatenated.xz',
    'crc32.xz',
    'crc64.xz',
    'empty.xz',
    'good-1-lzma2-1.xz',
    'hello.xz',
    'hello-hello-hello.xz',
    'long_distance.xz',
    'nocheck.xz',
    'pb4.xz',
    'sha256.xz',
    'stream_padding.xz',
    'x86.xz',
  ];

  group('xz chunked decoder', () {
    for (final name in archives) {
      test('$name decodes the same whatever the pieces', () {
        final src = _archive(name);
        final want =
            XZDecoder().decodeBytes(src, verify: true, throwOnError: true);
        for (final piece in [1, 2, 7, 64, 1024, 1 << 16, src.length + 1]) {
          expect(_decode(src, piece), want, reason: 'piece size $piece');
        }
      });
    }

    test('a truncated archive is rejected', () {
      final src = _archive('good-1-lzma2-1.xz');
      expect(() => _decode(Uint8List.sublistView(src, 0, src.length - 8), 64),
          throwsA(isA<ArchiveException>()));
    });

    test('a first LZMA2 chunk without a dictionary reset is rejected', () {
      final encoded = XZEncoder().encodeBytes([1, 2, 3], check: XZCheck.crc32);
      expect(encoded[24], 1);
      encoded[24] = 2;
      expect(() => xzCodec.decode(encoded), throwsA(isA<ArchiveException>()));
    });

    test('a damaged block is caught by its check', () {
      final src = Uint8List.fromList(_archive('crc32.xz'));
      src[src.length - 20] ^= 0xff;
      expect(() => _decode(src, 64), throwsA(isA<ArchiveException>()));
    });

    test('a closed sink refuses more bytes, the way dart:io filters do', () {
      final src = _archive('hello.xz');
      final decoder = XzChunkedDecoder(_Held())
        ..add(src)
        ..close();
      expect(() => decoder.add(src), throwsStateError);
    });

    test('a sink that failed keeps reporting the same failure', () {
      final decoder = XzChunkedDecoder(_Held(), verify: true);
      // Not an xz signature, which the first piece is enough to know
      expect(() => decoder.add(Uint8List(64)),
          throwsA(isA<ArchiveException>()));
      // What follows is not read as if the failure had not happened
      expect(() => decoder.add(_archive('hello.xz')),
          throwsA(isA<ArchiveException>()));
      expect(decoder.close, throwsA(isA<ArchiveException>()));
    });

    test('the check runs unless it is turned off', () {
      // The eight bytes of the CRC64 sit between the block and the index, so
      // damaging one of them leaves data only the check can call wrong
      final src = Uint8List.fromList(_archive('cat.jpg.xz'));
      src[src.length - 28] ^= 0xff;
      final held = _Held();
      // The default verifies, which is the only chance a stream reader gets
      expect(() => XzChunkedDecoder(held)..add(src)..close(),
          throwsA(isA<ArchiveException>()));
      expect(() {
        XzChunkedDecoder(_Held(), verify: false)
          ..add(src)
          ..close();
      }, returnsNormally);
    });

    test('addSlice takes a range and closes on the last one', () {
      final src = _archive('cat.jpg.xz');
      final want =
          XZDecoder().decodeBytes(src, verify: true, throwOnError: true);
      final held = _Held();
      final decoder = XzChunkedDecoder(held);
      const piece = 700;
      for (var at = 0; at < src.length; at += piece) {
        final end = at + piece < src.length ? at + piece : src.length;
        decoder.addSlice(src, at, end, end == src.length);
      }
      expect(held.closed, isTrue);
      expect(held.bytes, want);
    });

    // The pull decoder is what this has to agree with, so the agreement is
    // checked on every truncation and every single byte change of an archive,
    // rather than on the handful of ways one imagines it could go wrong
    for (final name in const [
      'empty.xz',
      'hello.xz',
      'crc32.xz',
      'crc64.xz',
      'nocheck.xz',
      'sha256.xz',
      'pb4.xz',
      'stream_padding.xz',
      'hello-hello-hello.xz',
    ]) {
      test('$name takes exactly what the pull decoder takes, damaged any way',
          () {
        final base = _archive(name);
        void agree(Uint8List src, String what) {
          Uint8List? pull;
          try {
            pull = XZDecoder().decodeBytes(src, verify: true, throwOnError: true);
          } catch (_) {
            pull = null;
          }
          for (final piece in const [1, 13, 4096]) {
            Uint8List? chunked;
            try {
              chunked = _decode(src, piece);
            } catch (_) {
              chunked = null;
            }
            expect(chunked != null, pull != null,
                reason: '$what, piece $piece: one took it and the other did '
                    'not');
            if (pull != null && chunked != null) {
              expect(chunked, pull, reason: '$what, piece $piece');
            }
          }
        }

        for (var length = 0; length <= base.length; length++) {
          agree(Uint8List.sublistView(base, 0, length), 'cut at $length');
        }
        for (var at = 0; at < base.length; at++) {
          final src = Uint8List.fromList(base);
          src[at] ^= 0xff;
          agree(src, 'byte $at flipped');
        }
      });
    }

    test('an empty input is rejected', () {
      expect(() => XzChunkedDecoder(_Held()).close(),
          throwsA(isA<ArchiveException>()));
    });
  });

  group('xz stream converter', () {
    test('the default encoder writes the native CRC64 check on every backend',
        () {
      final native = base64Decode(
          '/Td6WFoAAATm1rRGAgAhARYAAAB0L+WjAQACAQIDAACjq/XzQTeKOwABGwMLL7kQ'
          'H7bzfQEAAAAABFla');
      expect(xzCodec.encode([1, 2, 3]), native);
    });

    for (final name in ['cat.jpg.xz', 'concatenated.xz', 'x86.xz', 'pb4.xz']) {
      test('$name decodes from the file the way a reader gets it', () async {
        final want = XZDecoder()
            .decodeBytes(_archive(name), verify: true, throwOnError: true);
        final got = <int>[];
        // openRead hands over whatever the file system gave it, when it gave
        // it, which is the arrival a caller actually has
        await for (final piece in File(p.join('test/_data/xz', name))
            .openRead()
            .transform(xzCodec.decoder)) {
          got.addAll(piece);
        }
        expect(got, want);
      });
    }

    test('pieces that arrive one event apart decode the same', () async {
      final src = _archive('cat.jpg.xz');
      final want =
          XZDecoder().decodeBytes(src, verify: true, throwOnError: true);
      final random = Random(20260910);
      final controller = StreamController<List<int>>();
      final done = controller.stream
          .transform(xzCodec.decoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      var at = 0;
      while (at < src.length) {
        final take = 1 + random.nextInt(3000);
        final end = at + take < src.length ? at + take : src.length;
        // A real source yields between events, which is where a decoder that
        // held state on the stack rather than in fields would come apart
        await Future<void>.delayed(Duration.zero);
        controller.add(Uint8List.sublistView(src, at, end));
        at = end;
      }
      await controller.close();
      expect(await done, want);
    });

    test('a reader that pauses gets everything once it resumes', () async {
      final src = _archive('cat.jpg.xz');
      final want =
          XZDecoder().decodeBytes(src, verify: true, throwOnError: true);
      final got = <int>[];
      final finished = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      var paused = false;
      subscription = File(p.join('test/_data/xz', 'cat.jpg.xz'))
          .openRead()
          .transform(xzCodec.decoder)
          .listen((piece) {
        got.addAll(piece);
        if (!paused) {
          paused = true;
          subscription.pause();
          unawaited(Future<void>.delayed(const Duration(milliseconds: 20))
              .then((_) => subscription.resume()));
        }
      }, onDone: finished.complete);
      await finished.future;
      expect(got, want);
    });

    test('output keeps up with a download rather than waiting for it',
        () async {
      // Forty copies of the same archive is a valid xz file of forty streams,
      // which is what gives a long input with something to hand over all the
      // way through it
      final one = _archive('cat.jpg.xz');
      final src = Uint8List(one.length * 40);
      for (var i = 0; i < 40; i++) {
        src.setRange(i * one.length, (i + 1) * one.length, one);
      }
      final want = XZDecoder().decodeBytes(one, verify: true).length * 40;

      final controller = StreamController<List<int>>();
      var fed = 0;
      var decoded = 0;
      var fedAtFirstOutput = -1;
      var decodedWhenFedOut = 0;
      final finished = Completer<void>();
      controller.stream.transform(xzCodec.decoder).listen((piece) {
        if (fedAtFirstOutput < 0) {
          fedAtFirstOutput = fed;
        }
        decoded += piece.length;
      }, onDone: finished.complete);

      // Pieces the size a socket hands over, one event apart, which is the
      // shape of a download rather than of a buffer that is already full
      const piece = 16 << 10;
      for (var at = 0; at < src.length; at += piece) {
        final end = at + piece < src.length ? at + piece : src.length;
        controller.add(Uint8List.sublistView(src, at, end));
        fed = end;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      decodedWhenFedOut = decoded;
      await controller.close();
      await finished.future;

      expect(decoded, want);
      // Something came out long before the input ran out
      expect(fedAtFirstOutput, lessThan(src.length ~/ 5));
      // And most of it was already out by the time the last piece arrived,
      // which is what a decoder that held the archive could not do
      expect(decodedWhenFedOut, greaterThan((want * 0.9).round()));
    });

    test('convert takes the whole archive at once', () {
      final src = _archive('hello.xz');
      expect(const XzDecoderConverter(verify: true).convert(src),
          XZDecoder().decodeBytes(src, verify: true, throwOnError: true));
    });

    test('a failure reaches the stream as an error', () async {
      final src = _archive('good-1-lzma2-1.xz');
      final cut = Uint8List.sublistView(src, 0, src.length ~/ 2);
      expect(
          Stream<List<int>>.fromIterable([cut]).transform(xzCodec.decoder).toList(),
          throwsA(isA<ArchiveException>()));
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

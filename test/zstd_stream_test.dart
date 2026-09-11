import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The chunked decoder is the frame decoder turned inside out, so what it has to
// do is agree with it on every archive whatever the input is cut into. The
// archives are the ones the whole-input decoder is already tested against.

final _directory = Directory('test/_data/zstd');

Uint8List _archive(String name) =>
    File(p.join(_directory.path, name)).readAsBytesSync();

List<String> _archives() => _directory
    .listSync()
    .whereType<File>()
    .map((f) => f.uri.pathSegments.last)
    .where((name) => name.endsWith('.zst'))
    .toList()
  ..sort();

Uint8List _decode(Uint8List src, int piece,
    {bool verify = true, ZstdDictionary? dictionary}) {
  final held = _Held();
  final decoder =
      ZstdChunkedDecoder(held, verify: verify, dictionary: dictionary);
  for (var at = 0; at < src.length; at += piece) {
    final end = at + piece < src.length ? at + piece : src.length;
    decoder.addSlice(src, at, end, false);
  }
  decoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

void main() {
  final dictionaries = {
    'raw': ZstdDictionary(_archive('dict-raw.dict')),
    'trained': ZstdDictionary(_archive('dict-trained.dict')),
  };

  ZstdDictionary? dictionaryFor(String name) {
    if (name.startsWith('dv-') || name.contains('-dict')) {
      return name.contains('raw') ? dictionaries['raw'] : dictionaries['trained'];
    }
    return null;
  }

  group('zstd chunked decoder', () {
    for (final name in _archives()) {
      test('$name decodes the same whatever the pieces', () {
        final src = _archive(name);
        final dictionary = dictionaryFor(name);
        Uint8List? want;
        try {
          want = ZstdDecoder(dictionary: dictionary)
              .decodeBytes(src, verify: true, throwOnError: true);
        } catch (_) {
          want = null;
        }
        for (final piece in [1, 3, 64, 4096, 1 << 16, src.length + 1]) {
          Uint8List? got;
          try {
            got = _decode(src, piece, dictionary: dictionary);
          } catch (_) {
            got = null;
          }
          expect(got != null, want != null, reason: 'piece $piece');
          if (want != null && got != null) {
            expect(got, want, reason: 'piece $piece');
          }
        }
      });
    }

    test('a truncated frame is rejected', () {
      final src = _archive('text-1k-l19.zst');
      expect(() => _decode(Uint8List.sublistView(src, 0, src.length - 6), 64),
          throwsA(isA<ArchiveException>()));
    });

    test('a damaged frame is caught by its checksum', () {
      final src = Uint8List.fromList(_archive('text-1k-l19.zst'));
      src[src.length - 12] ^= 0xff;
      expect(() => _decode(src, 64), throwsA(isA<ArchiveException>()));
    });

    test('the check runs unless it is turned off', () {
      final src = Uint8List.fromList(_archive('text-1k-l19.zst'));
      // The last four bytes are the frame's XXH64, which only the check reads
      src[src.length - 1] ^= 0xff;
      expect(() => _decode(src, 64), throwsA(isA<ArchiveException>()));
      expect(() => _decode(src, 64, verify: false), returnsNormally);
    });

    test('an empty input is rejected', () {
      expect(() => ZstdChunkedDecoder(_Held()).close(),
          throwsA(isA<ArchiveException>()));
    });

    test('a frame that needs a dictionary says so', () {
      final src = _archive('dv-small-trained-l1.zst');
      expect(() => _decode(src, 64), throwsA(isA<ArchiveException>()));
    });
  });

  group('zstd stream converter', () {
    test('decodes from the file the way a reader gets it', () async {
      final name = 'domains-slice-l19.zst';
      final want = ZstdDecoder()
          .decodeBytes(_archive(name), verify: true, throwOnError: true);
      final got = <int>[];
      await for (final piece in File(p.join(_directory.path, name))
          .openRead()
          .transform(zstdCodec.decoder)) {
        got.addAll(piece);
      }
      expect(got, want);
    });

    test('pieces that arrive one event apart decode the same', () async {
      final src = _archive('domains-slice-l19.zst');
      final want = ZstdDecoder().decodeBytes(src, verify: true);
      final controller = StreamController<List<int>>();
      final done = controller.stream
          .transform(zstdCodec.decoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      for (var at = 0; at < src.length; at += 700) {
        final end = at + 700 < src.length ? at + 700 : src.length;
        await Future<void>.delayed(Duration.zero);
        controller.add(Uint8List.sublistView(src, at, end));
      }
      await controller.close();
      expect(await done, want);
    });

    test('convert takes the whole archive at once', () {
      final src = _archive('text-1k-l19.zst');
      expect(zstdCodec.decode(src), ZstdDecoder().decodeBytes(src));
    });

    test('a Stream encodes and decodes back through the two converters',
        () async {
      final source = Uint8List(300000);
      for (var i = 0; i < source.length; i++) {
        source[i] = (i * 13 + (i >> 9)) & 0xff;
      }
      final pieces = <List<int>>[];
      for (var at = 0; at < source.length; at += 8192) {
        final end = at + 8192 < source.length ? at + 8192 : source.length;
        pieces.add(Uint8List.sublistView(source, at, end));
      }
      final got = <int>[];
      await for (final piece in Stream<List<int>>.fromIterable(pieces)
          .transform(zstdCodec.encoder)
          .transform(zstdCodec.decoder)) {
        got.addAll(piece);
      }
      expect(got, source);
    });

    test('the pieces the input arrives in do not reach the archive', () {
      final source = Uint8List(400000);
      for (var i = 0; i < source.length; i++) {
        source[i] = (i * 29 + (i >> 7)) & 0xff;
      }
      Uint8List encode(int piece, {required int level, required bool checksum}) {
        final held = _Held();
        final encoder =
            ZstdChunkedEncoder(held, level: level, checksum: checksum);
        for (var at = 0; at < source.length; at += piece) {
          final end = at + piece < source.length ? at + piece : source.length;
          encoder.addSlice(source, at, end, false);
        }
        encoder.close();
        return held.bytes;
      }

      for (final level in [1, 3, 6, 9, 12, 17, 22]) {
        for (final checksum in [true, false]) {
          final whole = encode(source.length, level: level, checksum: checksum);
          for (final piece in [1, 17, 4096, 65536, 131072]) {
            expect(encode(piece, level: level, checksum: checksum), whole,
                reason: 'level $level checksum $checksum piece $piece');
          }
          expect(
              ZstdDecoder()
                  .decodeBytes(whole, verify: true, throwOnError: true),
              source,
              reason: 'level $level checksum $checksum');
        }
      }
    });

    test('every level writes a frame that reads back', () {
      final source = Uint8List(200000);
      for (var i = 0; i < source.length; i++) {
        source[i] = (i * 5 + (i >> 6)) & 0xff;
      }
      for (var level = 1; level <= 22; level++) {
        final held = _Held();
        final encoder = ZstdChunkedEncoder(held, level: level);
        for (var at = 0; at < source.length; at += 33333) {
          final end =
              at + 33333 < source.length ? at + 33333 : source.length;
          encoder.addSlice(source, at, end, false);
        }
        encoder.close();
        expect(
            ZstdDecoder()
                .decodeBytes(held.bytes, verify: true, throwOnError: true),
            source,
            reason: 'level $level');
      }
    });

    test('an empty input still writes a frame', () {
      final held = _Held();
      ZstdChunkedEncoder(held).close();
      expect(held.closed, isTrue);
      expect(ZstdDecoder().decodeBytes(held.bytes, verify: true,
          throwOnError: true), isEmpty);
    });

    test('what it writes carries no content size and reads back', () {
      final source = Uint8List(70000);
      for (var i = 0; i < source.length; i++) {
        source[i] = (i * 7) & 0xff;
      }
      for (final level in [1, 3, 9, 19]) {
        for (final piece in [1, 4096, 65536, source.length]) {
          final held = _Held();
          final encoder = ZstdChunkedEncoder(held, level: level);
          for (var at = 0; at < source.length; at += piece) {
            final end =
                at + piece < source.length ? at + piece : source.length;
            encoder.addSlice(source, at, end, false);
          }
          encoder.close();
          final archive = held.bytes;
          // A frame that names no size says so in its descriptor
          expect(archive[4] >> 6, 0, reason: 'level $level piece $piece');
          expect((archive[4] >> 5) & 1, 0, reason: 'level $level piece $piece');
          expect(ZstdDecoder().decodeBytes(archive, verify: true,
              throwOnError: true), source,
              reason: 'level $level piece $piece');
        }
      }
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

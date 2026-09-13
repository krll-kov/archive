import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// What every knob does at its zero, where the reference has an opinion about
// the value and where the value is refused instead

Uint8List _payload(int length) => Uint8List.fromList(
    List.generate(length, (i) => (i * 31 + (i >> 6) * 7) & 0xff));

Uint8List _chunked(List<int> source, ZstdCodec codec, {int piece = 997}) {
  final out = BytesBuilder();
  final sink = codec.encoder.startChunkedConversion(
      ByteConversionSink.withCallback((bytes) => out.add(bytes)));
  for (var at = 0; at < source.length; at += piece) {
    final end = at + piece < source.length ? at + piece : source.length;
    sink.add(source.sublist(at, end));
  }
  sink.close();
  return out.toBytes();
}

void main() {
  group('zstd level at its edges', () {
    final source = _payload(200000);

    test('level zero is the reference default, not the lowest level', () {
      // Data the two levels part on, since most inputs give the same bytes
      final parting = File('test/_data/cat.jpg').readAsBytesSync();
      for (final data in [source, parting]) {
        expect(ZstdEncoder(level: 0).encodeBytes(data),
            ZstdEncoder(level: 3).encodeBytes(data));
      }
      expect(ZstdEncoder(level: 0).encodeBytes(parting),
          isNot(ZstdEncoder(level: 1).encodeBytes(parting)));
    });

    test('a level above the table is clamped to it', () {
      final top = ZstdEncoder(level: 22).encodeBytes(source);
      expect(ZstdEncoder(level: 23).encodeBytes(source), top);
      expect(ZstdEncoder(level: 1000).encodeBytes(source), top);
    });

    test('a negative level is refused rather than read as level one', () {
      expect(() => ZstdEncoder(level: -1).encodeBytes(source),
          throwsA(isA<ArgumentError>()));
      expect(() => ZstdEncoder().encodeBytes(source, level: -3),
          throwsA(isA<ArgumentError>()));
      expect(
          () => ZstdEncoder().encodeStream(
              InputMemoryStream(source), OutputMemoryStream(),
              level: -1),
          throwsA(isA<ArgumentError>()));
      expect(() => _chunked(source, const ZstdCodec(level: -1)),
          throwsA(isA<ArgumentError>()));
    });

    test('every level round trips what it wrote', () {
      for (var level = 0; level <= 22; level++) {
        final frame = ZstdEncoder(level: level).encodeBytes(source);
        expect(ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
            source,
            reason: 'level $level');
      }
    });
  });

  group('zstd with nothing to compress', () {
    test('an empty input writes a frame that reads back empty', () {
      for (var level = 0; level <= 22; level++) {
        final frame = ZstdEncoder(level: level).encodeBytes(Uint8List(0));
        expect(frame, isNotEmpty, reason: 'level $level');
        expect(ZstdDecoder().uncompressedSize(frame), 0, reason: 'level $level');
        expect(
            ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
            isEmpty,
            reason: 'level $level');
      }
    });

    test('an empty stream writes what an empty buffer writes', () {
      final output = OutputMemoryStream();
      ZstdEncoder().encodeStream(InputMemoryStream(Uint8List(0)), output);
      expect(output.getBytes(), ZstdEncoder().encodeBytes(Uint8List(0)));
    });

    test('no chunk and one empty chunk write the same frame', () {
      const codec = ZstdCodec();
      final none = _chunked(<int>[], codec);
      expect(_chunked(<int>[], codec, piece: 1), none);
      expect(ZstdDecoder().decodeBytes(none, verify: true, throwOnError: true),
          isEmpty);
    });

    test('empty chunks between the data change nothing', () {
      final source = _payload(5000);
      const codec = ZstdCodec();
      final out = BytesBuilder();
      final sink = codec.encoder.startChunkedConversion(
          ByteConversionSink.withCallback((bytes) => out.add(bytes)));
      sink.add(const <int>[]);
      for (var at = 0; at < source.length; at += 500) {
        sink.add(const <int>[]);
        sink.add(source.sublist(at, at + 500));
      }
      sink.add(const <int>[]);
      sink.close();
      expect(out.toBytes(), _chunked(source, codec, piece: 500));
    });

    test('an empty dictionary is the same as none', () {
      final source = _payload(4000);
      final empty = ZstdDictionary(Uint8List(0));
      expect(empty.id, 0);
      final frame = ZstdEncoder(dictionary: empty).encodeBytes(source);
      expect(frame, ZstdEncoder().encodeBytes(source));
      expect(
          ZstdDecoder(dictionary: empty)
              .decodeBytes(frame, verify: true, throwOnError: true),
          source);
    });

    test('an empty archive is not a frame', () {
      expect(() => ZstdDecoder().decodeBytes(Uint8List(0), throwOnError: true),
          throwsA(isA<ArchiveException>()));
      expect(
          () => ZstdDecoder().decodeStream(
              InputMemoryStream(Uint8List(0)), OutputMemoryStream(),
              throwOnError: true),
          throwsA(isA<ArchiveException>()));
      expect(ZstdDecoder().decodeBytes(Uint8List(0)), isEmpty);
    });
  });

  group('zstd settings that cannot be honoured', () {
    test('a window limit below the smallest window', () {
      for (final limit in [0, 1, 1023]) {
        expect(() => ZstdDecoder(windowSizeLimit: limit),
            throwsA(isA<ArgumentError>()), reason: 'limit $limit');
      }
      expect(ZstdDecoder(windowSizeLimit: 1024), isA<ZstdDecoder>());
    });

    test('a worker count or a budget of zero', () {
      final source = _payload(1 << 20);
      expect(
          () => ZstdEncoder().encodeBytes(source,
              multithread: ZstdMultithreadOptions<Uint8List>(
                  onDone: (_) {}, workers: 0)),
          throwsA(isA<ArgumentError>()));
      expect(
          () => ZstdEncoder().encodeBytes(source,
              multithread: ZstdMultithreadOptions<Uint8List>(
                  onDone: (_) {}, memoryBudget: 0)),
          throwsA(isA<ArgumentError>()));
      expect(
          () => ZstdEncoder().encodeBytes(source,
              multithread: ZstdMultithreadOptions<Uint8List>(
                  onDone: (_) {}, jobSize: -1)),
          throwsA(isA<ArgumentError>()));
      expect(
          () => ZstdEncoder().encodeBytes(source,
              multithread: ZstdMultithreadOptions<Uint8List>(
                  onDone: (_) {}, overlapLog: -1)),
          throwsA(isA<ArgumentError>()));
    });

    test('a job size and an overlap of zero are the defaults, not a refusal',
        () {
      final source = _payload(1 << 20);
      expect(
          () => ZstdEncoder().encodeBytes(source,
              multithread: ZstdMultithreadOptions<Uint8List>(
                  onDone: (_) {}, jobSize: 0, overlapLog: 0)),
          returnsNormally);
    });
  });
}

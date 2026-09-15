import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The contract every chunked codec inherits, checked through both of the sinks
// that use it. What a codec does with the bytes is its own business; what it
// does with a caller that feeds it badly is the base's, and is the same for all
// of them.

Uint8List _archive(String name) =>
    File(p.join('test/_data/xz', name)).readAsBytesSync();

Uint8List _sample(int size) {
  final data = Uint8List(size);
  for (var i = 0; i < size; i++) {
    data[i] = (i * 11) & 0xff;
  }
  return data;
}

void main() {
  final sinks = <String, ChunkedSink Function(Sink<List<int>>)>{
    'decoder': (sink) => XzChunkedDecoder(sink),
    'encoder': (sink) => XzChunkedEncoder(sink),
  };
  final feed = <String, Uint8List>{
    'decoder': _archive('hello.xz'),
    'encoder': _sample(500),
  };

  sinks.forEach((name, make) {
    group('chunked sink contract, $name', () {
      test('a closed sink refuses more bytes', () {
        final sink = make(_Held())
          ..add(feed[name]!)
          ..close();
        expect(() => sink.add(feed[name]!), throwsStateError);
      });

      test('closing twice is not an error', () {
        final sink = make(_Held())..add(feed[name]!);
        sink.close();
        expect(sink.close, returnsNormally);
      });

      test('the output is closed once, when the input ends', () {
        final held = _Held();
        final sink = make(held);
        sink.add(feed[name]!);
        expect(held.closes, 0);
        sink.close();
        expect(held.closes, 1);
      });

      test('the last slice closes the sink', () {
        final held = _Held();
        final source = feed[name]!;
        final sink = make(held);
        for (var at = 0; at < source.length; at += 7) {
          final end = at + 7 < source.length ? at + 7 : source.length;
          sink.addSlice(source, at, end, end == source.length);
        }
        expect(held.closes, 1);
        expect(() => sink.add(source), throwsStateError);
      });

      test('a slice outside the buffer is refused', () {
        final sink = make(_Held());
        expect(() => sink.addSlice(feed[name]!, 2, 1, false),
            throwsA(isA<RangeError>()));
        expect(
            () => sink.addSlice(feed[name]!, 0, feed[name]!.length + 1, false),
            throwsA(isA<RangeError>()));
      });

      test('a plain list of ints is taken as well as typed data', () {
        final held = _Held();
        final sink = make(held);
        // ignore: prefer_typed_lists
        sink.add(<int>[...feed[name]!]);
        sink.close();
        expect(held.length, greaterThan(0));
      });

      test('empty pieces change nothing', () {
        final held = _Held();
        final sink = make(held)
          ..add(const <int>[])
          ..add(feed[name]!)
          ..add(Uint8List(0));
        sink.close();
        expect(held.length, greaterThan(0));
      });

      test('the caller may reuse the buffer it handed over', () {
        final held = _Held();
        final source = feed[name]!;
        final buffer = Uint8List(source.length);
        final sink = make(held);
        for (var at = 0; at < source.length; at += 5) {
          final end = at + 5 < source.length ? at + 5 : source.length;
          buffer.setRange(0, end - at, source, at);
          sink.addSlice(buffer, 0, end - at, false);
          // What the sink kept must not be a view of this
          buffer.fillRange(0, buffer.length, 0xcd);
        }
        sink.close();
        expect(held.length, greaterThan(0));
      });
    });
  });

  group('chunked sink failures', () {
    test('the first failure is the one every later call reports', () {
      final held = _Held();
      final sink = XzChunkedDecoder(held);
      expect(() => sink.add(Uint8List(64)), throwsA(isA<ArchiveException>()));
      expect(() => sink.add(_archive('hello.xz')),
          throwsA(isA<ArchiveException>()));
      expect(sink.close, throwsA(isA<ArchiveException>()));
      // A failed conversion hands nothing over and closes nothing
      expect(held.length, 0);
      expect(held.closes, 0);
    });

    // A stream hears a failure once, as it does from gzip and zlib in dart:io.
    // A decoder that fails drops the input after it and never closes, as gzip
    // does. Every other transformer closes on its first failure
    test('every transformer reports a failure to a stream once', () async {
      Stream<T> failing<T>(List<T> items) async* {
        yield* Stream.fromIterable(items);
        yield* Stream<T>.error(StateError('source failed'));
        yield* Stream.fromIterable(items);
      }

      Stream<T> watched<T>(Stream<T> source, Completer<void> fed) =>
          source.transform(
              StreamTransformer<T, T>.fromHandlers(handleDone: (sink) {
            fed.complete();
            sink.close();
          }));

      List<List<int>> pieces(List<int> bytes) => [
            for (var at = 0; at < bytes.length; at += 16)
              bytes.sublist(
                  at, at + 16 < bytes.length ? at + 16 : bytes.length),
          ];

      Stream<List<int>> broken(Codec<List<int>, List<int>> codec) {
        final archive = Uint8List.fromList(codec.encode(_sample(100000)));
        archive[0] ^= 0xff;
        return Stream.fromIterable(pieces(archive));
      }

      final files = [
        for (var i = 0; i < 4; i++) ArchiveFile.bytes('f$i.bin', _sample(3000)),
      ];
      final tar = TarEncoder().encodeBytes(Archive()..addFile(files[0]));
      tar[148] ^= 1;
      final data = pieces(_sample(3000));
      final cases = <String, Stream<Object?> Function(Completer<void>)>{
        'xzCodec.decoder': (fed) =>
            watched(broken(xzCodec), fed).transform(xzCodec.decoder),
        'zstdCodec.decoder': (fed) =>
            watched(broken(zstdCodec), fed).transform(zstdCodec.decoder),
        'bzip2Codec.decoder': (fed) =>
            watched(broken(bzip2Codec), fed).transform(bzip2Codec.decoder),
        'xzCodec.encoder': (fed) =>
            watched(failing(data), fed).transform(xzCodec.encoder),
        'zstdCodec.encoder': (fed) =>
            watched(failing(data), fed).transform(zstdCodec.encoder),
        'bzip2Codec.encoder': (fed) =>
            watched(failing(data), fed).transform(bzip2Codec.encoder),
        'tarCodec.decoder': (fed) =>
            watched(Stream.fromIterable(pieces(tar)), fed)
                .transform(tarCodec.decoder),
        'tarCodec.encoder': (fed) =>
            watched(failing(files), fed).transform(tarCodec.encoder),
        'zipCodec.encoder': (fed) =>
            watched(failing(files), fed).transform(zipCodec.encoder),
        'threaded xz decoder': (fed) => watched(broken(xzCodec), fed).transform(
            const XzCodec(
                    multithread: XZMultithreadOptions.converter(workers: 2))
                .decoder),
        'threaded zstd encoder': (fed) => watched(failing(data), fed).transform(
            const ZstdCodec(
                    multithread: ZstdMultithreadOptions.converter(workers: 2))
                .encoder),
      };
      for (final entry in cases.entries) {
        final errors = <Object>[];
        final fed = Completer<void>();
        final ended = Completer<void>();
        entry
            .value(fed)
            .listen((_) {}, onError: errors.add, onDone: ended.complete);
        await Future.any(
                [ended.future, fed.future.then((_) => pumpEventQueue())])
            .timeout(const Duration(seconds: 10));
        expect(errors, hasLength(1), reason: entry.key);
      }
    });

    test('what a codec throws at bad data becomes one kind of failure', () {
      final src = Uint8List.fromList(_archive('x86.xz'));
      src[src.length ~/ 2] ^= 0xff;
      expect(
          () => XzChunkedDecoder(_Held())
            ..add(src)
            ..close(),
          throwsA(isA<ArchiveException>()));
    });
  });

  group('chunked converter', () {
    test('convert gives what the chunked path gives', () {
      final source = _archive('cat.jpg.xz');
      final held = _Held();
      XzChunkedDecoder(held)
        ..add(source)
        ..close();
      expect(xzCodec.decode(source), held.bytes);
    });

    test('a Sink that is not a ByteConversionSink is taken as well', () {
      final plain = _Held();
      final sink = xzCodec.decoder.startChunkedConversion(plain);
      expect(sink, isA<ByteConversionSink>());
      sink
        ..add(_archive('hello.xz'))
        ..close();
      expect(plain.length, 6);
    });
  });

  group('sink output stream', () {
    test('what it hands over is a copy, not a view', () {
      final held = _Held();
      final out = SinkOutputStream(held);
      final buffer = Uint8List.fromList([1, 2, 3, 4]);
      out.writeRange(buffer, 0, 4);
      out.flush();
      buffer.fillRange(0, 4, 9);
      expect(held.bytes, [1, 2, 3, 4]);
      expect(out.written, 4);
    });

    test('a diverted stretch does not reach the sink', () {
      final held = _Held();
      final out = SinkOutputStream(held);
      final buffer = OutputMemoryStream();
      out
        ..divert = buffer
        ..writeBytes([1, 2, 3])
        ..divert = null
        ..writeBytes([4, 5])
        ..flush();
      expect(buffer.getBytes(), [1, 2, 3]);
      expect(held.bytes, [4, 5]);
      expect(out.written, 5);
    });

    test('what goes past can be folded in on the way', () {
      final held = _Held();
      final seen = <int>[];
      SinkOutputStream(held)
        ..watch = ((piece) => seen.addAll(piece))
        ..writeBytes([7, 8])
        ..writeByte(9)
        ..flush();
      expect(seen, [7, 8, 9]);
      expect(held.bytes, [7, 8, 9]);
    });

    test('reset only clears the count', () {
      final held = _Held();
      final out = SinkOutputStream(held)
        ..writeBytes([1, 2, 3])
        ..flush();
      expect(out.written, 3);
      out.reset();
      expect(out.written, 0);
      expect(held.bytes, [1, 2, 3]);
    });

    test('clear drops what is queued rather than deferring it', () {
      final held = _Held();
      final out = SinkOutputStream(held)..writeBytes([1, 2, 3]);
      out.clear();
      expect(out.length, 0);
      out.flush();
      expect(held.bytes, isEmpty,
          reason: 'cleared bytes must not reach the sink later');
    });
  });

  // Measured on this SDK: gzip.decoder and zlib.decoder throw a
  // FormatException out of add on a corrupt stream and leave the sink they
  // were given open, and a close afterwards does not close it either
  group('a failed parse leaves the output open, as dart:io does', () {
    final source = Uint8List.fromList(List.filled(4096, 65));
    final truncated = <String, Uint8List>{
      'xz': _cut(xzCodec.encoder.convert(source), 20),
      'bzip2': _cut(bzip2Codec.encoder.convert(source), 5),
      'zstd': _cut(zstdCodec.encoder.convert(source), 5),
    };
    final starts = <String, ByteConversionSink Function(Sink<List<int>>)>{
      'xz': xzCodec.decoder.startChunkedConversion,
      'bzip2': bzip2Codec.decoder.startChunkedConversion,
      'zstd': zstdCodec.decoder.startChunkedConversion,
    };

    for (final name in truncated.keys) {
      test(name, () {
        final held = _Watched();
        final sink = starts[name]!(held);
        expect(() {
          sink.add(truncated[name]!);
          sink.close();
        }, throwsA(isA<ArchiveException>()));
        expect(held.closed, isFalse);
        // The failure is remembered, so nothing closes it later on either
        expect(sink.close, returnsNormally);
        expect(held.closed, isFalse);
      });
    }
  });
}

Uint8List _cut(List<int> bytes, int off) =>
    Uint8List.fromList(bytes.sublist(0, bytes.length - off));

class _Watched implements Sink<List<int>> {
  var closed = false;

  @override
  void add(List<int> data) {}

  @override
  void close() => closed = true;
}

class _Held implements Sink<List<int>> {
  final _pieces = <List<int>>[];
  var length = 0;
  var closes = 0;

  @override
  void add(List<int> data) {
    _pieces.add(data);
    length += data.length;
  }

  @override
  void close() {
    closes++;
  }

  Uint8List get bytes {
    final out = Uint8List(length);
    var at = 0;
    for (final piece in _pieces) {
      out.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return out;
  }
}

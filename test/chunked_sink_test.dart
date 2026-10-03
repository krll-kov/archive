import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/util/decode_guard.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The contract every chunked codec inherits, checked through both of the sinks
// that use it. What a codec does with the bytes is its own business; what it
// does with a caller that feeds it badly is the base's, and is the same for all
// of them.

Uint8List _archive(String name) =>
    File(p.join('test/_data/xz', name)).readAsBytesSync();

Future<void> _expectLazySubscription<S, T>(
    StreamTransformer<S, T> transformer) async {
  var listens = 0;
  var cancelled = false;
  final started = Completer<void>();
  final source = StreamController<S>(
    onListen: () {
      listens++;
      started.complete();
    },
    onCancel: () => cancelled = true,
  );
  final transformed = source.stream.transform(transformer);
  StreamSubscription<T>? subscription;
  addTearDown(() async {
    subscription ??= transformed.listen((_) {});
    await subscription!.cancel().timeout(const Duration(seconds: 5));
    expect(cancelled, isTrue);
    await source.close();
  });
  await Future<void>.delayed(Duration.zero);
  expect(listens, 0);
  subscription = transformed.listen((_) {});
  await started.future.timeout(const Duration(seconds: 5));
  expect(listens, 1);
}

Uint8List _sample(int size) {
  final data = Uint8List(size);
  for (var i = 0; i < size; i++) {
    data[i] = (i * 11) & 0xff;
  }
  return data;
}

void main() {
  group('transformers subscribe when listened to', () {
    test('tar decoder', () => _expectLazySubscription(tarCodec.decoder));
    test('tar encoder', () => _expectLazySubscription(tarCodec.encoder));
    test('zip encoder', () => _expectLazySubscription(zipCodec.encoder));
    test(
        'threaded xz decoder',
        () => _expectLazySubscription(const XzCodec(
                multithread: XZMultithreadOptions.converter(workers: 2))
            .decoder));
    test(
        'threaded zstd encoder',
        () => _expectLazySubscription(const ZstdCodec(
                multithread: ZstdMultithreadOptions.converter(workers: 2))
            .encoder));
  });

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
    // does. The xz, zstd and bzip2 encoders stay open after a source error, as
    // gzip.encoder does. tar, zip and the threaded codecs close on their first
    // failure
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

    test('a source error and then a cut archive give two errors, as utf8 does',
        () async {
      Stream<List<int>> halfThenError(List<int> input) async* {
        yield input.sublist(0, input.length ~/ 2);
        throw StateError('source failed');
      }

      final decoders = <String, (Converter<List<int>, Object>, List<int>)>{
        'utf8.decoder': (utf8.decoder, [0x61, 0xe2, 0x82, 0xac]),
        'xzCodec.decoder': (xzCodec.decoder, xzCodec.encode(_sample(100000))),
        'zstdCodec.decoder': (
          zstdCodec.decoder,
          zstdCodec.encode(_sample(100000))
        ),
        'bzip2Codec.decoder': (
          bzip2Codec.decoder,
          bzip2Codec.encode(_sample(100000))
        ),
      };
      for (final MapEntry(key: name, value: (decoder, input))
          in decoders.entries) {
        final errors = <Object>[];
        final subscription = halfThenError(input)
            .transform(decoder)
            .listen((_) {}, onError: errors.add);
        await pumpEventQueue();
        await subscription.cancel();
        expect(errors, hasLength(2), reason: name);
        expect(errors.first, isA<StateError>(), reason: name);
        expect(errors.last, isA<FormatException>(), reason: name);
      }
    });

    // We behave like gzip.decoder in dart:io. After a failure a decoder drops
    // the rest of the input and never closes the stream. The listener ends it.
    // await for, pipe and toList cancel at the first error on their own. A
    // listen that waits for onDone has to cancel in onError. gzip.decoder is
    // checked here too, so a change on the dart:io side shows up as well
    test('a failed decoder stream stays open, as gzip.decoder does', () async {
      Future<void> expectOpen(String reason,
          Converter<List<int>, List<int>> decoder, List<int> bytes) async {
        final errors = <Object>[];
        var closed = false;
        final failed = Completer<void>();
        final subscription = Stream<List<int>>.fromIterable([bytes])
            .transform(decoder)
            .listen((_) {},
                onError: (Object error) {
                  errors.add(error);
                  if (!failed.isCompleted) {
                    failed.complete();
                  }
                },
                onDone: () => closed = true);
        await failed.future.timeout(const Duration(seconds: 10));
        // The source has closed by now, so a stream that ends would have
        await pumpEventQueue();
        await subscription.cancel();
        expect(errors, hasLength(1), reason: reason);
        expect(errors.single, isA<FormatException>(), reason: reason);
        expect(closed, isFalse, reason: reason);
      }

      final gz = Uint8List.fromList(gzip.encode(_sample(100000)))..[0] ^= 0xff;
      await expectOpen('gzip.decoder, broken header', gzip.decoder, gz);

      final codecs = <String, Codec<List<int>, List<int>>>{
        'xz': xzCodec,
        'zstd': zstdCodec,
        'bzip2': bzip2Codec,
      };
      for (final codec in codecs.entries) {
        final archive = Uint8List.fromList(codec.value.encode(_sample(100000)));
        // A broken header fails in add. A cut archive fails in close
        final broken = Uint8List.fromList(archive)..[0] ^= 0xff;
        final cut = archive.sublist(0, archive.length - 5);
        await expectOpen(
            '${codec.key}, broken header', codec.value.decoder, broken);
        await expectOpen('${codec.key}, cut', codec.value.decoder, cut);
      }
    });

    // Encoders follow gzip.encoder in dart:io. An error from the source reaches
    // the stream once, and the stream stays open
    test('a failed encoder stream stays open, as gzip.encoder does', () async {
      final data = [for (var i = 0; i < 4; i++) _sample(3000)];
      void failSource(StreamController<List<int>> source) {
        data.forEach(source.add);
        source.addError(StateError('source failed'));
      }

      final encoders = <String, Converter<List<int>, List<int>>>{
        'gzip.encoder': gzip.encoder,
        'xzCodec.encoder': xzCodec.encoder,
        'zstdCodec.encoder': zstdCodec.encoder,
        'bzip2Codec.encoder': bzip2Codec.encoder,
      };
      for (final encoder in encoders.entries) {
        await _expectEndAfterFailure<List<int>>(encoder.key,
            (source) => source.transform(encoder.value), failSource,
            closes: false);
      }
    });

    // tar, zip and the threaded codecs have no dart:io counterpart. They end the
    // stream on their first failure
    test('tar, zip and threaded transformers close on their first failure',
        () async {
      void feedBytes(StreamController<List<int>> source, List<int> bytes) {
        for (var at = 0; at < bytes.length; at += 16) {
          source.add(bytes.sublist(
              at, at + 16 < bytes.length ? at + 16 : bytes.length));
        }
      }

      final files = [
        for (var i = 0; i < 4; i++) ArchiveFile.bytes('f$i.bin', _sample(3000)),
      ];
      void failFiles(StreamController<ArchiveFile> source) {
        files.forEach(source.add);
        source.addError(StateError('source failed'));
      }

      final data = [for (var i = 0; i < 4; i++) _sample(3000)];
      void failData(StreamController<List<int>> source) {
        data.forEach(source.add);
        source.addError(StateError('source failed'));
      }

      final tar = TarEncoder().encodeBytes(Archive()..addFile(files[0]));
      tar[148] ^= 1;
      final xz = Uint8List.fromList(xzCodec.encode(_sample(100000)))
        ..[0] ^= 0xff;

      await _expectEndAfterFailure<List<int>>(
          'tarCodec.decoder',
          (source) => source.transform(tarCodec.decoder),
          (source) => feedBytes(source, tar),
          closes: true);
      await _expectEndAfterFailure<ArchiveFile>('tarCodec.encoder',
          (source) => source.transform(tarCodec.encoder), failFiles,
          closes: true);
      await _expectEndAfterFailure<ArchiveFile>('zipCodec.encoder',
          (source) => source.transform(zipCodec.encoder), failFiles,
          closes: true);
      await _expectEndAfterFailure<List<int>>(
          'threaded xz decoder',
          (source) => source.transform(const XzCodec(
                  multithread: XZMultithreadOptions.converter(workers: 2))
              .decoder),
          (source) => feedBytes(source, xz),
          closes: true);
      await _expectEndAfterFailure<List<int>>(
          'threaded zstd encoder',
          (source) => source.transform(const ZstdCodec(
                  multithread: ZstdMultithreadOptions.converter(workers: 2))
              .encoder),
          failData,
          closes: true);
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

  group('failures that are not bad data', () {
    test('what the output throws keeps its type', () {
      final data = _sample(300000);
      const failure = FileSystemException('No space left on device');
      final cases = <(ChunkedSink Function(Sink<List<int>>), List<int>)>[
        ((sink) => XzChunkedDecoder(sink), XZEncoder().encodeBytes(data)),
        ((sink) => ZstdChunkedDecoder(sink), ZstdEncoder().encodeBytes(data)),
        ((sink) => BZip2ChunkedDecoder(sink), BZip2Encoder().encodeBytes(data)),
        ((sink) => XzChunkedEncoder(sink), data),
        ((sink) => ZstdChunkedEncoder(sink), data),
        ((sink) => BZip2ChunkedEncoder(sink), data),
      ];
      for (final (make, input) in cases) {
        expect(
            () => make(_FailingSink(failure))
              ..add(input)
              ..close(),
            throwsA(same(failure)));
      }
    });

    test('an error from the source reaches the caller as it is', () async {
      final failure = RangeError('from the source');
      final bytes = <StreamTransformer<List<int>, List<int>>>[
        xzCodec.decoder,
        const XzCodec(multithread: XZMultithreadOptions.converter(workers: 2))
            .decoder,
        xzCodec.encoder,
        zstdCodec.decoder,
        zstdCodec.encoder,
        const ZstdCodec(
                multithread: ZstdMultithreadOptions.converter(workers: 2))
            .encoder,
        bzip2Codec.decoder,
        bzip2Codec.encoder,
      ];
      for (final transformer in bytes) {
        await expectLater(
            Stream<List<int>>.error(failure).transform(transformer).toList(),
            throwsA(same(failure)));
      }
      await expectLater(
          Stream<List<int>>.error(failure).transform(tarCodec.decoder).toList(),
          throwsA(same(failure)));
      for (final encoder in [tarCodec.encoder, zipCodec.encoder]) {
        await expectLater(
            Stream<ArchiveFile>.error(failure).transform(encoder).toList(),
            throwsA(same(failure)));
      }
    });

    test('an error from inside a stream converter is ArchiveException',
        () async {
      Stream<int> broken(Stream<int> source) async* {
        await for (final value in source) {
          yield value;
        }
        throw RangeError('inside');
      }

      await expectLater(archiveStreamErrors(Stream.value(1), broken).toList(),
          throwsA(isA<ArchiveException>()));
      const failure = FileSystemException('inside');
      Stream<int> foreign(Stream<int> source) async* {
        await for (final value in source) {
          yield value;
        }
        throw failure;
      }

      await expectLater(archiveStreamErrors(Stream.value(1), foreign).toList(),
          throwsA(same(failure)));
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
    for (final kind in ['memory', 'file']) {
      for (final failureAt in ['sink', 'watch']) {
        test('writeStream restores a $kind subset after a $failureAt failure',
            () {
          final data = _sample(131120);
          late InputStream input;
          if (kind == 'memory') {
            final outer = InputMemoryStream(data, offset: 11, length: 131100);
            input = InputMemoryStream(outer.toUint8List(),
                offset: 7, length: 131073);
          } else {
            final dir = Directory.systemTemp.createTempSync('archive_sink_');
            addTearDown(() => dir.deleteSync(recursive: true));
            final file = File(p.join(dir.path, 'input'))
              ..writeAsBytesSync(data);
            final source = InputFileStream(file.path, bufferSize: 17);
            addTearDown(source.closeSync);
            final outer = InputFileStream.fromFileStream(source,
                position: 11, length: 131100);
            input = InputFileStream.fromFileStream(outer,
                position: 7, length: 131073);
          }
          input.position = 17;
          final failure = StateError('output failed');
          final output = SinkOutputStream(
              failureAt == 'sink' ? _FailingSink(failure) : _Held());
          if (failureAt == 'watch') {
            output.watch = (_) => throw failure;
          }

          expect(() => output.writeStream(input), throwsA(same(failure)));
          expect(input.position, 17);
          expect(input.readByte(), data[35]);
        });
      }
    }

    test('writeStream restores the position after reading fails', () {
      final failure = StateError('input failed');
      final input = _FailingInput(_sample(131073), failure)..position = 17;
      final output = SinkOutputStream(_Held());

      expect(() => output.writeStream(input), throwsA(same(failure)));
      expect(input.position, 17);
    });

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

    // Measured on this SDK: closing the sink of
    // `zlib.encoder.startChunkedConversion` sends the last bytes and closes
    // that sink, and `OutputFileStream` flushes before it closes its file
    test('close hands over what is queued and closes the sink', () async {
      final held = _Held();
      final out = SinkOutputStream(held)..writeBytes([1, 2, 3]);
      await out.close();
      expect(held.bytes, [1, 2, 3]);
      expect(held.closes, 1);
    });

    test('closeSync hands over what is queued and closes the sink', () {
      final held = _Held();
      final out = SinkOutputStream(held)..writeBytes([1, 2, 3]);
      out.closeSync();
      expect(held.bytes, [1, 2, 3]);
      expect(held.closes, 1);
    });

    test('a close after a close does nothing, as dart:io does', () {
      final held = _Held();
      final out = SinkOutputStream(held)..writeBytes([1, 2, 3]);
      out
        ..closeSync()
        ..closeSync();
      expect(held.bytes, [1, 2, 3]);
      expect(held.closes, 1);
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

/// Feeds a source that never closes, so only the transformer can end the
/// stream. We expect one error, then a stream that ended or stayed open
Future<void> _expectEndAfterFailure<T>(
    String reason,
    Stream<Object?> Function(Stream<T> source) transform,
    void Function(StreamController<T> source) feed,
    {required bool closes}) async {
  final source = StreamController<T>();
  final errors = <Object>[];
  final failed = Completer<void>();
  final ended = Completer<void>();
  final subscription =
      transform(source.stream).listen((_) {}, onError: (Object error) {
    errors.add(error);
    if (!failed.isCompleted) {
      failed.complete();
    }
  }, onDone: ended.complete);
  feed(source);
  await failed.future.timeout(const Duration(seconds: 10));
  if (closes) {
    await ended.future.timeout(const Duration(seconds: 10));
  } else {
    // A stream that ends would have ended by now
    await pumpEventQueue();
    expect(ended.isCompleted, isFalse, reason: reason);
  }
  await subscription.cancel();
  expect(errors, hasLength(1), reason: reason);
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

class _FailingSink implements Sink<List<int>> {
  final Object failure;

  _FailingSink(this.failure);

  @override
  void add(List<int> data) => throw failure;

  @override
  void close() {}
}

class _FailingInput extends InputMemoryStream {
  final Object failure;

  _FailingInput(super.bytes, this.failure);

  @override
  int readInto(Uint8List into, int at, int count) {
    super.readInto(into, at, count);
    throw failure;
  }
}

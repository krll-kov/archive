import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/util/chunked_sink.dart';
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
        expect(() => sink.addSlice(feed[name]!, 0, feed[name]!.length + 1, false),
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

    test('what a codec throws at bad data becomes one kind of failure', () {
      final src = Uint8List.fromList(_archive('x86.xz'));
      src[src.length ~/ 2] ^= 0xff;
      expect(() => XzChunkedDecoder(_Held())..add(src)..close(),
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
        ..writeBytes([4, 5]);
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
        ..writeByte(9);
      expect(seen, [7, 8, 9]);
      expect(held.bytes, [7, 8, 9]);
    });

    test('reset only clears the count', () {
      final held = _Held();
      final out = SinkOutputStream(held)..writeBytes([1, 2, 3]);
      expect(out.written, 3);
      out.reset();
      expect(out.written, 0);
      expect(held.bytes, [1, 2, 3]);
    });
  });
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

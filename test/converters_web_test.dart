import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

Uint8List _sample(int length, int seed) {
  final bytes = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = (state >> 16) % 5 == 0 ? 0x41 : (state >> 8) & 0xff;
  }
  return bytes;
}

Stream<List<int>> _pieces(List<int> bytes, int size) async* {
  for (var at = 0; at < bytes.length; at += size) {
    yield bytes.sublist(
        at, at + size < bytes.length ? at + size : bytes.length);
  }
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final out = BytesBuilder();
  await for (final piece in stream) {
    out.add(piece);
  }
  return out.takeBytes();
}

class _Collect implements Sink<List<int>> {
  final bytes = BytesBuilder();
  var closed = false;

  @override
  void add(List<int> data) => bytes.add(data);

  @override
  void close() => closed = true;
}

List<ArchiveFile> _entries() => [
      ArchiveFile.string('readme.txt', 'the first entry'),
      ArchiveFile.bytes('dir/binary.dat', _sample(70000, 3)),
      ArchiveFile.bytes('${'long/' * 30}name.dat', _sample(700, 5)),
      ArchiveFile.bytes('empty.dat', Uint8List(0)),
    ]..forEach((entry) => entry.lastModTime = 1700000000);

void main() {
  final data = _sample(300000, 7);

  group('zstd converters on the web', () {
    test('codec round trips whole', () {
      expect(zstdCodec.decode(zstdCodec.encode(data)), data);
    });

    for (final size in [1, 4096, 65536]) {
      test('stream round trips in pieces of $size', () async {
        final input = size == 1 ? data.sublist(0, 20000) : data;
        final compressed =
            await _collect(_pieces(input, size).transform(zstdCodec.encoder));
        expect(ZstdDecoder().decodeBytes(compressed), input);
        final back = await _collect(
            _pieces(compressed, size).transform(zstdCodec.decoder));
        expect(back, input);
      });
    }

    test('decoder reads what the whole buffer encoder writes', () async {
      final compressed = ZstdEncoder().encodeBytes(data);
      expect(
          await _collect(
              _pieces(compressed, 1000).transform(zstdCodec.decoder)),
          data);
    });
  });

  group('bzip2 converters on the web', () {
    test('codec round trips whole', () {
      expect(bzip2Codec.decode(bzip2Codec.encode(data)), data);
    });

    for (final size in [1, 4096, 65536]) {
      test('stream round trips in pieces of $size', () async {
        final input = size == 1 ? data.sublist(0, 20000) : data;
        final compressed =
            await _collect(_pieces(input, size).transform(bzip2Codec.encoder));
        expect(BZip2Decoder().decodeBytes(compressed, verify: true), input);
        final back = await _collect(
            _pieces(compressed, size).transform(bzip2Codec.decoder));
        expect(back, input);
      });
    }

    test('decoder reads what the whole buffer encoder writes', () async {
      final compressed = BZip2Encoder().encodeBytes(data, blockSize100k: 1);
      expect(
          await _collect(
              _pieces(compressed, 1000).transform(bzip2Codec.decoder)),
          data);
    });
  });

  group('tar converters on the web', () {
    test('TarChunkedEncoder writes what TarDecoder reads', () {
      final sink = _Collect();
      final encoder = TarChunkedEncoder(sink);
      for (final entry in _entries()) {
        encoder.add(entry);
      }
      encoder.close();
      expect(sink.closed, isTrue);
      final archive = TarDecoder().decodeBytes(sink.bytes.takeBytes());
      final want = _entries();
      expect(archive.files.map((f) => f.name), want.map((e) => e.name));
      for (var i = 0; i < want.length; i++) {
        expect(archive.files[i].content, want[i].content);
      }
    });

    test('tarCodec round trips through streams', () async {
      final bytes = await _collect(
          Stream<ArchiveFile>.fromIterable(_entries())
              .transform(tarCodec.encoder));
      final got = <String, List<int>>{};
      await for (final entry
          in _pieces(bytes, 777).transform(tarCodec.decoder)) {
        final content = <int>[];
        await for (final part in entry.content) {
          content.addAll(part);
        }
        got[entry.name] = content;
      }
      final want = _entries();
      expect(got.keys, want.map((e) => e.name));
      for (final entry in want) {
        expect(got[entry.name], entry.content);
      }
    });
  });

  group('zip converters on the web', () {
    for (final streamed in [true, false]) {
      test('ZipChunkedEncoder streamed: $streamed writes what ZipDecoder reads',
          () {
        final sink = _Collect();
        final encoder = ZipChunkedEncoder(sink, streamed: streamed);
        for (final entry in _entries()) {
          encoder.add(entry);
        }
        encoder.close();
        expect(sink.closed, isTrue);
        final archive =
            ZipDecoder().decodeBytes(sink.bytes.takeBytes(), verify: true);
        final want = _entries();
        expect(archive.files.map((f) => f.name), want.map((e) => e.name));
        for (var i = 0; i < want.length; i++) {
          expect(archive.files[i].content, want[i].content);
        }
      });
    }

    test('zipCodec encoder writes what ZipDecoder reads', () async {
      final bytes = await _collect(
          Stream<ArchiveFile>.fromIterable(_entries())
              .transform(zipCodec.encoder));
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      final want = _entries();
      expect(archive.files.map((f) => f.name), want.map((e) => e.name));
      for (var i = 0; i < want.length; i++) {
        expect(archive.files[i].content, want[i].content);
      }
    });
  });

  group('CodecsRecognizer on the web', () {
    final small = _sample(5000, 11);
    final archive = Archive()..add(ArchiveFile.bytes('a.dat', small));
    final formats = <ArchiveFormat, Uint8List>{
      ArchiveFormat.gzip: GZipEncoder().encodeBytes(small),
      ArchiveFormat.bzip2: BZip2Encoder().encodeBytes(small),
      ArchiveFormat.xz: XZEncoder().encodeBytes(small),
      ArchiveFormat.zstd: ZstdEncoder().encodeBytes(small),
      ArchiveFormat.zip: ZipEncoder().encodeBytes(archive),
      ArchiveFormat.tar: TarEncoder().encodeBytes(archive),
    };

    for (final entry in formats.entries) {
      test('recognizes ${entry.key.name}', () {
        expect(CodecsRecognizer.recognize(entry.value), entry.key);
      });
    }

    test('recognizes zlib only when asked', () {
      final zlib = ZLibEncoder().encodeBytes(small);
      expect(CodecsRecognizer.isZLib(zlib), isTrue);
      expect(CodecsRecognizer.recognize(zlib, withZLib: true),
          ArchiveFormat.zlib);
    });

    test('plain text is unknown', () {
      expect(CodecsRecognizer.recognize(utf8.encode('just some text')),
          ArchiveFormat.unknown);
    });
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

// zip is written forward: a local header, its data, and the central directory
// at the end, nothing read back. So the bytes have to be the ones the
// whole-archive encoder writes, and the archive has to come back off disk
// entry by entry..

Uint8List _source(int length, int seed) {
  final bytes = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = (state >> 16) % 5 == 0 ? 0x41 : (state >> 8) & 0xff;
  }
  return bytes;
}

List<ArchiveFile> _entries() => [
      ArchiveFile.string('readme.txt', 'the first entry'),
      ArchiveFile.bytes('dir/binary.dat', _source(70000, 3)),
      ArchiveFile.bytes('small.dat', _source(7, 5)),
    ];

Archive _archiveOf(List<ArchiveFile> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.add(entry);
  }
  return archive;
}

Uint8List _zip(List<ArchiveFile> entries,
    {int level = DeflateLevel.bestSpeed, bool streamed = true}) {
  final held = _Held();
  final encoder = ZipChunkedEncoder(held, level: level, streamed: streamed);
  for (final entry in entries) {
    encoder.add(entry);
  }
  encoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

void main() {
  group('zip chunked encoder', () {
    test('with the sizes in front it writes what one archive writes', () {
      final held = OutputMemoryStream();
      ZipEncoder().encodeStream(_archiveOf(_entries()), held);
      expect(_zip(_entries(), streamed: false), held.getBytes());
    });

    test('what it writes reads back', () {
      // The encoder reads an entry's content, so what it should be has to be
      // held before it goes in
      final want = _source(70000, 3);
      final back = ZipDecoder().decodeBytes(_zip(_entries()), verify: true);
      expect(back.files.map((f) => f.name), _entries().map((e) => e.name));
      expect(back.files[1].content, want);
    });

    test('an empty archive is still an archive', () {
      final held = _Held();
      ZipChunkedEncoder(held).close();
      expect(ZipDecoder().decodeBytes(held.bytes).files, isEmpty);
    });

    test('adding after close is refused', () {
      final encoder = ZipChunkedEncoder(_Held())..close();
      expect(() => encoder.add(ArchiveFile.string('a', 'b')),
          throwsA(isA<StateError>()));
    });

    test('the bytes go out as the entries are added', () {
      final held = _Held();
      final encoder = ZipChunkedEncoder(held);
      expect(held.pieces, 0);
      encoder.add(ArchiveFile.bytes('a.bin', _source(60000, 7)));
      final afterFirst = held.bytes.length;
      expect(afterFirst, greaterThan(0));
      encoder.add(ArchiveFile.bytes('b.bin', _source(60000, 11)));
      expect(held.bytes.length, greaterThan(afterFirst));
      encoder.close();
    });
  });

  group('zip with the sizes behind the data, which is the default', () {
    for (final useAddLevel in [false, true]) {
      test('the ${useAddLevel ? 'add' : 'entry'} level override is respected',
          () {
        Uint8List payload(bool streamed) {
          final file = ArchiveFile.bytes('a', Uint8List(128 * 1024))
            ..compressionLevel = useAddLevel ? null : 0;
          final output = OutputMemoryStream();
          final encoder = ZipEncoder(streamed: streamed)
            ..startEncode(output, level: 1);
          encoder.add(file, level: useAddLevel ? 0 : null);
          encoder.endEncode();
          final archive = ZipDecoder().decodeBytes(output.getBytes());
          return (archive.files.single.rawContent! as ZipFile)
              .getStream(decompress: false)
              .toUint8List();
        }

        final expected = payload(false);
        final actual = payload(true);
        expect(actual.length, expected.length);
        expect(actual, expected);
      });
    }

    // Deflate grows data that does not compress. 4293656835 bytes is the
    // largest entry whose worst case still fits 32 bits. One byte more is
    // written the way Info-ZIP writes a zip64 entry to a pipe
    test('an entry deflate may grow past 4 GB is written with zip64', () {
      ByteData written(int size) {
        final output = OutputMemoryStream();
        ZipEncoder(streamed: true)
          ..startEncode(output)
          ..addHeader(ArchiveFile.file('a', size, FileContentMemory([1, 2, 3])))
              ?.finish();
        return ByteData.sublistView(output.getBytes());
      }

      final plain = written(4293656835);
      expect(plain.getUint16(4, Endian.little), 20);
      expect(plain.getUint32(18, Endian.little), 0);
      expect(plain.getUint16(28, Endian.little), 0);
      final plainEnd = plain.lengthInBytes;
      expect(plain.getUint32(plainEnd - 16, Endian.little), 0x08074b50);
      expect(plain.getUint32(plainEnd - 4, Endian.little), 4293656835);

      final wide = written(4293656836);
      expect(wide.getUint16(4, Endian.little), 45);
      expect(wide.getUint32(18, Endian.little), 0xFFFFFFFF);
      expect(wide.getUint32(22, Endian.little), 0xFFFFFFFF);
      expect(wide.getUint16(28, Endian.little), 20);
      expect(wide.getUint16(31, Endian.little), 1);
      final wideEnd = wide.lengthInBytes;
      expect(wide.getUint32(wideEnd - 24, Endian.little), 0x08074b50);
      expect(wide.getUint64(wideEnd - 8, Endian.little), 4293656836);
    });

    // An entry over 4 GB is streamed too, not held in memory
    test('an entry over 4 GB is streamed with zip64', () {
      final output = OutputMemoryStream();
      final encoder = ZipEncoder(streamed: true)..startEncode(output);
      final body = encoder.addHeader(
          ArchiveFile.file('a', 5000000000, FileContentMemory([1, 2, 3])));
      expect(body, isNotNull);
      body!.finish();
      encoder.endEncode();
      final view = ByteData.sublistView(output.getBytes());
      expect(view.getUint16(4, Endian.little), 45);
      expect(view.getUint32(22, Endian.little), 0xFFFFFFFF);
      expect(view.getUint16(28, Endian.little), 20);

      var central = 0;
      while (view.getUint32(central, Endian.little) != 0x02014b50) {
        central++;
      }
      expect(view.getUint32(central - 24, Endian.little), 0x08074b50);
      expect(view.getUint64(central - 8, Endian.little), 5000000000);
      expect(view.getUint16(central + 6, Endian.little), 45);
      expect(view.getUint32(central + 24, Endian.little), 0xFFFFFFFF);
      final nameLength = view.getUint16(central + 28, Endian.little);
      final zip64 = central + 46 + nameLength;
      expect(view.getUint16(zip64, Endian.little), 1);
      expect(view.getUint64(zip64 + 4, Endian.little), 5000000000);
    });

    test('it emits before the compression pass reads an entire entry', () {
      final bytes = _source(1024 * 1024, 17);
      final input = _ObservedInput(bytes);
      final output = _ObservedOutput(input);
      ZipChunkedEncoder(output)
        ..add(ArchiveFile.stream('a', input))
        ..close();
      expect(output.firstRead, isNotNull);
      // The CRC pass must read the source once before compression starts
      expect(output.firstRead!, lessThan(2 * bytes.length));
    });

    test('an entry without content is a valid empty file', () {
      final bytes = _zip([ArchiveFile.noData('empty')]);
      final archive = ZipDecoder().decodeBytes(bytes);
      final file = archive.files.single.rawContent! as ZipFile;
      expect(
          file.compressionMethod != CompressionType.deflate ||
              file.compressedSize > 0,
          isTrue);
      expect(archive.files.single.content, isEmpty);
    });

    test('what it writes reads back', () {
      final want = _source(70000, 3);
      final back = ZipDecoder().decodeBytes(_zip(_entries()), verify: true);
      expect(back.files.map((f) => f.name), _entries().map((e) => e.name));
      expect(back.files[1].content, want);
    });

    test('the central directory carries bit 3 as well', () {
      // A reader that compares the two headers, 7-zip among them, calls the
      // pair broken when only one of them says the sizes follow the data
      final bytes = _zip([ArchiveFile.bytes('a.bin', _source(60000, 7))]);
      final eocd = bytes.length - 22;
      final centralAt = bytes[eocd + 16] |
          (bytes[eocd + 17] << 8) |
          (bytes[eocd + 18] << 16) |
          (bytes[eocd + 19] << 24);
      // signature, version made by, version needed, then the flag word
      expect(bytes[centralAt] | (bytes[centralAt + 1] << 8), 0x4b50);
      expect(bytes[centralAt + 8] & 0x08, 0x08);
      expect(bytes[6] & 0x08, 0x08, reason: 'the local header too');
    });

    test('the local header defers the check and the sizes', () {
      final bytes = _zip([ArchiveFile.bytes('a.bin', _source(60000, 7))]);
      // General purpose bit 3, then zeros where the check and sizes go
      expect(bytes[6] & 0x08, 0x08);
      for (var at = 14; at < 26; at++) {
        expect(bytes[at], 0, reason: 'byte $at');
      }
    });

    test('an entry is not held whole', () async {
      final directory = await Directory.systemTemp.createTemp('zip_stream');
      try {
        final path = '${directory.path}/big.bin';
        // Random enough that deflate cannot shrink it away
        File(path).writeAsBytesSync(_source(4 << 20, 19));
        final held = _Held();
        ZipChunkedEncoder(held)
          ..add(ArchiveFile.stream('big.bin', InputFileStream(path)))
          ..close();
        // Buffered, the whole entry would land in one piece
        expect(held.pieces, greaterThan(16));
        expect(
            ZipDecoder()
                .decodeBytes(held.bytes, verify: true)
                .files
                .single
                .size,
            4 << 20);
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });

  group('zip codec', () {
    test('entries transform into an archive', () async {
      final bytes = await Stream.fromIterable(_entries())
          .transform(zipCodec.encoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      expect(bytes, _zip(_entries()));
      expect(ZipDecoder().decodeBytes(Uint8List.fromList(bytes)).files.length,
          _entries().length);
    });

    test('a source that goes silent can be cancelled and is let go', () async {
      // Parked waiting for an entry that never comes, which a cancel used to
      // wait on for good
      final source = StreamController<ArchiveFile>();
      final written = Completer<void>();
      final subscription = source.stream
          .transform(zipCodec.encoder)
          .listen((_) => written.isCompleted ? null : written.complete());
      source.add(_entries().first);
      await written.future.timeout(const Duration(seconds: 5));
      // Past the last piece of the entry, so it waits on the source
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await subscription.cancel().timeout(const Duration(seconds: 5));
      expect(source.hasListener, isFalse);
      await source.close();
    });

    for (final autoClose in [false, true]) {
      test('autoClose $autoClose decides whether a written entry is closed',
          () async {
        final content = _ClosingInput(_source(300000, 21));
        final bytes = await Stream.value(ArchiveFile.stream('big.bin', content))
            .transform(ZipCodec(autoClose: autoClose).encoder)
            .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
        expect(bytes, isNotEmpty);
        expect(content.closed, autoClose);
      });
    }

    test('autoClose closes an entry cut off by a cancel', () async {
      final content = _ClosingInput(_source(8 << 20, 23));
      final source = StreamController<ArchiveFile>();
      final written = Completer<void>();
      final subscription = source.stream
          .transform(const ZipCodec(autoClose: true).encoder)
          .listen((_) => written.isCompleted ? null : written.complete());
      source.add(ArchiveFile.stream('big.bin', content));
      await written.future.timeout(const Duration(seconds: 10));
      await subscription.cancel().timeout(const Duration(seconds: 10));
      await source.close();
      expect(content.closed, isTrue);
    });

    test('the bytes of an entry survive the transformer', () async {
      final archive = Archive()..add(ArchiveFile.string('a.txt', 'hello'));
      Future<List<int>> once() => Stream.fromIterable(archive.files)
          .transform(zipCodec.encoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      final first = await once();
      expect(archive.files.single.content, 'hello'.codeUnits);
      expect(await once(), first);
    });
  });

  group('zip on disk', () {
    // The stream writes an archive nothing reads back as it goes, so it is read
    // back afterwards the way a reader gets it: off disk, through the file
    // stream, and then extracted entry by entry
    test('what the stream writes reads back off disk', () async {
      final directory = await Directory.systemTemp.createTemp('zip_stream');
      try {
        final want = _source(70000, 3);
        final path = '${directory.path}/out.zip';
        File(path).writeAsBytesSync(_zip(_entries()));

        final input = InputFileStream(path);
        final archive = ZipDecoder().decodeStream(input, verify: true);
        expect(archive.files.map((file) => file.name),
            _entries().map((entry) => entry.name));
        expect(archive.files[1].readBytes(), want);
        await input.close();
      } finally {
        directory.deleteSync(recursive: true);
      }
    });

    test('extractFileToDisk writes the entries back as files', () async {
      final directory = await Directory.systemTemp.createTemp('zip_stream');
      try {
        final want = _source(70000, 3);
        final path = '${directory.path}/out.zip';
        File(path).writeAsBytesSync(_zip(_entries()));

        await extractFileToDisk(path, '${directory.path}/out');
        expect(File('${directory.path}/out/dir/binary.dat').readAsBytesSync(),
            want);
        expect(File('${directory.path}/out/readme.txt').readAsStringSync(),
            'the first entry');
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });

  group('back pressure inside one entry', () {
    test('an entry is handed over as it is compressed', () async {
      final content = _source(16 << 20, 11);
      final started = DateTime.now();
      var first = -1;
      await for (final piece in Stream<ArchiveFile>.fromIterable(
              [ArchiveFile.bytes('big.bin', content)])
          .transform(zipCodec.encoder)) {
        if (first < 0 && piece.isNotEmpty) {
          first = DateTime.now().difference(started).inMicroseconds;
        }
      }
      final whole = DateTime.now().difference(started).inMicroseconds;
      // The transform used to deflate the whole entry before its first yield,
      // which held every compressed byte of it in memory
      expect(first, lessThan(whole ~/ 4));
    });
  });
}

class _ObservedInput extends InputMemoryStream {
  int read = 0;

  _ObservedInput(super.bytes);

  @override
  InputStream readBytes(int count) {
    final piece = super.readBytes(count);
    read += piece.length;
    return piece;
  }
}

class _ObservedOutput extends _Held {
  final _ObservedInput input;
  int? firstRead;

  _ObservedOutput(this.input);

  @override
  void add(List<int> data) {
    if (data.isNotEmpty) firstRead ??= input.read;
    super.add(data);
  }
}

class _Held implements Sink<List<int>> {
  final _pieces = <List<int>>[];
  var _length = 0;
  var closed = false;

  int get pieces => _pieces.length;

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

/// Reports whether whoever took it closed it
class _ClosingInput extends InputMemoryStream {
  var closed = false;

  _ClosingInput(super.bytes);

  @override
  void closeSync() {
    closed = true;
    super.closeSync();
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

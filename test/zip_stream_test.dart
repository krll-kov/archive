import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// zip is written forward: a local header, its data, and the central directory
// at the end, nothing read back. So the bytes have to be the ones the
// whole-archive encoder writes, and a real unzip has to accept them.

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
    test('what it writes reads back', () {
      final want = _source(70000, 3);
      final back = ZipDecoder().decodeBytes(_zip(_entries()), verify: true);
      expect(back.files.map((f) => f.name), _entries().map((e) => e.name));
      expect(back.files[1].content, want);
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
        expect(ZipDecoder().decodeBytes(held.bytes, verify: true).files.single.size,
            4 << 20);
      } finally {
        directory.deleteSync(recursive: true);
      }
    });

    test('unzip accepts it', () async {
      if (!File('/usr/bin/unzip').existsSync()) {
        return;
      }
      final directory = await Directory.systemTemp.createTemp('zip_stream');
      try {
        final want = _source(70000, 3);
        final path = '${directory.path}/out.zip';
        File(path).writeAsBytesSync(_zip(_entries()));
        final tested = Process.runSync('unzip', ['-t', path]);
        expect(tested.exitCode, 0, reason: tested.stdout as String);
        Process.runSync('unzip', ['-q', path, '-d', '${directory.path}/out']);
        expect(File('${directory.path}/out/dir/binary.dat').readAsBytesSync(),
            want);
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
  });

  group('zip against the system unzip', () {
    test('unzip accepts what the stream writes', () async {
      if (!File('/usr/bin/unzip').existsSync()) {
        return;
      }
      final directory = await Directory.systemTemp.createTemp('zip_stream');
      try {
        final want = _source(70000, 3);
        final path = '${directory.path}/out.zip';
        File(path).writeAsBytesSync(_zip(_entries()));
        final tested = Process.runSync('unzip', ['-t', path]);
        expect(tested.exitCode, 0, reason: tested.stdout as String);
        Process.runSync('unzip', ['-q', path, '-d', '${directory.path}/out']);
        expect(File('${directory.path}/out/dir/binary.dat').readAsBytesSync(),
            want);
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });
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

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/util/chunked_sink.dart';
import 'package:test/test.dart';

// tar has no index at the end and no back references, so it goes both ways in
// a stream. Writing: the bytes have to be the ones the whole-archive encoder
// writes, and nesting it in a codec's sink has to compress on the way past.
// Reading: the same entries the whole-archive decoder finds, whatever the
// input is cut into.

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
      ArchiveFile.bytes('binary.dat', _source(70000, 3)),
      ArchiveFile.bytes('small.dat', _source(7, 5)),
      ArchiveFile.bytes('again.dat', _source(200000, 9)),
    ];

Archive _archiveOf(List<ArchiveFile> entries) {
  final archive = Archive();
  for (final entry in entries) {
    archive.add(entry);
  }
  return archive;
}

Uint8List _tar(List<ArchiveFile> entries) {
  final held = _Held();
  final encoder = TarChunkedEncoder(held);
  for (final entry in entries) {
    encoder.add(entry);
  }
  encoder.close();
  expect(held.closed, isTrue);
  return held.bytes;
}

Stream<List<int>> _pieces(Uint8List bytes, int piece) async* {
  for (var at = 0; at < bytes.length; at += piece) {
    final end = at + piece < bytes.length ? at + piece : bytes.length;
    yield Uint8List.sublistView(bytes, at, end);
  }
}

/// Name, size and content of every entry, as nested lists: a record of a
/// `Uint8List` compares by identity, which would pass nothing
Future<List<List<Object>>> _stream(Uint8List archive, int piece) async {
  final held = <List<Object>>[];
  await for (final entry in _pieces(archive, piece).transform(tarCodec.decoder)) {
    final bytes = <int>[];
    await for (final part in entry.content) {
      bytes.addAll(part);
    }
    held.add([entry.name, entry.size, bytes]);
  }
  return held;
}

List<List<Object>> _whole(Uint8List archive) => TarDecoder()
    .decodeBytes(archive)
    .files
    .map((f) => <Object>[
          f.name,
          f.size,
          f.isFile ? (f.content as List<int>).toList() : <int>[],
        ])
    .toList();

void main() {
  final directory = Directory('test/_data/tar');
  final archives = directory
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      // writer-big.tar names an entry of 16 GB inside a 4 KB file. The whole
      // decoder clamps the read and reports what it found, the streamed one
      // says the archive ended, so the two have nothing to compare
      .where((name) => name.endsWith('.tar') && name != 'writer-big.tar')
      .toList()
    ..sort();

  group('tar chunked encoder', () {
    test('it writes what one archive writes', () {
      expect(_tar(_entries()), TarEncoder().encodeBytes(_archiveOf(_entries())));
    });

    test('an empty archive is still an archive', () {
      final held = _Held();
      TarChunkedEncoder(held).close();
      expect(held.bytes, TarEncoder().encodeBytes(Archive()));
      expect(TarDecoder().decodeBytes(held.bytes).files, isEmpty);
    });

    test('a name too long for the header reads back', () {
      final name = '${'a-very-long-directory-name/' * 6}file.txt';
      expect(name.length, greaterThan(100));
      final entry = ArchiveFile.string(name, 'content');
      final back = TarDecoder().decodeBytes(_tar([entry]));
      expect(back.files.single.name, name);
    });

    test('adding after close is refused', () {
      final encoder = TarChunkedEncoder(_Held())..close();
      expect(() => encoder.add(ArchiveFile.string('a', 'b')),
          throwsA(isA<StateError>()));
    });

    test('nesting it in zstd writes a .tar.zst on the fly', () {
      final entries = _entries();
      final held = _Held();
      final encoder = TarChunkedEncoder(ZstdChunkedEncoder(held, level: 3));
      for (final entry in entries) {
        encoder.add(entry);
      }
      encoder.close();
      expect(held.closed, isTrue);
      final tar = ZstdDecoder()
          .decodeBytes(held.bytes, verify: true, throwOnError: true);
      expect(tar, _tar(entries));
      final back = TarDecoder().decodeBytes(tar);
      expect(back.files.map((f) => f.name), entries.map((e) => e.name));
      expect(back.files[1].content, entries[1].content);
    });

    test('nesting it in bzip2 writes a .tar.bz2 on the fly', () {
      final entries = _entries();
      final held = _Held();
      final encoder = TarChunkedEncoder(BZip2ChunkedEncoder(held));
      for (final entry in entries) {
        encoder.add(entry);
      }
      encoder.close();
      final tar = BZip2Decoder().decodeBytes(held.bytes, verify: true);
      expect(tar, _tar(entries));
      expect(TarDecoder().decodeBytes(tar).files.map((f) => f.name),
          entries.map((e) => e.name));
    });

    test('an entry read from a file goes through in pieces', () async {
      final directory = await Directory.systemTemp.createTemp('tar_stream');
      try {
        final path = '${directory.path}/big.bin';
        final content = _source(500000, 13);
        File(path).writeAsBytesSync(content);
        final input = InputFileStream(path);
        final entry = ArchiveFile.stream('big.bin', input);
        final held = _Held();
        TarChunkedEncoder(held)
          ..add(entry)
          ..close();
        await input.close();
        final back = TarDecoder().decodeBytes(held.bytes);
        expect(back.files.single.content, content);
        // The file is half a megabyte, handed over in pieces of 64 KiB
        expect(held.pieces, greaterThan(4));
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });

  group('tar codec', () {
    test('entries transform into an archive', () async {
      final entries = _entries();
      final bytes = await Stream.fromIterable(entries)
          .transform(tarCodec.encoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      expect(bytes, _tar(entries));
    });

    test('a .tar.zst is one chain of transforms', () async {
      final entries = _entries();
      final archive = await Stream.fromIterable(entries)
          .transform(tarCodec.encoder)
          .transform(zstdCodec.encoder)
          .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));
      final names = <String>[];
      await for (final entry in Stream.fromIterable([archive])
          .transform(zstdCodec.decoder)
          .transform(tarCodec.decoder)) {
        names.add(entry.name);
        await entry.content.drain<void>();
      }
      expect(names, entries.map((e) => e.name));
    });
  });

  group('SinkOutputStream.writeStream', () {
    test('it hands a stream over in pieces and leaves the position alone', () {
      final source = _source(200000, 17);
      final held = _Held();
      final out = SinkOutputStream(held);
      final input = InputMemoryStream(source);
      input.skip(10);
      out.writeStream(input);
      // What is queued is handed over on flush, which every codec calls
      out.flush();
      expect(held.bytes, Uint8List.sublistView(source, 10));
      expect(out.written, source.length - 10);
      expect(input.position, 10);
      expect(held.pieces, greaterThan(1));
    });

    test('single bytes are gathered rather than handed over one at a time', () {
      final held = _Held();
      final out = SinkOutputStream(held);
      for (var i = 0; i < 200000; i++) {
        out.writeByte(i & 0xff);
      }
      out.flush();
      expect(out.written, 200000);
      expect(held.bytes.length, 200000);
      // 64 KiB a piece, not one call per byte
      expect(held.pieces, lessThan(8));
    });

    test('an exhausted stream writes nothing', () {
      final held = _Held();
      final out = SinkOutputStream(held);
      out.writeStream(InputMemoryStream(Uint8List(0)));
      out.flush();
      expect(out.written, 0);
      expect(held.pieces, 0);
    });
  });

  group('tar stream reader', () {
    for (final name in archives) {
      test('$name reads as the whole-archive decoder does', () async {
        final archive = File('${directory.path}/$name').readAsBytesSync();
        List<List<Object>> want;
        try {
          want = _whole(archive);
        } catch (_) {
          // Not every file here is one this package reads whole either
          return;
        }
        for (final piece in [1, 137, 512, 4096, archive.length]) {
          expect(await _stream(archive, piece), want,
              reason: '$name piece $piece');
        }
      });
    }

    test('a long name and a pax header survive the stream', () async {
      final long = '${'a-very-long-directory-name/' * 6}file.txt';
      final entries = [
        ArchiveFile.string(long, 'first'),
        ArchiveFile.bytes('plain.bin', _source(3000, 5)),
      ];
      final archive = Archive();
      for (final entry in entries) {
        archive.add(entry);
      }
      final bytes = TarEncoder().encodeBytes(archive);
      for (final piece in [1, 512, 9999]) {
        final read = await _stream(bytes, piece);
        expect(read.map((e) => e[0]), [long, 'plain.bin'],
            reason: 'piece $piece');
        expect(read[1][2], _source(3000, 5), reason: 'piece $piece');
      }
    });

    test('content left unread is skipped', () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('a.bin', _source(5000, 7)))
        ..add(ArchiveFile.bytes('b.bin', _source(9000, 11)));
      final bytes = TarEncoder().encodeBytes(archive);
      final names = <String>[];
      await for (final entry in _pieces(bytes, 333).transform(tarCodec.decoder)) {
        names.add(entry.name);
      }
      expect(names, ['a.bin', 'b.bin']);
    });

    test('content read only part way still leaves the archive in step',
        () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('a.bin', _source(5000, 13)))
        ..add(ArchiveFile.string('b.txt', 'second'));
      final bytes = TarEncoder().encodeBytes(archive);
      final names = <String>[];
      await for (final entry in _pieces(bytes, 700).transform(tarCodec.decoder)) {
        names.add(entry.name);
        if (entry.name == 'a.bin') {
          // One piece, then walk away from the rest
          await entry.content.first;
        }
      }
      expect(names, ['a.bin', 'b.txt']);
    });

    test('reading the content twice is refused', () async {
      final archive = Archive()..add(ArchiveFile.string('a.txt', 'one'));
      final bytes = TarEncoder().encodeBytes(archive);
      await for (final entry in _pieces(bytes, 512).transform(tarCodec.decoder)) {
        await entry.content.drain<void>();
        expect(() => entry.content, throwsA(isA<StateError>()));
      }
    });

    test('the content of an entry the archive has passed is refused', () async {
      final archive = Archive()
        ..add(ArchiveFile.string('a.txt', 'one'))
        ..add(ArchiveFile.string('b.txt', 'two'));
      final bytes = TarEncoder().encodeBytes(archive);
      final held = <TarEntry>[];
      await for (final entry in _pieces(bytes, 512).transform(tarCodec.decoder)) {
        held.add(entry);
      }
      expect(() => held.first.content, throwsA(isA<StateError>()));
    });

    test('an archive cut short is refused', () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('a.bin', _source(4000, 17)));
      final bytes = TarEncoder().encodeBytes(archive);
      final short = Uint8List.sublistView(bytes, 0, 1200);
      expect(_stream(short, 256), throwsA(isA<ArchiveException>()));
    });

    test('the type flag comes back as a type', () async {
      final archive = Archive()
        ..add(ArchiveFile.directory('dir'))
        ..add(ArchiveFile.string('dir/a.txt', 'one'))
        ..add(ArchiveFile.symlink('link', 'dir/a.txt'));
      final bytes = TarEncoder().encodeBytes(archive);
      final types = <String, TarEntryType>{};
      await for (final entry in _pieces(bytes, 512).transform(tarCodec.decoder)) {
        types[entry.name] = entry.type;
        await entry.content.drain<void>();
      }
      expect(types['dir'], TarEntryType.directory);
      expect(types['dir/a.txt'], TarEntryType.file);
      expect(types['link'], TarEntryType.symbolicLink);
      expect(types['link'] == TarEntryType.file, isFalse);
    });

    test('an empty archive yields nothing', () async {
      final bytes = TarEncoder().encodeBytes(Archive());
      expect(await _stream(bytes, 512), isEmpty);
    });

    test('it reads a .tar.gz as it arrives', () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('big.bin', _source(200000, 19)))
        ..add(ArchiveFile.string('note.txt', 'at the end'));
      final tar = TarEncoder().encodeBytes(archive);
      final gz = Uint8List.fromList(gzip.encode(tar));
      final names = <String>[];
      var bytes = 0;
      await for (final entry
          in _pieces(gz, 4096).transform(gzip.decoder).transform(tarCodec.decoder)) {
        names.add(entry.name);
        await for (final piece in entry.content) {
          bytes += piece.length;
        }
      }
      expect(names, ['big.bin', 'note.txt']);
      expect(bytes, 200000 + 10);
    });

    test('it reads a .tar.zst as it arrives', () async {
      final archive = Archive()
        ..add(ArchiveFile.bytes('big.bin', _source(300000, 23)));
      final tar = TarEncoder().encodeBytes(archive);
      final zst = Uint8List.fromList(zstdCodec.encode(tar));
      final read = <String>[];
      await for (final entry in _pieces(zst, 8192)
          .transform(zstdCodec.decoder)
          .transform(tarCodec.decoder)) {
        read.add(entry.name);
        expect(await entry.content.fold<int>(0, (n, p) => n + p.length),
            300000);
      }
      expect(read, ['big.bin']);
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
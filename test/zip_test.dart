import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_test_util.dart';

final zipTests = <dynamic>[
  {
    'Name': 'test/_data/zip/test.zip',
    'Comment': 'This is a zipfile comment.',
    'File': [
      {
        'Name': 'test.txt',
        'Content': 'This is a test text file.\n'.codeUnits,
        'Mtime': '09-05-10 12:12:02',
        'Mode': 0644,
      },
      {
        'Name': 'gophercolor16x16.png',
        'File': 'gophercolor16x16.png',
        'Mtime': '09-05-10 15:52:58',
        'Mode': 0644,
      },
    ],
  },
  {
    'Name': 'test/_data/zip/test-trailing-junk.zip',
    'Comment': 'This is a zipfile comment.',
    'File': [
      {
        'Name': 'test.txt',
        'Content': 'This is a test text file.\n'.codeUnits,
        'Mtime': '09-05-10 12:12:02',
        'Mode': 0644,
      },
      {
        'Name': 'gophercolor16x16.png',
        'File': 'gophercolor16x16.png',
        'Mtime': '09-05-10 15:52:58',
        'Mode': 0644,
      },
    ],
  },
  /*{
    'Name':   'test/_data/zip/r.zip',
    'Source': returnRecursiveZip,
    'File': [
      {
        'Name':    'r/r.zip',
        'Content': rZipBytes(),
        'Mtime':   '03-04-10 00:24:16',
        'Mode':    0666,
      },
    ],
  },*/
  {
    'Name': 'test/_data/zip/symlink.zip',
    'File': [
      {
        'Name': 'symlink',
        'Content': '../target'.codeUnits,
        'Mode': 0777 | 0120000,
        'isSymbolicLink': true,
      },
    ],
  },
  {
    'Name': 'test/_data/zip/readme.zip',
  },
  {
    'Name': 'test/_data/zip/readme.notzip',
    //'Error': ErrFormat,
  },
  {
    'Name': 'test/_data/zip/dd.zip',
    'File': [
      {
        'Name': 'filename',
        'Content': 'This is a test textfile.\n'.codeUnits,
        'Mtime': '02-02-11 13:06:20',
        'Mode': 0666,
      },
    ],
  },
  {
    // created in windows XP file manager.
    'Name': 'test/_data/zip/winxp.zip',
    'File': [
      {'Name': 'hello', 'isFile': true},
      {'Name': 'dir/bar', 'isFile': true},
      {
        'Name': 'dir/empty/',
        'Content': <int>[], // empty list of codeUnits - no content
        'isFile': false
      },
      {'Name': 'readonly', 'isFile': true},
    ]
  },
  /*
  {
    // created by Zip 3.0 under Linux
    'Name': 'test/_data/zip/unix.zip',
    'File': crossPlatform,
  },*/
  {
    'Name': 'test/_data/zip/go-no-datadesc-sig.zip',
    'File': [
      {
        'Name': 'foo.txt',
        'Content': 'foo\n'.codeUnits,
        'Mtime': '03-08-12 16:59:10',
        'Mode': 0644,
      },
      {
        'Name': 'bar.txt',
        'Content': 'bar\n'.codeUnits,
        'Mtime': '03-08-12 16:59:12',
        'Mode': 0644,
      },
    ],
  },
  {
    'Name': 'test/_data/zip/go-with-datadesc-sig.zip',
    'File': [
      {
        'Name': 'foo.txt',
        'Content': 'foo\n'.codeUnits,
        'Mode': 0666,
      },
      {
        'Name': 'bar.txt',
        'Content': 'bar\n'.codeUnits,
        'Mode': 0666,
      },
    ],
  },
  /*{
    'Name':   'Bad-CRC32-in-data-descriptor',
    'Source': returnCorruptCRC32Zip,
    'File': [
      {
        'Name':       'foo.txt',
        'Content':    'foo\n'.codeUnits,
        'Mode':       0666,
        'ContentErr': ErrChecksum,
      },
      {
        'Name':    'bar.txt',
        'Content': 'bar\n'.codeUnits,
        'Mode':    0666,
      },
    ],
  },*/
  // Tests that we verify (and accept valid) crc32s on files
  // with crc32s in their file header (not in data descriptors)
  {
    'Name': 'test/_data/zip/crc32-not-streamed.zip',
    'File': [
      {
        'Name': 'foo.txt',
        'Content': 'foo\n'.codeUnits,
        'Mtime': '03-08-12 16:59:10',
        'Mode': 0644,
      },
      {
        'Name': 'bar.txt',
        'Content': 'bar\n'.codeUnits,
        'Mtime': '03-08-12 16:59:12',
        'Mode': 0644,
      },
    ],
  },
  // Tests that we verify (and reject invalid) crc32s on files
  // with crc32s in their file header (not in data descriptors)
  {
    'Name': 'test/_data/zip/crc32-not-streamed.zip',
    //'Source': returnCorruptNotStreamedZip,
    'File': [
      {
        'Name': 'foo.txt',
        'Content': 'foo\n'.codeUnits,
        'Mtime': '03-08-12 16:59:10',
        'Mode': 0644,
        'VerifyChecksum': true
        //'ContentErr': ErrChecksum,
      },
      {
        'Name': 'bar.txt',
        'Content': 'bar\n'.codeUnits,
        'Mtime': '03-08-12 16:59:12',
        'Mode': 0644,
        'VerifyChecksum': true
      },
    ],
  },
  {
    'Name': 'test/_data/zip/zip64.zip',
    'File': [
      {
        'Name': 'README',
        'Content': 'This small file is in ZIP64 format.\n'.codeUnits,
        'Mtime': '08-10-12 14:33:32',
        'Mode': 0644,
      },
    ],
  },
];

void main() async {
  group('zip', () {
    test('EOCD may span two reverse-search chunks', () {
      final dir = Directory.systemTemp.createTempSync('archive-comment-');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final size in [
        0,
        1005,
        1006,
        1007,
        1008,
        1009,
        1010,
        2030,
        2031,
        2032,
        2033,
        2034,
        65535
      ]) {
        final content = 'known payload' * 400;
        final archive = Archive()
          ..comment = 'x' * size
          ..addFile(ArchiveFile.string('hello.txt', content));
        final bytes = ZipEncoder().encodeBytes(archive, level: 0);
        final path = '${dir.path}/fixture.zip';
        File(path).writeAsBytesSync(bytes);
        for (final createInput in <InputStream Function()>[
          () => InputMemoryStream(bytes),
          () => InputFileStream(path)
        ]) {
          final input = createInput();
          try {
            final decoded = ZipDecoder().decodeStream(input);
            expect(decoded.length, 1,
                reason: 'comment=$size, ${input.runtimeType}');
            expect(decoded.first.content, content.codeUnits);
          } finally {
            input.closeSync();
          }
        }
      }
    });

    test('short malformed streams terminate', () {
      for (var length = 0; length < 9; length++) {
        expect(ZipDecoder().decodeBytes(List.filled(length, 0)), isEmpty);
      }
    });

    test('an extra field with 1 to 3 trailing bytes is read', () {
      final content = utf8.encode('extra field payload' * 20);
      final name = utf8.encode('hello.txt');
      final crc = getCrc32(content);
      for (var trailing = 1; trailing <= 3; trailing++) {
        final extra = (ByteData(9 + trailing)
              ..setUint16(0, 0x5455, Endian.little)
              ..setUint16(2, 5, Endian.little)
              ..setUint8(4, 1)
              ..setUint32(5, 1700000000, Endian.little))
            .buffer
            .asUint8List();
        final local = ByteData(30)
          ..setUint32(0, 0x04034b50, Endian.little)
          ..setUint16(4, 10, Endian.little)
          ..setUint32(14, crc, Endian.little)
          ..setUint32(18, content.length, Endian.little)
          ..setUint32(22, content.length, Endian.little)
          ..setUint16(26, name.length, Endian.little)
          ..setUint16(28, extra.length, Endian.little);
        final central = ByteData(46)
          ..setUint32(0, 0x02014b50, Endian.little)
          ..setUint16(4, 20, Endian.little)
          ..setUint16(6, 10, Endian.little)
          ..setUint32(16, crc, Endian.little)
          ..setUint32(20, content.length, Endian.little)
          ..setUint32(24, content.length, Endian.little)
          ..setUint16(28, name.length, Endian.little)
          ..setUint16(30, extra.length, Endian.little);
        final out = BytesBuilder()
          ..add(local.buffer.asUint8List())
          ..add(name)
          ..add(extra)
          ..add(content);
        final centralOffset = out.length;
        out
          ..add(central.buffer.asUint8List())
          ..add(name)
          ..add(extra);
        final end = ByteData(22)
          ..setUint32(0, 0x06054b50, Endian.little)
          ..setUint16(8, 1, Endian.little)
          ..setUint16(10, 1, Endian.little)
          ..setUint32(12, out.length - centralOffset, Endian.little)
          ..setUint32(16, centralOffset, Endian.little);
        out.add(end.buffer.asUint8List());
        final bytes = out.takeBytes();
        for (final (verify, throwOnError) in [
          (false, false),
          (true, false),
          (false, true)
        ]) {
          final decoded = ZipDecoder()
              .decodeBytes(bytes, verify: verify, throwOnError: throwOnError);
          expect(decoded.single.content, content,
              reason: 'trailing $trailing, verify $verify, '
                  'throwOnError $throwOnError');
        }
      }
    });

    test('an MS-DOS directory without a trailing slash is a directory',
        () async {
      final bytes = _rawZip([
        _RawEntry('def'.codeUnits, 0x0014, 0x10),
        _RawEntry('def/foo'.codeUnits, 0x0014, 0x20, content: 'foo'.codeUnits),
        _RawEntry('bar'.codeUnits, 0x0314, 0x81a40010,
            content: 'bar'.codeUnits),
        _RawEntry('ghi'.codeUnits, 0x0314, 0x41ed0000),
        _RawEntry('ghi/baz'.codeUnits, 0x0314, 0x81a40000,
            content: 'baz'.codeUnits),
        _RawEntry('dev'.codeUnits, 0x0314, 0x61a40000,
            content: 'dev'.codeUnits),
      ]);
      for (final (verify, throwOnError) in [
        (false, false),
        (true, false),
        (false, true)
      ]) {
        final archive = ZipDecoder()
            .decodeBytes(bytes, verify: verify, throwOnError: throwOnError);
        expect(archive.find('def')!.isDirectory, isTrue,
            reason: 'verify $verify, throwOnError $throwOnError');
        expect(archive.find('def/foo')!.content, 'foo'.codeUnits);
        expect(archive.find('bar')!.content, 'bar'.codeUnits);
        expect(archive.find('ghi')!.isDirectory, isTrue);
        expect(archive.find('dev')!.isDirectory, isFalse);
      }
      final dir = Directory.systemTemp.createTempSync('archive-dos-dir-');
      try {
        await extractArchiveToDisk(ZipDecoder().decodeBytes(bytes), dir.path);
        expect(File(p.join(dir.path, 'def', 'foo')).readAsStringSync(), 'foo');
        expect(File(p.join(dir.path, 'ghi', 'baz')).readAsStringSync(), 'baz');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('a name without the UTF-8 flag is CP437 unless it is valid UTF-8', () {
      List<int> unicodePath(List<int> header, String name,
          {int crc = 0, int version = 1}) {
        final utf = utf8.encode(name);
        return (ByteData(9)
                  ..setUint16(0, 0x7075, Endian.little)
                  ..setUint16(2, 5 + utf.length, Endian.little)
                  ..setUint8(4, version)
                  ..setUint32(5, crc ^ getCrc32(header), Endian.little))
                .buffer
                .asUint8List() +
            utf;
      }

      final bytes = _rawZip([
        _RawEntry(
            [0x99, ...'lf'.codeUnits, 0x84, ...'sser.txt'.codeUnits], 0, 0x20),
        _RawEntry('?lf?sser2.txt'.codeUnits, 0, 0x20,
            extra: unicodePath('?lf?sser2.txt'.codeUnits, 'Ölfässer2.txt')),
        _RawEntry('?lf?sser3.txt'.codeUnits, 0, 0x20,
            extra: unicodePath('?lf?sser3.txt'.codeUnits, 'Ölfässer3.txt',
                crc: 1)),
        _RawEntry(utf8.encode('Ölfässer4.txt'), 0x0314, 0x81a40000),
        _RawEntry('?lf?sser5.txt'.codeUnits, 0, 0x20,
            extra: unicodePath('?lf?sser5.txt'.codeUnits, 'Ölfässer5.txt',
                version: 2)),
      ]);
      for (final (verify, throwOnError) in [
        (false, false),
        (true, false),
        (false, true)
      ]) {
        expect(
            ZipDecoder()
                .decodeBytes(bytes, verify: verify, throwOnError: throwOnError)
                .map((f) => f.name),
            [
              'Ölfässer.txt',
              'Ölfässer2.txt',
              '?lf?sser3.txt',
              'Ölfässer4.txt',
              '?lf?sser5.txt'
            ],
            reason: 'verify $verify, throwOnError $throwOnError');
      }
      expect(
          ZipDecoder(filenameEncoding: latin1)
              .decodeBytes(bytes)
              .map((f) => f.name)
              .first,
          '\u0099lf\u0084sser.txt');
      final flagged = ZipEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('café.txt', 'x')));
      expect(
          ZipDecoder(filenameEncoding: latin1)
              .decodeBytes(flagged)
              .map((f) => f.name),
          ['café.txt']);
    });

    test('EOCD remains covered when approaching the first chunk', () {
      final dir = Directory.systemTemp.createTempSync('archive-first-chunk-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final empty = ZipEncoder().encodeBytes(
          Archive()..addFile(ArchiveFile.string('data.bin', '')),
          level: 0);
      final overhead = empty.length - 22;
      for (var position = 1020; position <= 1024; position++) {
        for (var comment = 1006; comment <= 1010; comment++) {
          final content = 'a' * (position - overhead);
          final bytes = ZipEncoder().encodeBytes(
              Archive()
                ..comment = 'x' * comment
                ..addFile(ArchiveFile.string('data.bin', content)),
              level: 0);
          expect(bytes.length - 22 - comment, position);
          final path = '${dir.path}/fixture.zip';
          File(path).writeAsBytesSync(bytes);
          for (final createInput in <InputStream Function()>[
            () => InputMemoryStream(bytes),
            () => InputFileStream(path)
          ]) {
            final input = createInput();
            try {
              final decoder = ZipDecoder();
              final archive = decoder.decodeStream(input);
              expect(decoder.directory.filePosition, position,
                  reason:
                      'position=$position comment=$comment ${input.runtimeType}');
              expect(archive.length, 1);
              expect(archive.first.content, content.codeUnits);
            } finally {
              input.closeSync();
            }
          }
        }
      }
    });

    test('the EOCD of a nested zip is not mistaken for the outer one', () {
      final dir = Directory.systemTemp.createTempSync('archive-nested-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final inner = ZipEncoder().encodeBytes(
          Archive()..addFile(ArchiveFile.string('inner.txt', 'i' * 50)),
          level: 0);
      // The padding shifts the nested archive's own EOCD away from the end of
      // the outer file, so the search meets it both inside the first chunk it
      // reads and several chunks in.
      for (final pad in [0, 1, 2, 20, 500, 1000, 1024, 1100, 2048]) {
        final outer = Archive()
          ..addFile(ArchiveFile.bytes('inner.zip', Uint8List.fromList(inner)))
          ..addFile(ArchiveFile.string('pad.txt', 'p' * pad));
        final bytes = ZipEncoder().encodeBytes(outer, level: 0);
        final path = '${dir.path}/nested.zip';
        File(path).writeAsBytesSync(bytes);
        for (final createInput in <InputStream Function()>[
          () => InputMemoryStream(bytes),
          () => InputFileStream(path)
        ]) {
          final input = createInput();
          try {
            final decoder = ZipDecoder();
            final archive = decoder.decodeStream(input);
            expect(decoder.directory.filePosition, bytes.length - 22,
                reason: 'pad=$pad, ${input.runtimeType}');
            expect(archive.length, 2);
            expect(archive.findFile('inner.zip')!.content, inner);
            expect(archive.findFile('pad.txt')!.content.length, pad);
          } finally {
            input.closeSync();
          }
        }
      }
    });

    test('a signature in the trailing comment bytes is too late to be an EOCD',
        () {
      final dir = Directory.systemTemp.createTempSync('archive-tail-sig-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final content = 'known payload' * 400;
      // A record needs 22 bytes, so a signature closer than that to the end of
      // the file cannot start one and must not end the search.
      for (var trailing = 0; trailing <= 22 - 4 - 1; trailing++) {
        final comment = '${'x' * 40}PK${'y' * trailing}';
        final bytes = ZipEncoder().encodeBytes(
            Archive()
              ..comment = comment
              ..addFile(ArchiveFile.string('hello.txt', content)),
            level: 0);
        final path = '${dir.path}/tail.zip';
        File(path).writeAsBytesSync(bytes);
        for (final createInput in <InputStream Function()>[
          () => InputMemoryStream(bytes),
          () => InputFileStream(path)
        ]) {
          final input = createInput();
          try {
            final decoder = ZipDecoder();
            final archive = decoder.decodeStream(input);
            expect(decoder.directory.filePosition,
                bytes.length - 22 - comment.length,
                reason: 'trailing=$trailing, ${input.runtimeType}');
            expect(archive.length, 1);
            expect(archive.first.content, content.codeUnits);
          } finally {
            input.closeSync();
          }
        }
      }
    });

    test('ArchiveFile compression level', () async {
      final testArchive = Archive();
      final list = Uint8List(1000);
      for (var i = 0; i < list.length; i++) {
        list[i] = i % 256;
      }
      final f = ArchiveFile.bytes('test', list);
      final f2 = ArchiveFile.bytes('test2', list);
      testArchive.addFile(f);
      testArchive.addFile(f2);

      final zipBytes = ZipEncoder().encode(testArchive);

      f.compression = CompressionType.none;
      final zipBytes2 = ZipEncoder().encode(testArchive);

      // Using no compression should result in a larger zip
      expect(zipBytes.length, lessThan(zipBytes2.length));

      final archive2 = ZipDecoder().decodeBytes(zipBytes2);
      // Verify the compression method decoded from the zip is preserved.
      expect(archive2.files[0].compression, CompressionType.none);
      expect(archive2.files[1].compression, CompressionType.deflate);

      f.compression = CompressionType.deflate;
      f.compressionLevel = 9;
      f2.compressionLevel = 9;
      final zipBytes3 = ZipEncoder().encode(testArchive);

      // Higher compression level should result in a smaller zip
      expect(zipBytes.length, greaterThan(zipBytes3.length));
    });

    test('encode file stream', () async {
      final input = InputFileStream('test/_data/zip/android-javadoc.zip');
      final output = OutputFileStream('$testOutputPath/encode_file_stream.zip');
      final archive = Archive();
      archive.add(ArchiveFile.stream('android-javadoc.zip', input));
      ZipEncoder().encodeStream(archive, output);

      final archive2 = ZipDecoder().decodeStream(InputMemoryStream(
          File('$testOutputPath/encode_file_stream.zip').readAsBytesSync()));

      input.reset();
      expect(archive2.length, 1);
      expect(archive2[0].name, 'android-javadoc.zip');
      expect(archive2[0].size, input.length);
      final content = archive2[0].content;
      expect(content.length, input.length);
    });

    test('file close', () async {
      final input = InputFileStream('test/_data/test2.zip');
      final archive = ZipDecoder().decodeStream(input);
      final f1 = archive[1];
      final f2 = archive[3];
      f1.closeSync();
      final f2content = f2.content;
      expect(f2content.length, 3);
    });

    test('memory file close', () async {
      final archive = ZipDecoder().decodeStream(
          InputMemoryStream(File('test/_data/test2.zip').readAsBytesSync()));
      final f1 = archive[1];
      final f2 = archive[3];
      f1.closeSync();
      final f2content = f2.content;
      expect(f2content.length, 3);
    });

    test('shared file', () async {
      final archive = ZipDecoder().decodeStream(
          InputMemoryStream(File('test/_data/test2.zip').readAsBytesSync()));
      final archive2 = Archive()..add(archive[1]);
      final zip = ZipEncoder().encodeBytes(archive2, autoClose: true);
      final archive3 = ZipDecoder().decodeBytes(zip);
      expect(archive3.length, 1);
      expect(archive3[0].name, archive[1].name);
      final b1 = archive3[0].content;
      final b2 = archive[1].content;
      compareBytes(b1, b2);
    });

    test('empty', () async {
      final archive = Archive();
      final encoded = ZipEncoder().encodeBytes(archive);
      final decoded = ZipDecoder().decodeBytes(encoded);
      expect(decoded.length, equals(0));
    });

    test('decode 0 bytes', () async {
      final archive = ZipDecoder().decodeBytes(Uint8List(0));
      expect(archive.length, equals(0));
    });

    test('normalizes backslash path separators', () async {
      // Regression test for #411: Windows-style paths with backslashes must
      // be normalized to forward slashes, as required by the zip format.
      final archive = Archive();
      archive.add(ArchiveFile('dir_name\\file_name', 3, [1, 2, 3]));
      archive.add(ArchiveFile.directory('sub_dir\\nested'));

      final encoded = ZipEncoder().encodeBytes(archive);
      final decoded = ZipDecoder().decodeBytes(encoded);

      final names = decoded.map((f) => f.name).toList();
      for (final name in names) {
        expect(name, isNot(contains('\\')));
      }
      expect(names, contains('dir_name/file_name'));
      expect(names, contains('sub_dir/nested/'));
    });

    test('apk', () async {
      final archive = Archive()
        ..addFile(
            ArchiveFile.bytes('AndroidManifest.xml', List<int>.filled(100, 0)));

      final apk = ZipEncoder().encode(archive);

      final decodedArchive = ZipDecoder().decodeBytes(apk);
      for (final archiveFile in decodedArchive.files) {
        expect(archiveFile.rawContent, isNotNull);
        expect(archiveFile.rawContent!.length, 6);
      }
    });

    test('zip file data: memory stream', () async {
      final archive = ZipDecoder().decodeStream(
          InputMemoryStream(File('test/_data/test2.zip').readAsBytesSync()));
      final file = archive[1];
      file.closeSync();
      expect(file.rawContent, isNotNull);
    });

    test('encode already compressed file', () {
      final testArchive = Archive();
      testArchive.addFile(ArchiveFile.bytes('test', [1, 2, 3]));

      final testArchiveBytes =
          ZipEncoder().encode(testArchive, level: DeflateLevel.bestCompression);

      final decodedTestArchive = ZipDecoder().decodeBytes(testArchiveBytes);

      // Verify that the archive file is already compressed and will be
      // compressed when re-encoded.
      expect(decodedTestArchive.files.single.isCompressed, true);

      final decodedTestArchiveBytes = ZipEncoder()
          .encode(decodedTestArchive, level: DeflateLevel.bestCompression);

      final verifyArchive = ZipDecoder().decodeBytes(decodedTestArchiveBytes);
      expect(verifyArchive.single.content, [1, 2, 3]);
    });

    test('re-encode after reading content', () {
      // https://github.com/brendan-duncan/archive/issues/374
      // Reading a file's content caches the decompressed data, which should
      // not cause the still-compressed rawContent to be compressed a second
      // time when the archive is re-encoded.
      final text = 'Hello World! ' * 10;
      final archive = Archive()..addFile(ArchiveFile.string('test.txt', text));
      final zipBytes = ZipEncoder().encode(archive);

      final decodedArchive = ZipDecoder().decodeBytes(zipBytes);
      final file = decodedArchive.findFile('test.txt')!;

      // Trigger decompression, caching the decompressed content.
      expect(utf8.decode(file.content), text);
      expect(file.isCompressed, true);

      final reEncodedZipBytes = ZipEncoder().encode(decodedArchive);

      final verifyArchive =
          ZipDecoder().decodeBytes(reEncodedZipBytes, verify: true);
      final verifyFile = verifyArchive.findFile('test.txt')!;
      expect(utf8.decode(verifyFile.content), text);
    });

    test('decode encode', () async {
      final archive = ZipDecoder().decodeStream(
          InputMemoryStream(File('test/_data/test2.zip').readAsBytesSync()));

      final zipBytes = ZipEncoder().encodeBytes(archive);

      final archive2 = ZipDecoder().decodeBytes(zipBytes);

      expect(archive.length, archive2.length);
    });

    test('decode file stream', () async {
      final input = InputFileStream('test/_data/zip/android-javadoc.zip',
          bufferSize: 32 * 1024);
      final archive = ZipDecoder().decodeStream(input);
      await extractArchiveToDisk(
          archive, '$testOutputPath/zip_decode_file_stream');
    });

    test('the decoder reads a stream in either byte order', () {
      for (final name in ['test.zip', 'lzma.zip']) {
        final path = 'test/_data/zip/$name';
        final bytes = File(path).readAsBytesSync();
        final expected = ZipDecoder().decodeBytes(bytes);
        expect(expected.files, isNotEmpty, reason: name);
        for (final order in ByteOrder.values) {
          for (final input in <InputStream>[
            InputFileStream(path, byteOrder: order),
            InputMemoryStream(bytes, byteOrder: order),
          ]) {
            final reason = '$name ${input.runtimeType} $order';
            final archive = ZipDecoder().decodeStream(input);
            expect(archive.files.map((f) => f.name),
                expected.files.map((f) => f.name),
                reason: reason);
            for (var i = 0; i < archive.length; i++) {
              expect(archive[i].readBytes(), expected[i].readBytes(),
                  reason: '$reason ${archive[i].name}');
            }
            expect(input.byteOrder, order, reason: reason);
            input.closeSync();
          }
        }
      }
    });

    test('an entry decoded and encoded again keeps its modification time', () {
      final decoded = ZipDecoder()
          .decodeBytes(File('test/_data/zip/test.zip').readAsBytesSync());
      final again = ZipDecoder().decodeBytes(ZipEncoder().encodeBytes(decoded));
      expect(again.length, decoded.length);
      for (final file in decoded.files) {
        expect(again.findFile(file.name)!.lastModDateTime, file.lastModDateTime,
            reason: file.name);
      }
    });

    test('decode', () async {
      var file = File(p.join('test/_data/zip/android-javadoc.zip'));
      var bytes = file.readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(archive.length, equals(102));
    });

    test('verify refuses content that does not match its CRC32', () {
      final bytes = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.noCompress('a.txt', 5, utf8.encode('hello')))
        ..add(ArchiveFile.string('b.txt', 'hello' * 100)));
      bytes[latin1.decode(bytes).indexOf('hello')] ^= 0x20;
      final checked = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(() => checked.findFile('a.txt')!.readBytes(),
          throwsA(isA<ArchiveException>()));
      expect(
          () => ZipDecoder()
              .decodeBytes(bytes, verify: true)
              .findFile('a.txt')!
              .writeContent(OutputMemoryStream()),
          throwsA(isA<ArchiveException>()));
      expect(
          checked.findFile('b.txt')!.readBytes(), utf8.encode('hello' * 100));
      expect(ZipDecoder().decodeBytes(bytes).findFile('a.txt')!.readBytes(),
          utf8.encode('Hello'));
    });

    test('an entry from a stream read part way holds the rest of it', () {
      for (final compression in [
        CompressionType.deflate,
        CompressionType.none
      ]) {
        final stream = InputMemoryStream(Uint8List.fromList([10, 20, 30, 40]))
          ..skip(2);
        final archive = Archive()
          ..add(ArchiveFile.stream('a.bin', stream)..compression = compression);
        for (var round = 0; round < 2; round++) {
          final entry = ZipDecoder()
              .decodeBytes(ZipEncoder().encodeBytes(archive), verify: true)
              .first;
          expect(entry.size, 2, reason: '$compression, round $round');
          expect(entry.readBytes(), [30, 40],
              reason: '$compression, round $round');
        }
      }
    });

    test('verify refuses a damaged local header or central directory', () {
      final bytes = ZipEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'hello')));
      final central = ByteData.sublistView(bytes)
          .getUint32(bytes.length - 6, Endian.little);
      for (final at in [0, central]) {
        final damaged = Uint8List.fromList(bytes)..[at] ^= 1;
        for (final decode in [
          (bool verify) => ZipDecoder().decodeBytes(damaged, verify: verify),
          (bool verify) => ZipDecoder()
              .decodeStream(InputMemoryStream(damaged), verify: verify),
        ]) {
          expect(() => decode(true), throwsA(isA<ArchiveException>()),
              reason: 'byte $at');
          expect(() => decode(false), returnsNormally, reason: 'byte $at');
        }
      }
    });

    test('strict decoding refuses a local name the central one does not match',
        () {
      final bytes = ZipEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'hello')));
      final damaged = Uint8List.fromList(bytes)..[31] ^= 1;
      for (final (verify, throwOnError) in [(true, false), (false, true)]) {
        expect(
            () => ZipDecoder().decodeBytes(damaged,
                verify: verify, throwOnError: throwOnError),
            throwsA(isA<ArchiveException>()),
            reason: 'verify $verify, throwOnError $throwOnError');
      }
    });

    test('verify refuses a zip without its end of central directory', () {
      final bytes = ZipEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'hello')));
      for (final cut in [1, 5, 22]) {
        final short = Uint8List.sublistView(bytes, 0, bytes.length - cut);
        expect(() => ZipDecoder().decodeBytes(short, verify: true),
            throwsA(isA<ArchiveException>()),
            reason: 'cut $cut');
        expect(ZipDecoder().decodeBytes(short), isEmpty, reason: 'cut $cut');
      }
      expect(
          ZipDecoder()
              .decodeBytes(ZipEncoder().encodeBytes(Archive()), verify: true),
          isEmpty);
    });

    group('verify, throwOnError and passwords', () {
      final data = Uint8List.fromList(
          List.generate(70000, (i) => (i * 7 + (i >> 9)) % 251));
      final zip = ZipEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.bytes('a', data)));

      Uint8List read(Uint8List bytes, bool verify, bool throwOnError) =>
          ZipDecoder()
              .decodeBytes(bytes, verify: verify, throwOnError: throwOnError)
              .files
              .single
              .content;

      test('a wrong CRC throws only with verify', () {
        final bad = Uint8List.fromList(zip);
        bad[14] ^= 1;
        expect(read(bad, false, false), data);
        expect(read(bad, false, true), data);
        expect(() => read(bad, true, false),
            throwsA(isA<ArchiveChecksumException>()));
      });

      test('a wrong central CRC throws only with verify', () {
        final bad = Uint8List.fromList(zip);
        final central =
            ByteData.sublistView(bad).getUint32(bad.length - 6, Endian.little);
        bad[central + 16] ^= 1;
        expect(read(bad, false, false), data);
        expect(read(bad, false, true), data);
        expect(() => read(bad, true, false),
            throwsA(isA<ArchiveChecksumException>()));
        final file = ZipDecoder().decodeBytes(bad).single;
        expect((file.rawContent! as ZipFile).verifyCrc32(), isFalse);
      });

      test('an unsigned descriptor CRC can equal its optional signature', () {
        final content = Uint8List.fromList([0xac, 0x0a, 0x7a, 0xd5]);
        expect(getCrc32(content), 0x08074b50);
        final encoded = ZipEncoder(streamed: true)
            .encodeBytes(Archive()..add(ArchiveFile.bytes('a', content)));
        final central = ByteData.sublistView(encoded)
            .getUint32(encoded.length - 6, Endian.little);
        for (final signed in [false, true]) {
          final bytes = signed
              ? encoded
              : Uint8List.fromList([
                  ...encoded.sublist(0, central - 16),
                  ...encoded.sublist(central - 12),
                ]);
          if (!signed) {
            ByteData.sublistView(bytes)
                .setUint32(bytes.length - 6, central - 4, Endian.little);
          }
          for (final (verify, throwOnError) in [
            (false, false),
            (true, false),
            (false, true),
          ]) {
            expect(read(bytes, verify, throwOnError), content,
                reason:
                    'signed $signed verify $verify throwOnError $throwOnError');
          }
        }
      });

      test('an error thrown by the callback reaches the caller unchanged', () {
        final two = ZipEncoder().encodeBytes(Archive()
          ..add(ArchiveFile.bytes('a', data))
          ..add(ArchiveFile.bytes('b', data)));
        for (final (verify, throwOnError) in [
          (false, false),
          (true, false),
          (false, true)
        ]) {
          expect(
              () => ZipDecoder().decodeBytes(two,
                  verify: verify,
                  throwOnError: throwOnError,
                  callback: (_) => throw StateError('callback')),
              throwsA(isA<StateError>()),
              reason: 'verify $verify, throwOnError $throwOnError');
        }
      });

      test('damaged structure throws with either flag and not without', () {
        final bad = Uint8List.fromList(zip);
        final central =
            ByteData.sublistView(bad).getUint32(bad.length - 6, Endian.little);
        ByteData.sublistView(bad)
            .setUint32(central + 42, bad.length + 1000, Endian.little);
        expect(() => ZipDecoder().decodeBytes(bad), returnsNormally);
        for (final (verify, throwOnError) in [(true, false), (false, true)]) {
          expect(
              () => read(bad, verify, throwOnError),
              throwsA(allOf(isA<ArchiveException>(),
                  isNot(isA<ArchiveChecksumException>()))),
              reason: 'verify $verify, throwOnError $throwOnError');
        }
      });

      test('entry size must match decompressed content with either flag', () {
        for (final compression in [
          CompressionType.none,
          CompressionType.deflate,
          CompressionType.bzip2
        ]) {
          final encoded = ZipEncoder().encodeBytes(Archive()
            ..add(ArchiveFile.bytes('a', data)..compression = compression));
          final central = ByteData.sublistView(encoded)
              .getUint32(encoded.length - 6, Endian.little);
          for (final size in [data.length - 1, data.length + 1]) {
            final bad = Uint8List.fromList(encoded);
            ByteData.sublistView(bad)
                .setUint32(central + 24, size, Endian.little);
            expect(() => read(bad, false, false), returnsNormally);
            for (final (verify, throwOnError) in [
              (true, false),
              (false, true)
            ]) {
              for (final write in [false, true]) {
                expect(() {
                  final file = ZipDecoder()
                      .decodeBytes(bad,
                          verify: verify, throwOnError: throwOnError)
                      .files
                      .single;
                  if (write) {
                    final output = OutputMemoryStream()..writeByte(17);
                    file.writeContent(output);
                  } else {
                    file.content;
                  }
                }, throwsA(isA<ArchiveException>()),
                    reason:
                        '$compression size $size verify $verify write $write');
              }
            }
          }
        }
      });

      test('strict decoding rejects fields outside their ZIP records', () {
        final central =
            ByteData.sublistView(zip).getUint32(zip.length - 6, Endian.little);
        for (final (offset, width, value) in [
          (26, 2, 65535),
          (28, 2, 65535),
          (central + 28, 2, 65535),
          (central + 30, 2, 65535),
          (central + 32, 2, 65535),
          (zip.length - 10, 4, 0),
          (zip.length - 10, 4, zip.length),
          (zip.length - 12, 2, 2),
          (zip.length - 12, 2, 0),
        ]) {
          final bad = Uint8List.fromList(zip);
          final view = ByteData.sublistView(bad);
          if (width == 2) {
            view.setUint16(offset, value, Endian.little);
          } else {
            view.setUint32(offset, value, Endian.little);
          }
          expect(() => ZipDecoder().decodeBytes(bad), returnsNormally);
          for (final (verify, throwOnError) in [(true, false), (false, true)]) {
            expect(
                () => ZipDecoder().decodeBytes(bad,
                    verify: verify, throwOnError: throwOnError),
                throwsA(isA<ArchiveException>()),
                reason: 'offset $offset value $value verify $verify');
          }
        }
      });

      test('strict decoding rejects a truncated archive comment', () {
        final archive = Archive()
          ..comment = 'archive comment'
          ..add(ArchiveFile.string('a.txt', 'some content'));
        final bytes = ZipEncoder().encodeBytes(archive);
        final directory =
            Directory.systemTemp.createTempSync('archive-zip-comment-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final file = File(p.join(directory.path, 'truncated.zip'));
        for (var cut = 1; cut <= archive.comment!.length; cut++) {
          final truncated = bytes.sublist(0, bytes.length - cut);
          expect(ZipDecoder().decodeBytes(truncated).first.content,
              utf8.encode('some content'));
          file.writeAsBytesSync(truncated);
          for (final (verify, throwOnError) in [(true, false), (false, true)]) {
            expect(
                () => ZipDecoder().decodeBytes(truncated,
                    verify: verify, throwOnError: throwOnError),
                throwsA(isA<ArchiveException>()),
                reason: 'cut $cut verify $verify');
            final input = InputFileStream(file.path, bufferSize: 7);
            try {
              expect(
                  () => ZipDecoder().decodeStream(input,
                      verify: verify, throwOnError: throwOnError),
                  throwsA(isA<ArchiveException>()),
                  reason: 'file cut $cut verify $verify');
            } finally {
              input.closeSync();
            }
          }
        }
      });

      test('strict decoding accepts a 65535-byte archive comment', () {
        final comment = 'a' * 65535;
        final bytes = ZipEncoder().encodeBytes(Archive()
          ..comment = comment
          ..add(ArchiveFile.string('a.txt', 'some content')));
        final directory =
            Directory.systemTemp.createTempSync('archive-zip-comment-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final file = File(p.join(directory.path, 'comment.zip'))
          ..writeAsBytesSync(bytes);
        for (final input in [
          InputMemoryStream(bytes),
          InputFileStream(file.path, bufferSize: 7),
        ]) {
          try {
            final decoder = ZipDecoder();
            final archive = decoder.decodeStream(input, verify: true);
            expect(archive.first.content, utf8.encode('some content'));
            expect(decoder.directory.zipFileComment, comment);
          } finally {
            input.closeSync();
          }
        }
      });

      test('strict decoding rejects an unsupported compression method', () {
        final bad = Uint8List.fromList(zip);
        ByteData.sublistView(bad).setUint16(8, 42, Endian.little);
        expect(() => read(bad, false, false), returnsNormally);
        for (final (verify, throwOnError) in [(true, false), (false, true)]) {
          expect(
              () => read(bad, verify, throwOnError),
              throwsA(allOf(isA<ArchiveException>(),
                  isNot(isA<ArchiveChecksumException>()))));
        }
      });

      test('an entry count past 65535 without zip64 is read', () {
        const count = 65537;
        final out = BytesBuilder();
        final central = BytesBuilder();
        final header = ByteData(46);
        for (var i = 0; i < count; i++) {
          final name = utf8.encode('$i');
          final offset = out.length;
          final local = ByteData(30)
            ..setUint32(0, 0x04034b50, Endian.little)
            ..setUint16(4, 10, Endian.little)
            ..setUint16(26, name.length, Endian.little);
          out
            ..add(local.buffer.asUint8List())
            ..add(name);
          header
            ..setUint32(0, 0x02014b50, Endian.little)
            ..setUint16(4, 20, Endian.little)
            ..setUint16(6, 10, Endian.little)
            ..setUint16(28, name.length, Endian.little)
            ..setUint32(42, offset, Endian.little);
          central
            ..add(Uint8List.fromList(header.buffer.asUint8List()))
            ..add(name);
        }
        final centralOffset = out.length;
        final centralSize = central.length;
        out.add(central.takeBytes());
        final end = ByteData(22)
          ..setUint32(0, 0x06054b50, Endian.little)
          ..setUint16(8, count & 0xffff, Endian.little)
          ..setUint16(10, count & 0xffff, Endian.little)
          ..setUint32(12, centralSize, Endian.little)
          ..setUint32(16, centralOffset, Endian.little);
        out.add(end.buffer.asUint8List());
        final bytes = out.takeBytes();
        for (final (verify, throwOnError) in [(true, false), (false, true)]) {
          expect(
              ZipDecoder()
                  .decodeBytes(bytes,
                      verify: verify, throwOnError: throwOnError)
                  .length,
              count);
        }
      });

      test('an unsupported method fails only its own entry', () async {
        final two = ZipEncoder().encodeBytes(Archive()
          ..add(ArchiveFile.bytes('good', data))
          ..add(ArchiveFile.bytes('odd', data)));
        final view = ByteData.sublistView(two);
        for (var at = 0; at + 46 < two.length; at++) {
          final signature = view.getUint32(at, Endian.little);
          final central = signature == 0x02014b50;
          if (!central && signature != 0x04034b50) {
            continue;
          }
          final nameAt = at + (central ? 46 : 30);
          if (String.fromCharCodes(two, nameAt, nameAt + 3) == 'odd') {
            view.setUint16(at + (central ? 10 : 8), 9, Endian.little);
          }
        }
        for (final (verify, throwOnError) in [
          (false, false),
          (true, false),
          (false, true)
        ]) {
          final files = ZipDecoder()
              .decodeBytes(two, verify: verify, throwOnError: throwOnError)
              .files;
          expect(files.map((f) => f.name), ['good', 'odd']);
          expect(files.first.content, data);
          if (verify || throwOnError) {
            expect(() => files.last.content, throwsA(isA<ArchiveException>()));
          } else {
            expect(files.last.content, isEmpty);
          }
        }
        final dir = Directory.systemTemp.createTempSync('zip_method');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = p.join(dir.path, 'two.zip');
        File(path).writeAsBytesSync(two);
        await extractFileToDisk(path, p.join(dir.path, 'out'));
        expect(File(p.join(dir.path, 'out', 'good')).readAsBytesSync(), data);
        expect(File(p.join(dir.path, 'out', 'odd')).existsSync(), isFalse);
      });

      test('an unsupported method entry encoded again stays unreadable', () {
        final two = ZipEncoder().encodeBytes(Archive()
          ..add(ArchiveFile.bytes('good', data))
          ..add(ArchiveFile.bytes('odd', data)));
        final view = ByteData.sublistView(two);
        for (var at = 0; at + 46 < two.length; at++) {
          final signature = view.getUint32(at, Endian.little);
          final central = signature == 0x02014b50;
          if (!central && signature != 0x04034b50) {
            continue;
          }
          final nameAt = at + (central ? 46 : 30);
          if (String.fromCharCodes(two, nameAt, nameAt + 3) == 'odd') {
            view.setUint16(at + (central ? 10 : 8), 9, Endian.little);
          }
        }
        final before = ZipDecoder()..decodeBytes(two);
        final again = ZipEncoder().encodeBytes(ZipDecoder().decodeBytes(two));
        final after = ZipDecoder();
        final files = after.decodeBytes(again).files;
        expect(files.map((f) => f.name), ['good', 'odd']);
        expect(files.first.content, data);
        expect(files.last.content, isEmpty);
        final odd = after.directory.fileHeaders.last;
        expect(odd.compressionMethod, 9);
        expect(odd.file!.getRawContent(),
            before.directory.fileHeaders.last.file!.getRawContent());
      });

      test('an unsupported method under AE-2 is encoded again as AE-2', () {
        final one = ZipEncoder(password: 'pw')
            .encodeBytes(Archive()..add(ArchiveFile.bytes('odd', data)));
        final view = ByteData.sublistView(one);
        final centralAt = view.getUint32(one.length - 6, Endian.little);
        for (final at in [0, centralAt]) {
          final central = at != 0;
          var extraAt = at +
              (central ? 46 : 30) +
              view.getUint16(at + (central ? 28 : 26), Endian.little);
          final extraEnd =
              extraAt + view.getUint16(at + (central ? 30 : 28), Endian.little);
          view.setUint32(at + (central ? 16 : 14), 0, Endian.little);
          while (extraAt < extraEnd) {
            if (view.getUint16(extraAt, Endian.little) == 0x9901) {
              view.setUint16(extraAt + 4, 2, Endian.little);
              view.setUint16(extraAt + 9, 9, Endian.little);
            }
            extraAt += 4 + view.getUint16(extraAt + 2, Endian.little);
          }
        }
        final before = ZipDecoder()..decodeBytes(one, password: 'pw');
        expect(before.directory.fileHeaders.single.file!.hasCrc32, isFalse);
        expect(
            () => ZipEncoder()
                .encodeBytes(ZipDecoder().decodeBytes(one, password: 'pw')),
            throwsA(isA<ArchiveException>()));
        final again = ZipEncoder(password: 'pw')
            .encodeBytes(ZipDecoder().decodeBytes(one, password: 'pw'));
        final after = ZipDecoder()..decodeBytes(again, password: 'pw');
        final odd = after.directory.fileHeaders.single;
        expect(odd.crc32, 0);
        expect(odd.file!.hasCrc32, isFalse);
        expect(odd.file!.unsupportedMethod, 9);
        expect(
            odd.file!.getStream(decompress: false).toUint8List(),
            before.directory.fileHeaders.single.file!
                .getStream(decompress: false)
                .toUint8List());
      });

      test('an unsupported method encoded again keeps its option bits', () {
        final one = ZipEncoder().encodeBytes(Archive()
          ..add(ArchiveFile.bytes('odd', data)
            ..compression = CompressionType.none));
        final view = ByteData.sublistView(one);
        final centralAt = view.getUint32(one.length - 6, Endian.little);
        for (final at in [0, centralAt]) {
          final central = at != 0;
          final flagsAt = at + (central ? 8 : 6);
          view.setUint16(at + (central ? 10 : 8), 6, Endian.little);
          view.setUint16(flagsAt, view.getUint16(flagsAt, Endian.little) | 6,
              Endian.little);
        }
        final again = ZipEncoder().encodeBytes(ZipDecoder().decodeBytes(one));
        final after = ZipDecoder()..decodeBytes(again);
        final odd = after.directory.fileHeaders.single;
        expect(odd.compressionMethod, 6);
        expect(odd.generalPurposeBitFlag & 6, 6);
        expect(odd.file!.flags & 6, 6);
      });

      test('strict decoding keeps local records before the central directory',
          () {
        final stored = ZipEncoder().encodeBytes(Archive()
          ..add(ArchiveFile.bytes('a', data)
            ..compression = CompressionType.none));
        final central = ByteData.sublistView(stored)
            .getUint32(stored.length - 6, Endian.little);
        for (final field in [26, 28, central + 20]) {
          final bad = Uint8List.fromList(stored);
          final view = ByteData.sublistView(bad);
          if (field < central) {
            view.setUint16(
                field, view.getUint16(field, Endian.little) + 1, Endian.little);
          } else {
            view.setUint32(field, data.length + 1, Endian.little);
          }
          for (final (verify, throwOnError) in [(true, false), (false, true)]) {
            expect(
                () => ZipDecoder().decodeBytes(bad,
                    verify: verify, throwOnError: throwOnError),
                throwsA(isA<ArchiveException>()),
                reason: 'field $field verify $verify');
          }
        }
      });

      test('strict decoding rejects a truncated data descriptor', () {
        final encoded = ZipEncoder(streamed: true)
            .encodeBytes(Archive()..add(ArchiveFile.bytes('a', data)));
        expect(
            ByteData.sublistView(encoded).getUint16(6, Endian.little) & 8, 8);
        final central = ByteData.sublistView(encoded)
            .getUint32(encoded.length - 6, Endian.little);
        for (final missing in [1, 4, 8, 12, 16]) {
          final bad = Uint8List.fromList([
            ...encoded.sublist(0, central - missing),
            ...encoded.sublist(central),
          ]);
          ByteData.sublistView(bad)
              .setUint32(bad.length - 6, central - missing, Endian.little);
          for (final (verify, throwOnError) in [(true, false), (false, true)]) {
            expect(
                () => ZipDecoder().decodeBytes(bad,
                    verify: verify, throwOnError: throwOnError),
                throwsA(isA<ArchiveException>()),
                reason: 'missing $missing verify $verify');
          }
        }
      });

      test('an empty password encrypts and decrypts an entry', () async {
        final key = ZipFile.deriveKey(
            '', Uint8List.fromList(List.generate(16, (i) => i)));
        expect(
            key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
            '18d5ccf5e2756473f72fb16646195467a1467e252587c74af37ac193669a0fdcc'
            '42c93e4e57659c876a30c98bcb3353021c60898bf7c68296c898150e2f0d9973bc9');
        for (final streamed in [false, true]) {
          final archive = Archive()..add(ArchiveFile.bytes('a', data));
          final encoded =
              ZipEncoder(password: '', streamed: streamed).encodeBytes(archive);
          final converted = await Stream.fromIterable(archive.files)
              .transform(ZipCodec(password: '', streamed: streamed).encoder)
              .fold(<int>[], (bytes, piece) => bytes..addAll(piece));
          for (final bytes in [encoded, converted]) {
            for (final (verify, throwOnError) in [
              (false, false),
              (true, false),
              (false, true),
            ]) {
              expect(
                  ZipDecoder()
                      .decodeBytes(bytes,
                          password: '',
                          verify: verify,
                          throwOnError: throwOnError)
                      .files
                      .single
                      .content,
                  data);
              for (final password in [null, 'wrong']) {
                expect(
                    () => ZipDecoder()
                        .decodeBytes(bytes,
                            password: password,
                            verify: verify,
                            throwOnError: throwOnError)
                        .files
                        .single
                        .content,
                    throwsA(isA<ArchivePasswordException>()));
              }
            }
          }
        }
      });

      test('a wrong or missing password throws regardless of flags', () {
        for (final name in ['aes256.zip', 'zipCrypto.zip']) {
          final bytes = File('test/_data/zip/$name').readAsBytesSync();
          for (final password in ['wrong', null]) {
            for (final (verify, throwOnError) in [
              (false, false),
              (true, false),
              (false, true)
            ]) {
              expect(
                  () => ZipDecoder()
                      .decodeBytes(bytes,
                          verify: verify,
                          throwOnError: throwOnError,
                          password: password)
                      .files
                      .where((f) => f.isFile && f.size > 0)
                      .map((f) => f.content)
                      .toList(),
                  throwsA(isA<ArchivePasswordException>()),
                  reason: '$name, password $password, verify $verify, '
                      'throwOnError $throwOnError');
            }
          }
        }
      });

      test('extractFileToDisk throws for a wrong or missing password',
          () async {
        final dir = Directory.systemTemp.createTempSync('zip_password');
        addTearDown(() => dir.deleteSync(recursive: true));
        for (final name in ['aes256.zip', 'zipCrypto.zip']) {
          for (final password in ['wrong', null]) {
            await expectLater(
                extractFileToDisk(
                    'test/_data/zip/$name', p.join(dir.path, '$name$password'),
                    password: password),
                throwsA(isA<ArchivePasswordException>()),
                reason: '$name, password $password');
          }
        }
      });

      test('extractArchiveToDisk throws for a wrong or missing password',
          () async {
        final dir = Directory.systemTemp.createTempSync('zip_password');
        addTearDown(() => dir.deleteSync(recursive: true));
        for (final name in ['aes256.zip', 'zipCrypto.zip']) {
          final bytes = File('test/_data/zip/$name').readAsBytesSync();
          for (final password in ['wrong', null]) {
            final out = p.join(dir.path, '$name$password');
            await expectLater(
                extractArchiveToDisk(
                    ZipDecoder().decodeBytes(bytes, password: password), out),
                throwsA(isA<ArchivePasswordException>()),
                reason: '$name, password $password');
            expect(
                () => extractArchiveToDiskSync(
                    ZipDecoder().decodeBytes(bytes, password: password),
                    '${out}sync'),
                throwsA(isA<ArchivePasswordException>()),
                reason: '$name, password $password');
            for (final path in [out, '${out}sync']) {
              expect(
                  Directory(path)
                      .listSync(recursive: true)
                      .whereType<File>()
                      .toList(),
                  isEmpty,
                  reason: path);
            }
          }
        }
      });
    });

    test('verify refuses a local header offset past the end', () {
      final bytes = ZipEncoder()
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'hello')));
      final central = ByteData.sublistView(bytes)
          .getUint32(bytes.length - 6, Endian.little);
      final damaged = Uint8List.fromList(bytes);
      ByteData.sublistView(damaged)
          .setUint32(central + 42, bytes.length + 1000, Endian.little);
      expect(() => ZipDecoder().decodeBytes(damaged, verify: true),
          throwsA(isA<ArchiveException>()));
    });

    test('a zip behind a prefix its offsets leave out reads its entries', () {
      final bytes = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.string('a.txt', 'hello'))
        ..add(ArchiveFile.string('b.txt', 'world')));
      final prefixed =
          Uint8List.fromList([...List.filled(100, 0x4d), ...bytes]);
      for (final verify in [false, true]) {
        final archive = ZipDecoder().decodeBytes(prefixed, verify: verify);
        expect(archive.files.map((f) => f.name), ['a.txt', 'b.txt'],
            reason: 'verify $verify');
        expect(archive.files.first.content, 'hello'.codeUnits,
            reason: 'verify $verify');
      }
    });

    test('a wrong central directory offset reads like unzip, verify refuses',
        () {
      final bytes = File('test/_data/test.zip').readAsBytesSync();
      final want = ZipDecoder().decodeBytes(bytes).files;
      final damaged = Uint8List.fromList(bytes);
      damaged[damaged.length - 6] = 0;
      final archive = ZipDecoder().decodeBytes(damaged);
      expect(archive.files.map((f) => f.name), want.map((f) => f.name));
      expect(archive.files.last.content, want.last.content);
      expect(() => ZipDecoder().decodeBytes(damaged, verify: true),
          throwsA(isA<ArchiveException>()));
    });

    test('verify refuses a data descriptor past the end of the file', () {
      final bytes = File('test/_data/zip/dd.zip').readAsBytesSync();
      final damaged = Uint8List.fromList(bytes);
      damaged[28] = 113;
      expect(() => ZipDecoder().decodeBytes(damaged, verify: true),
          throwsA(isA<ArchiveException>()));
    });

    test('a zip64 behind a prefix its offsets leave out reads its entries', () {
      final bytes = File('test/_data/zip/zip64_archive.zip').readAsBytesSync();
      final want = ZipDecoder().decodeBytes(bytes, verify: true).files;
      final prefixed =
          Uint8List.fromList([...List.filled(100, 0x4d), ...bytes]);
      final archive = ZipDecoder().decodeBytes(prefixed, verify: true);
      expect(archive.files.map((f) => f.name), want.map((f) => f.name));
      for (var i = 0; i < want.length; i++) {
        expect(archive.files[i].content, want[i].content);
      }
    });

    test('encoding a decoded archive into a file leaves its entries readable',
        () {
      final bytes = File('test/_data/test.zip').readAsBytesSync();
      final want = [
        for (final f in ZipDecoder().decodeBytes(bytes).files) f.content
      ];
      final archive = ZipDecoder().decodeBytes(bytes);
      final path = p.join(testOutputPath, 'reencoded_into_file.zip');
      final output = OutputFileStream(path);
      ZipEncoder().encodeStream(archive, output);
      output.closeSync();
      expect([for (final f in archive.files) f.content], want);
      final back =
          ZipDecoder().decodeBytes(File(path).readAsBytesSync(), verify: true);
      expect([for (final f in back.files) f.content], want);
    });

    test('verify passes an AES zip without a stored CRC', () {
      for (final (name, password) in [
        ('aes256.zip', '12345'),
        ('lzma_aes.zip', 'secret')
      ]) {
        final archive = ZipDecoder().decodeBytes(
            File('test/_data/zip/$name').readAsBytesSync(),
            password: password,
            verify: true);
        for (final f in archive.files.where((f) => f.isFile)) {
          expect(() => f.writeContent(OutputMemoryStream()), returnsNormally,
              reason: '$name ${f.name}');
        }
      }
    });

    test('verifyCrc32 answers false for a damaged entry decoded with verify',
        () {
      final bytes = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.noCompress('a.txt', 5, utf8.encode('hello'))));
      bytes[latin1.decode(bytes).indexOf('hello')] ^= 0x20;
      for (final verify in [false, true]) {
        final file = ZipDecoder()
            .decodeBytes(bytes, verify: verify)
            .findFile('a.txt')!
            .rawContent as ZipFile;
        expect(file.verifyCrc32(), isFalse, reason: 'verify $verify');
      }
    });

    test('an AES entry read without a password throws ArchiveException', () {
      final bytes = ZipEncoder(password: 'secret')
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'hello')));
      final entry = ZipDecoder().decodeBytes(bytes).findFile('a.txt')!;
      expect(entry.readBytes, throwsA(isA<ArchiveException>()));
    });

    test('an AES entry read again with a wrong password throws again', () {
      final bytes = ZipEncoder(password: 'secret').encodeBytes(
          Archive()..add(ArchiveFile.string('a.txt', 'hello' * 100)));
      for (final password in [null, 'wrong']) {
        for (final (verify, throwOnError) in [
          (false, false),
          (false, true),
          (true, false)
        ]) {
          final entry = ZipDecoder()
              .decodeBytes(bytes,
                  password: password,
                  verify: verify,
                  throwOnError: throwOnError)
              .findFile('a.txt')!;
          for (var read = 0; read < 3; read++) {
            final reason = 'password $password, verify $verify, '
                'throwOnError $throwOnError, read $read';
            expect(entry.readBytes, throwsA(isA<ArchivePasswordException>()),
                reason: reason);
            expect(() => entry.writeContent(OutputMemoryStream()),
                throwsA(isA<ArchivePasswordException>()),
                reason: reason);
          }
        }
      }
    });

    test('a ZipCrypto entry read again with a wrong password throws again',
        testOn: 'vm', () {
      final bytes = File('test/_data/zip/zipCrypto.zip').readAsBytesSync();
      for (final (verify, throwOnError) in [
        (false, false),
        (false, true),
        (true, false)
      ]) {
        final entry = ZipDecoder()
            .decodeBytes(bytes,
                password: 'wrong', verify: verify, throwOnError: throwOnError)
            .findFile('hello.txt')!;
        for (var read = 0; read < 3; read++) {
          final reason =
              'verify $verify, throwOnError $throwOnError, read $read';
          expect(entry.readBytes, throwsA(isA<ArchivePasswordException>()),
              reason: reason);
          expect(() => entry.writeContent(OutputMemoryStream()),
              throwsA(isA<ArchivePasswordException>()),
              reason: reason);
        }
      }
    });

    test('an entry with a damaged local header keeps its central name', () {
      final bytes = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('one.txt', 'first'.codeUnits))
        ..add(ArchiveFile.bytes('two.txt', 'second'.codeUnits))
        ..add(ArchiveFile.bytes('three.txt', 'third'.codeUnits)));
      final decoder = ZipDecoder()..decodeBytes(bytes);
      bytes[decoder.directory.fileHeaders[1].localHeaderOffset] ^= 0xff;
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.map((f) => f.name),
          ['one.txt', 'two.txt', 'three.txt']);
      final two = archive.findFile('two.txt')!;
      expect(two.size, 'second'.length);
      expect(two.crc32, getCrc32('second'.codeUnits));
      expect(archive.findFile('one.txt')!.content, 'first'.codeUnits);
      expect(archive.findFile('three.txt')!.content, 'third'.codeUnits);
    });

    test('a duplicate name keeps the CRC of the content it holds', () {
      final output = OutputMemoryStream();
      ZipEncoder()
        ..startEncode(output)
        ..add(ArchiveFile.bytes('a.txt', 'first'.codeUnits))
        ..add(ArchiveFile.bytes('a.txt', 'second and longer'.codeUnits))
        ..endEncode();
      final entry =
          ZipDecoder().decodeBytes(output.getBytes()).findFile('a.txt')!;
      final content = entry.readBytes()!;
      expect(content, 'second and longer'.codeUnits);
      expect(entry.size, content.length);
      expect(entry.crc32, getCrc32(content));
      final again = ZipDecoder().decodeBytes(
          ZipEncoder().encodeBytes(ZipDecoder().decodeBytes(output.getBytes())),
          verify: true);
      expect(again.findFile('a.txt')!.readBytes(), content);
    });

    test('an empty entry asked for xz is stored as 7-Zip stores it',
        testOn: 'vm', () async {
      Archive archive() => Archive()
        ..add(ArchiveFile.bytes('empty.bin', [])
          ..compression = CompressionType.xz)
        ..add(ArchiveFile.stream('stream.bin', InputMemoryStream(Uint8List(0)))
          ..compression = CompressionType.xz)
        ..add(ArchiveFile.bytes('one.bin', [0x61])
          ..compression = CompressionType.xz);
      final encoded = {
        'encodeBytes': ZipEncoder().encodeBytes(archive()),
        'streamed': ZipEncoder(streamed: true).encodeBytes(archive()),
        'password': ZipEncoder(password: 'pw').encodeBytes(archive()),
        'converter': Uint8List.fromList(
            await Stream.fromIterable(archive().files)
                .transform(zipCodec.encoder)
                .expand((b) => b)
                .toList()),
      };
      for (final MapEntry(key: name, value: bytes) in encoded.entries) {
        final decoder = ZipDecoder();
        final files = decoder.decodeBytes(bytes, password: 'pw', verify: true);
        final methods = [
          for (final header in decoder.directory.fileHeaders)
            header.file!.compressionMethod
        ];
        expect(methods,
            [CompressionType.none, CompressionType.none, CompressionType.xz],
            reason: name);
        expect(files.map((f) => f.content.length), [0, 0, 1], reason: name);
      }
    });

    test('an AES entry too short for its header throws on every read',
        testOn: 'vm', () {
      final bytes = ZipEncoder(password: 'pw').encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.txt', [0x41])
          ..compression = CompressionType.none));
      final data = ByteData.sublistView(bytes);
      final central = data.getUint32(bytes.length - 6, Endian.little);
      data
        ..setUint32(18, 20, Endian.little)
        ..setUint32(central + 20, 20, Endian.little);
      for (final (verify, throwOnError) in [(false, true), (true, false)]) {
        final archive = ZipDecoder().decodeBytes(bytes,
            password: 'pw', verify: verify, throwOnError: throwOnError);
        for (var read = 0; read < 3; read++) {
          final reason =
              'verify $verify, throwOnError $throwOnError, read $read';
          expect(archive.first.readBytes, throwsA(isA<ArchiveException>()),
              reason: reason);
          expect(() => ZipEncoder().encodeBytes(archive),
              throwsA(isA<ArchiveException>()),
              reason: reason);
        }
      }
    });

    test('empty directory', () {
      final archive = Archive();
      archive.add(ArchiveFile.directory('empty'));
      final encodedBytes = ZipEncoder().encodeBytes(archive);
      File(p.join(testOutputPath, 'empty_directory.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(encodedBytes);
      final archiveDecoded = ZipDecoder().decodeBytes(encodedBytes);
      expect(archiveDecoded.length, 1);
      expect(archiveDecoded[0].isFile, false);
      expect(archiveDecoded[0].name, 'empty/');
    });

    test('file decode utf file', () {
      var bytes = File(p.join('test/_data/zip/utf.zip')).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(archive.length, equals(5));
    });

    test('file stream encode', () {
      final fileStream = InputFileStream('test/_data/cat.jpg');
      final archiveFile = ArchiveFile.stream('cat.jpg', fileStream);
      final archive = Archive()..add(archiveFile);
      final encodedBytes = ZipEncoder().encodeBytes(archive);
      File(p.join(testOutputPath, 'file_stream.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(encodedBytes);
      final archiveDecoded = ZipDecoder().decodeBytes(encodedBytes);
      expect(archiveDecoded.length, 1);
    });

    test('file encoding zip file', () {
      final originalFileName = 'fileöäüÖÄÜß.txt';
      final bytes = Utf8Codec().encode('test');
      final archive = Archive();
      archive.add(ArchiveFile.bytes(originalFileName, bytes));

      archive.add(ArchiveFile.directory('foo'));
      archive.add(ArchiveFile.string('foo/bar.txt', '123'));

      var encodedBytes = ZipEncoder().encodeBytes(archive);

      File(p.join(testOutputPath, 'zip_encoder.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(encodedBytes);

      final archiveDecoded = ZipDecoder().decodeBytes(encodedBytes);
      expect(archiveDecoded.length, 3);

      final decodedFile = archiveDecoded[0];

      expect(decodedFile.name, originalFileName);
    });

    test('zip64', () {
      var bytes =
          File(p.join('test/_data/zip/zip64_archive.zip')).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);
      expect(archive.length, equals(3));
      expect(archive[0].size, equals(3136));
    });

    // Info-ZIP writes this to a pipe. The sizes behind the data are 8 bytes
    // each with zip64. unzip and Python take the sizes from the central
    // directory and never read these
    test('zip64 sizes behind the data', () async {
      final text =
          List.filled(10, 'the quick brown fox jumps over the lazy dog\n')
              .join()
              .codeUnits;
      final path = p.join('test/_data/zip/zip64_descriptor.zip');
      final input = InputFileStream(path);
      for (final archive in [
        ZipDecoder().decodeBytes(File(path).readAsBytesSync(), verify: true),
        ZipDecoder().decodeStream(input, verify: true),
      ]) {
        final file = archive.files.single;
        expect(file.name, '-');
        expect(file.size, 440);
        expect(file.content, text);
      }
      await input.close();
    });

    // The entry says 5 GB and holds three bytes. Nothing allocates 5 GB. A
    // zip64 extra field needs version 45 in both headers
    test('a stored entry over 4 GB needs version 45', () {
      final output = OutputMemoryStream();
      ZipEncoder()
        ..startEncode(output)
        ..add(ArchiveFile.file('a', 5000000000, FileContentMemory([1, 2, 3]))
          ..compression = CompressionType.none)
        ..endEncode();
      final bytes = output.getBytes();
      final view = ByteData.sublistView(bytes);

      expect(view.getUint32(22, Endian.little), 0xFFFFFFFF);
      expect(view.getUint16(30 + 1, Endian.little), 1);
      expect(view.getUint16(4, Endian.little), 45);

      var central = 0;
      while (view.getUint32(central, Endian.little) != 0x02014b50) {
        central++;
      }
      expect(view.getUint16(central + 6, Endian.little), 45);
    });

    test('data types', () {
      final archive = Archive();
      archive.add(ArchiveFile.bytes('uint8list', Uint8List(2)));
      archive.add(ArchiveFile.bytes('list_int', Uint8List.fromList([1, 2])));
      archive.add(ArchiveFile.typedData(
          'float32list', Float32List.fromList([3.0, 4.0])));
      archive.add(ArchiveFile.string('string', 'hello'));
      final zipData = ZipEncoder().encodeBytes(archive);
      File('$testOutputPath/zip64.zip')
        ..createSync(recursive: true)
        ..writeAsBytesSync(zipData);

      final archive2 = ZipDecoder().decodeBytes(zipData);
      expect(archive2.length, equals(archive.length));
    });

    test('encode', () {
      final archive = Archive();
      final bdata = 'hello world';
      final bytes = Uint8List.fromList(bdata.codeUnits);
      final name = 'abc.txt';
      final afile = ArchiveFile.bytes(name, bytes);
      archive.add(afile);

      final zipData = ZipEncoder().encodeBytes(archive);

      File(p.join(testOutputPath, 'uncompressed.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(zipData);

      final arc = ZipDecoder().decodeBytes(zipData, verify: true);
      expect(arc.length, equals(1));
      final arcData = arc[0].readBytes()!;
      expect(arcData.length, equals(bytes.length));
      for (var i = 0; i < arcData.length; ++i) {
        expect(arcData[i], equals(bytes[i]));
      }
    });

    test('encode with timestamp', () {
      final archive = Archive();
      var bdata = 'some file data';
      var bytes = Uint8List.fromList(bdata.codeUnits);
      final name = 'somefile.txt';
      final afile = ArchiveFile.bytes(name, bytes);
      archive.add(afile);

      var zipData = ZipEncoder().encodeBytes(archive,
          modified: DateTime.utc(2010, DateTime.january, 1));

      File(p.join(testOutputPath, 'uncompressed.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(zipData);

      var arc = ZipDecoder().decodeBytes(zipData, verify: true);
      expect(arc.length, equals(1));
      var arcData = arc[0].readBytes()!;
      expect(arcData.length, equals(bdata.length));
      for (var i = 0; i < arcData.length; ++i) {
        expect(arcData[i], equals(bdata.codeUnits[i]));
      }
      expect(arc[0].lastModDateTime, equals(DateTime(2010)));
    });

    test('zipCrypto', () {
      var file = File(p.join('test/_data/zip/zipCrypto.zip'));
      var bytes = file.readAsBytesSync();
      final archive =
          ZipDecoder().decodeBytes(bytes, verify: false, password: '12345');

      expect(archive.length, equals(2));

      for (var i = 0; i < archive.length; ++i) {
        var file = File(p.join('test/_data/zip/${archive[i].name}'));
        var bytes = file.readAsBytesSync();
        var content = archive[i].readBytes()!;
        expect(bytes.length, equals(content.length));
        bool diff = false;
        for (int i = 0; i < bytes.length; ++i) {
          if (bytes[i] != content[i]) {
            diff = true;
            break;
          }
        }
        expect(diff, equals(false));
      }
    });

    test('aes256', () {
      final stream = InputFileStream('test/_data/zip/aes256.zip');
      final archive = ZipDecoder().decodeStream(stream, password: '12345');

      expect(archive.length, equals(2));
      for (var i = 0; i < archive.length; ++i) {
        final file = File(p.join('test/_data/zip/${archive[i].name}'));
        final bytes = file.readAsBytesSync();
        final content = archive[i].readBytes()!;
        expect(content.length, equals(bytes.length));
        bool diff = false;
        for (int i = 0; i < bytes.length; ++i) {
          if (bytes[i] != content[i]) {
            diff = true;
            break;
          }
        }
        expect(diff, equals(false));
      }
    });

    test('decrypting leaves the input bytes as they were', () {
      for (final name in ['aes256.zip', 'zipCrypto.zip']) {
        final bytes = File('test/_data/zip/$name').readAsBytesSync();
        final original = Uint8List.fromList(bytes);
        for (var pass = 0; pass < 2; pass++) {
          final archive = ZipDecoder().decodeBytes(bytes, password: '12345');
          for (final f in archive.files) {
            expect(f.readBytes(), isNotNull, reason: '$name ${f.name}');
          }
        }
        expect(bytes, original, reason: name);
      }
    });

    test('a stored entry stays readable after decompressing to a file', () {
      final expected = 'stored content'.codeUnits;
      final bytes = ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.txt', expected)
          ..compression = CompressionType.none));
      final entry = ZipDecoder().decodeBytes(bytes).files.single;
      final directory =
          Directory.systemTemp.createTempSync('zip_stored_lifetime_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/out');
      final output = OutputFileStream(file.path, bufferSize: 3);
      entry.decompress(output);
      output.closeSync();
      expect(file.readAsBytesSync(), expected);
      expect(entry.content, expected);
    });

    test('encrypting leaves the source zip and stored bytes as they were', () {
      final bytes = File('test/_data/zip/test.zip').readAsBytesSync();
      final original = Uint8List.fromList(bytes);
      final archive = ZipDecoder().decodeBytes(bytes);
      final contents = [for (final f in archive.files) f.readBytes()!];
      final archiveUntouched = ZipDecoder().decodeBytes(bytes);
      final encrypted = ZipEncoder(password: 'pw')
          .encodeBytes(archiveUntouched, autoClose: false);
      expect(bytes, original);
      for (var i = 0; i < contents.length; i++) {
        expect(archiveUntouched.files[i].readBytes(), contents[i]);
        expect(
            ZipDecoder().decodeBytes(bytes).files[i].readBytes(), contents[i]);
      }
      for (final f
          in ZipDecoder().decodeBytes(encrypted, password: 'pw').files) {
        expect(f.crc32, getCrc32(f.readBytes()!), reason: f.name);
      }

      final data =
          Uint8List.fromList(List<int>.generate(1000, (i) => i & 0xff));
      final stored = Uint8List.fromList(data);
      ZipEncoder(password: 'pw').encodeBytes(Archive()
        ..add(ArchiveFile.bytes('a.bin', data)
          ..compression = CompressionType.none));
      expect(data, stored);
    });

    test('a non-ASCII password opens zips from other tools and from before',
        () {
      const password = 'pässwort';
      const expected = {
        'password_utf8_aes.zip': 'hello\n',
        'password_utf8_zipcrypto.zip': 'hello\n',
        'password_old_aes.zip': 'hello utf8 password\n',
        'password_old_zipcrypto.zip': 'hello crc check\n',
      };
      for (final MapEntry(key: name, value: content) in expected.entries) {
        final entry = ZipDecoder()
            .decodeBytes(File('test/_data/zip/$name').readAsBytesSync(),
                password: password)
            .files
            .single;
        expect(utf8.decode(entry.readBytes()!), content, reason: name);
      }

      final encoded = ZipEncoder(password: password)
          .encodeBytes(Archive()..add(ArchiveFile.string('a.txt', 'hello')));
      final utf8Bytes = String.fromCharCodes(utf8.encode(password));
      for (final key in [password, utf8Bytes]) {
        expect(
            utf8.decode(ZipDecoder()
                .decodeBytes(encoded, password: key)
                .files
                .single
                .readBytes()!),
            'hello',
            reason: key);
      }
      expect(
          () => ZipDecoder()
              .decodeBytes(encoded, password: 'wrong')
              .files
              .single
              .readBytes(),
          throwsA(isA<ArchiveException>()));
    });

    test('a UTF-8 ZipCrypto password passes the CRC when no check byte matches',
        () {
      final bytes =
          File('test/_data/zip/password_utf8_zipcrypto.zip').readAsBytesSync();
      int at(List<int> signature) {
        for (var i = 0;; i++) {
          if (bytes[i] == signature[0] &&
              bytes[i + 1] == signature[1] &&
              bytes[i + 2] == signature[2] &&
              bytes[i + 3] == signature[3]) {
            return i;
          }
        }
      }

      bytes[at([0x50, 0x4b, 0x03, 0x04]) + 11] ^= 0xff;
      bytes[at([0x50, 0x4b, 0x01, 0x02]) + 13] ^= 0xff;
      final entry =
          ZipDecoder().decodeBytes(bytes, password: 'pässwort').files.single;
      expect(utf8.decode(entry.readBytes()!), 'hello\n');
    });

    test('a legacy ZipCrypto password survives a UTF-8 verifier collision', () {
      final bytes = base64.decode(
          'UEsDBBQAAQAAAAAAAABcAaBLHAAAABAAAAAFAAAAYS50eHRLpfb7XA4bVEMsFBKkMCd8r6nh'
          '6FGZsOwRBuLDUEsBAhQAFAABAAAAAAAAAFwBoEscAAAAEAAAAAUAAAAAAAAAAAAAAAAAAAAA'
          'AGEudHh0UEsFBgAAAAABAAEAMwAAAD8AAAAAAA==');
      for (final verify in [false, true]) {
        final archive = ZipDecoder()
            .decodeBytes(bytes, password: 'pässwort', verify: verify);
        expect(archive.files.single.content, 'hello crc check\n'.codeUnits,
            reason: 'verify=$verify');
      }
    });

    test('a missing ZipCrypto password throws when the check byte matches', () {
      final bytes = base64.decode(
          'UEsDBBQAAQAAAAAAIQAgMDo2EgAAAAYAAAAFAAAAYS50eHSrT4I8+1ClWK6R6UBEMvz9'
          'Gu9QSwECFAAUAAEAAAAAACEAIDA6NhIAAAAGAAAABQAAAAAAAAAAAAAAAAAAAAAAYS50'
          'eHRQSwUGAAAAAAEAAQAzAAAANQAAAAAA');
      expect(
          ZipDecoder()
              .decodeBytes(bytes, password: 'secret')
              .files
              .single
              .readBytes(),
          'hello\n'.codeUnits);
      for (final (verify, throwOnError) in [
        (false, false),
        (true, false),
        (false, true)
      ]) {
        expect(
            () => ZipDecoder()
                .decodeBytes(bytes, verify: verify, throwOnError: throwOnError)
                .files
                .single
                .readBytes(),
            throwsA(isA<ArchivePasswordException>()),
            reason: 'verify $verify, throwOnError $throwOnError');
      }
    });

    test('an AES zip without a stored CRC passes verifyCrc32', () {
      for (final (name, password) in [
        ('aes256.zip', '12345'),
        ('lzma_aes.zip', 'secret')
      ]) {
        final archive = ZipDecoder().decodeBytes(
            File('test/_data/zip/$name').readAsBytesSync(),
            password: password);
        for (final f in archive.files.where((f) => f.isFile)) {
          expect((f.rawContent! as ZipFile).verifyCrc32(), isTrue,
              reason: '$name ${f.name}');
        }
      }

      final bytes = File('test/_data/zip/aes256.zip').readAsBytesSync();
      final decoder = ZipDecoder()..decodeBytes(bytes, password: '12345');
      final header = decoder.directory.fileHeaders
          .firstWhere((h) => h.filename == 'readme.notzip');
      final local = header.localHeaderOffset;
      final data = local +
          30 +
          (bytes[local + 26] | bytes[local + 27] << 8) +
          (bytes[local + 28] | bytes[local + 29] << 8);
      bytes[data + 18 + (header.compressedSize - 28) ~/ 2] ^= 0xff;
      final tampered = ZipDecoder()
          .decodeBytes(bytes, password: '12345')
          .files
          .firstWhere((f) => f.name == 'readme.notzip');
      expect(() => (tampered.rawContent! as ZipFile).verifyCrc32(),
          throwsA(isA<ArchiveChecksumException>()));
    });

    test('an AES zip encoded again has the CRC of its content', () {
      for (final (name, password) in [
        ('aes256.zip', '12345'),
        ('lzma_aes.zip', 'secret')
      ]) {
        for (final newPassword in [null, 'new password']) {
          final decoded = ZipDecoder().decodeBytes(
              File('test/_data/zip/$name').readAsBytesSync(),
              password: password);
          final encoded =
              ZipEncoder(password: newPassword).encodeBytes(decoded);
          final again =
              ZipDecoder().decodeBytes(encoded, password: newPassword);
          for (final f in again.files.where((f) => f.isFile)) {
            expect(f.crc32, getCrc32(f.readBytes()!),
                reason: '$name ${f.name} $newPassword');
          }
        }
      }
    });

    test('password', () {
      var file = File(p.join('test/_data/zip/password_zipcrypto.zip'));
      var bytes = file.readAsBytesSync();

      var b = File(p.join('test/_data/zip/hello.txt'));
      final bBytes = b.readAsBytesSync();

      final archive =
          ZipDecoder().decodeBytes(bytes, verify: true, password: 'test1234');
      expect(archive.length, equals(1));

      for (var i = 0; i < archive.length; ++i) {
        final zBytes = archive[i].readBytes()!;
        if (archive[i].name == 'hello.txt') {
          compareBytes(zBytes, bBytes);
        } else {
          throw TestFailure('Invalid file found');
        }
      }
    });

    test('decode zip bzip2', () {
      var file = File(p.join('test/_data/zip/zip_bzip2.zip'));
      var bytes = file.readAsBytesSync();

      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(archive.length, equals(2));

      for (final f in archive) {
        final c = f.getContent()?.toUint8List();
        expect(c, isNotNull);
      }
    });

    Map<String, List<int>> lzmaExpected() {
      var state = 3;
      final binary = List<int>.generate(70000, (_) {
        state = (state * 1103515245 + 12345) & 0x7fffffff;
        return (state >> 16) % 5 == 0 ? 0x41 : (state >> 8) & 0xff;
      });
      return {
        'a.txt': utf8.encode('hello lzma\n' * 200),
        'b.bin': binary,
        'empty.txt': <int>[],
        'dir/c.txt': utf8.encode('nested file\n' * 50),
      };
    }

    void expectLzmaArchive(Archive archive) {
      final want = lzmaExpected();
      final files = {
        for (final f in archive.files)
          if (f.isFile) f.name: f
      };
      expect(files.keys.toSet(), want.keys.toSet());
      for (final entry in want.entries) {
        expect(files[entry.key]!.content, entry.value, reason: entry.key);
      }
      for (final name in ['a.txt', 'b.bin', 'dir/c.txt']) {
        expect(files[name]!.compression, CompressionType.lzma, reason: name);
      }
    }

    for (final (name, password) in [('lzma', null), ('lzma_aes', 'secret')]) {
      test('decode zip $name', () {
        final path = 'test/_data/zip/$name.zip';
        expectLzmaArchive(ZipDecoder().decodeBytes(File(path).readAsBytesSync(),
            verify: true, password: password));
        final input = InputFileStream(path);
        expectLzmaArchive(
            ZipDecoder().decodeStream(input, verify: true, password: password));
        input.closeSync();
      });
    }

    test('LZMA dictionary properties honor the 4096-byte minimum', () {
      final nearBytes = File('test/_data/zip/lzma_near.zip').readAsBytesSync();
      final farBytes = File('test/_data/zip/lzma_far.zip').readAsBytesSync();
      for (final nearMatches in [true, false]) {
        final expected = nearMatches
            ? List<int>.generate(1024, (i) => i % 64)
            : List<int>.generate(
                24576, (i) => i >= 8192 && i < 16384 ? 64 + i % 64 : i % 64);
        final sizes =
            nearMatches ? [0, 1, 63, 64, 4095, 4096] : [0, 4096, 8192, 16384];
        for (final dictionarySize in sizes) {
          final bytes = Uint8List.fromList(nearMatches ? nearBytes : farBytes);
          final view = ByteData.sublistView(bytes);
          final payload = 30 +
              view.getUint16(26, Endian.little) +
              view.getUint16(28, Endian.little);
          view.setUint32(payload + 5, dictionarySize, Endian.little);
          if (!nearMatches && dictionarySize != 16384) {
            expect(() => ZipDecoder().decodeBytes(bytes).files.single.content,
                returnsNormally);
          }
          for (final (verify, throwOnError) in [(false, true), (true, false)]) {
            for (final writeContent in [false, true]) {
              Uint8List read() {
                final file = ZipDecoder()
                    .decodeBytes(bytes,
                        verify: verify, throwOnError: throwOnError)
                    .files
                    .single;
                if (!writeContent) {
                  return file.content;
                }
                final output = OutputMemoryStream();
                file.writeContent(output);
                return output.getBytes();
              }

              final reason =
                  'near $nearMatches, dictionary $dictionarySize, verify $verify, write $writeContent';
              if (nearMatches || dictionarySize == 16384) {
                expect(read(), expected, reason: reason);
              } else {
                expect(read, throwsA(isA<ArchiveException>()), reason: reason);
              }
            }
          }
        }
      }
    });

    test('LZMA entries grow past 2 MiB without exceeding their declared size',
        () {
      final encoded = File('test/_data/zip/lzma_2mib.zip').readAsBytesSync();
      final expected = Uint8List(2 * 1024 * 1024 + 273)
        ..fillRange(0, 2 * 1024 * 1024 + 273, 97);
      for (final missing in [0, 1]) {
        final bytes = Uint8List.fromList(encoded);
        final view = ByteData.sublistView(bytes);
        final central = view.getUint32(bytes.length - 6, Endian.little);
        view.setUint32(22, expected.length - missing, Endian.little);
        view.setUint32(central + 24, expected.length - missing, Endian.little);
        if (missing == 1) {
          expect(() => ZipDecoder().decodeBytes(bytes).files.single.content,
              returnsNormally);
        }
        for (final (verify, throwOnError) in [(false, true), (true, false)]) {
          for (final writeContent in [false, true]) {
            Uint8List read() {
              final file = ZipDecoder()
                  .decodeBytes(bytes,
                      verify: verify, throwOnError: throwOnError)
                  .files
                  .single;
              if (!writeContent) {
                return file.content;
              }
              final output = OutputMemoryStream();
              file.writeContent(output);
              return output.getBytes();
            }

            if (missing == 0) {
              expect(read(), expected);
            } else {
              expect(read, throwsA(isA<ArchiveException>()));
            }
          }
        }
      }
    });

    test('an LZMA size claim does not allocate before validating the data', () {
      for (final property in [225, 93]) {
        final bytes = ZipEncoder().encodeBytes(Archive()
          ..add(ArchiveFile.file(
              'a',
              9007199254740991,
              FileContentMemory(
                  [9, 4, 5, 0, property, 0, 0, 128, 0, 0, 0, 0, 0, 0]))
            ..compression = CompressionType.none));
        final view = ByteData.sublistView(bytes);
        view.setUint16(8, ZipFile.zipCompressionLzma, Endian.little);
        var central = 0;
        while (view.getUint32(central, Endian.little) != 0x02014b50) {
          central++;
        }
        view.setUint16(central + 10, ZipFile.zipCompressionLzma, Endian.little);
        expect(() => ZipDecoder().decodeBytes(bytes).files.single.content,
            returnsNormally);
        for (final (verify, throwOnError) in [(false, true), (true, false)]) {
          for (final writeContent in [false, true]) {
            final file = ZipDecoder()
                .decodeBytes(bytes, verify: verify, throwOnError: throwOnError)
                .files
                .single;
            expect(
                () => writeContent
                    ? file.writeContent(OutputMemoryStream())
                    : file.content,
                throwsA(isA<ArchiveException>().having(
                    (error) => error.message,
                    'message',
                    contains(property == 225
                        ? 'Invalid LZMA properties'
                        : 'truncated or corrupt'))),
                reason:
                    'property $property, verify $verify, write $writeContent');
          }
        }
      }
    });

    test('a zip made on Windows gets default permissions', () async {
      final windows = ZipDecoder()
          .decodeBytes(File('test/_data/zip/winxp.zip').readAsBytesSync());
      for (final f in windows.files) {
        expect(f.unixPermissions, f.isFile ? 0x1a4 : 0x1ed, reason: f.name);
      }
      final unix = ZipDecoder()
          .decodeBytes(File('test/_data/zip/test.zip').readAsBytesSync());
      for (final f in unix.files) {
        expect(f.mode, 0x81a4, reason: f.name);
      }

      final dir = Directory.systemTemp.createTempSync('zip_mode');
      addTearDown(() => dir.deleteSync(recursive: true));
      await extractFileToDisk('test/_data/zip/winxp.zip', dir.path);
      final hello = File(p.join(dir.path, 'hello'));
      expect(hello.readAsBytesSync(), isNotEmpty);
      if (!Platform.isWindows) {
        expect(hello.statSync().mode & 0x1ff, 0x1a4);
      }
    });

    test('a zip made on Unix keeps a mode with no permission bits', () {
      Uint8List unixZip(String name, String content, int mode) {
        final bytes = ZipEncoder().encodeBytes(
            Archive()..add(ArchiveFile.string(name, content)..mode = mode));
        final directory = ByteData.sublistView(bytes)
            .getUint32(bytes.length - 6, Endian.little);
        bytes[directory + 5] = 3;
        return bytes;
      }

      final file = ZipDecoder()
          .decodeBytes(unixZip('private.txt', 'private', 0x8000))
          .files
          .single;
      expect(file.mode, 0x8000);
      expect(file.unixPermissions, 0);
      final link = ZipDecoder()
          .decodeBytes(unixZip('link', 'target.txt', 0xa000))
          .files
          .single;
      expect(link.isSymbolicLink, isTrue);
      expect(link.symbolicLink, 'target.txt');
    });

    test('encode keeps lzma entries of a decoded zip', () {
      final decoded = ZipDecoder()
          .decodeBytes(File('test/_data/zip/lzma.zip').readAsBytesSync());
      final encoded = ZipEncoder().encodeBytes(decoded);
      final again = ZipDecoder().decodeBytes(encoded, verify: true);
      expectLzmaArchive(again);
      for (final f in again.files) {
        if (f.compression != CompressionType.lzma) continue;
        final zipFile = f.rawContent! as ZipFile;
        expect(zipFile.flags & 0x02, 0x02, reason: f.name);
        expect(zipFile.version, 63, reason: f.name);
      }
    });

    test('an entry that claims 2^63 bytes is re-encoded from the bytes it has',
        () {
      const hex = '504b03042d00080000000000000000000000ffffffffffffffff0100140041'
          '01001000ebffffffffffff7febffffffffffff7f58504b070800000000ffffff'
          'ffffffffff504b01022d002d00080000000000000000000000ffffffffffffff'
          'ff0100140000000000000000000000000000004101001000ebffffffffffff7f'
          'ebffffffffffff7f504b0506000000000100010043000000440000000000';
      final bytes = Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16)
      ]);
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.single.content.length, 106);
      expect(() => ZipEncoder().encodeBytes(archive), returnsNormally);
    }, testOn: 'vm');

    test('a time outside the DOS range is clamped as libarchive writes it',
        () async {
      int seconds(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
      final cases = [
        (-86399, 0x0021, 0x0000),
        (0, 0x0021, 0x0000),
        (seconds(DateTime(1979, 12, 31, 23, 59, 59)), 0x0021, 0x0000),
        (seconds(DateTime(1980)), 0x0021, 0x0000),
        (seconds(DateTime(1980, 1, 1, 0, 0, 2)), 0x0021, 0x0001),
        (seconds(DateTime(2107, 12, 31, 23, 59, 59)), 0xff9f, 0xbf7d),
        (seconds(DateTime(2108)), 0xff9f, 0xbf7d),
        (seconds(DateTime(2200, 6, 1)), 0xff9f, 0xbf7d),
      ];
      final archive = Archive();
      for (final (i, (time, _, _)) in cases.indexed) {
        archive.add(ArchiveFile.bytes('$i.txt', [i])..lastModTime = time);
      }
      final encoded = {
        'encodeBytes': ZipEncoder().encodeBytes(archive),
        'converter': Uint8List.fromList(await Stream.fromIterable(archive.files)
            .transform(zipCodec.encoder)
            .expand((b) => b)
            .toList()),
      };
      int? ut(Uint8List? extra) {
        final view = ByteData.sublistView(extra ?? Uint8List(0));
        for (var at = 0; at + 4 <= view.lengthInBytes;) {
          final size = view.getUint16(at + 2, Endian.little);
          if (view.getUint16(at, Endian.little) == 0x5455) {
            expect((size, view.getUint8(at + 4)), (5, 1));
            return view.getUint32(at + 5, Endian.little);
          }
          at += 4 + size;
        }
        return null;
      }

      for (final MapEntry(key: how, value: bytes) in encoded.entries) {
        final files = ZipDecoder().decodeBytes(bytes, verify: true).files;
        for (final (i, (seconds, date, time)) in cases.indexed) {
          final zipFile = files[i].rawContent! as ZipFile;
          expect(
              (zipFile.lastModFileDate, zipFile.lastModFileTime), (date, time),
              reason: '$how case $i');
          expect(ut(zipFile.extraField), seconds % 0x100000000,
              reason: '$how case $i local');
          expect(ut(zipFile.header!.extraField), seconds % 0x100000000,
              reason: '$how case $i central');
        }
      }
      final modified = DateTime(1975, 5, 5);
      final overridden = ZipDecoder()
          .decodeBytes(ZipEncoder().encodeBytes(archive, modified: modified))
          .files
          .first
          .rawContent! as ZipFile;
      expect(ut(overridden.header!.extraField),
          modified.millisecondsSinceEpoch ~/ 1000);
      expect((overridden.lastModFileDate, overridden.lastModFileTime),
          (0x0021, 0x0000));
    });

    test('zstd and xz entries are decoded and kept by the encoder', () {
      final a =
          utf8.encode('The quick brown fox jumps over the lazy dog\n' * 30);
      final b = List.generate(70000, (i) => (i * 7 + i ~/ 13) & 0xff);
      for (final (name, type, password) in [
        ('zstd.zip', CompressionType.zstd, null),
        ('xz.zip', CompressionType.xz, null),
        ('xz_aes.zip', CompressionType.xz, 'secret'),
      ]) {
        final bytes = File('test/_data/zip/$name').readAsBytesSync();
        for (final verify in [false, true]) {
          final archive = ZipDecoder()
              .decodeBytes(bytes, password: password, verify: verify);
          expect(archive.files.map((f) => f.name), ['a.txt', 'b.bin'],
              reason: name);
          expect(archive.files.map((f) => f.compression), [type, type],
              reason: name);
          expect(archive.files.map((f) => f.content), [a, b], reason: name);
          final out = OutputMemoryStream();
          ZipDecoder()
              .decodeBytes(bytes, password: password, verify: verify)
              .files[1]
              .writeContent(out);
          expect(out.getBytes(), b, reason: name);
        }
        if (password != null) {
          continue;
        }
        final again = ZipDecoder().decodeBytes(
            ZipEncoder().encodeBytes(ZipDecoder().decodeBytes(bytes)),
            verify: true);
        expect(again.files.map((f) => f.compression), [type, type],
            reason: name);
        expect(again.files.map((f) => f.content), [a, b], reason: name);
      }
      for (final type in [CompressionType.zstd, CompressionType.xz]) {
        final archive = Archive()
          ..add(ArchiveFile.bytes('a.txt', a)..compression = type);
        final back = ZipDecoder()
            .decodeBytes(ZipEncoder().encodeBytes(archive), verify: true);
        expect(back.single.compression, type, reason: '$type');
        expect(back.single.content, a, reason: '$type');
        if (type == CompressionType.zstd) {
          expect((back.single.rawContent! as ZipFile).compressedSize,
              lessThan(a.length ~/ 4));
          final sizes = [
            for (final level in [-1, 1, 9])
              (ZipDecoder()
                      .decodeBytes(ZipEncoder().encodeBytes(
                          Archive()
                            ..add(ArchiveFile.bytes('b.bin', b)
                              ..compression = type),
                          level: level))
                      .single
                      .rawContent! as ZipFile)
                  .compressedSize
          ];
          expect(sizes[1], isNot(sizes[2]));
        }
      }
    });

    test('a zstd entry takes the zstd levels above 9', () {
      final b = List.generate(70000, (i) => (i * 7 + i ~/ 13) & 0xff);
      for (final level in [19, 22]) {
        final expected = ZstdEncoder().encodeBytes(b, level: level).length;
        final byArgument = ZipDecoder().decodeBytes(
            ZipEncoder().encodeBytes(
                Archive()
                  ..add(ArchiveFile.bytes('b.bin', b)
                    ..compression = CompressionType.zstd),
                level: level),
            verify: true);
        final byFile = ZipDecoder().decodeBytes(
            ZipEncoder().encodeBytes(Archive()
              ..add(ArchiveFile.bytes('b.bin', b)
                ..compression = CompressionType.zstd
                ..compressionLevel = level)),
            verify: true);
        for (final back in [byArgument, byFile]) {
          expect(back.single.content, b, reason: '$level');
          expect((back.single.rawContent! as ZipFile).compressedSize, expected,
              reason: '$level');
        }
      }
      expect(
          () => ZipEncoder().encodeBytes(
              Archive()
                ..add(ArchiveFile.bytes('b.bin', b)
                  ..compression = CompressionType.zstd),
              level: 23),
          throwsArgumentError);
      expect(
          () => ZipEncoder().encodeBytes(
              Archive()..add(ArchiveFile.bytes('b.bin', b)),
              level: 19),
          throwsArgumentError);
    });

    test('a small entry does not hold the output buffer', () {
      final data = utf8.encode('alpha beta gamma');
      for (final type in [
        CompressionType.zstd,
        CompressionType.xz,
        CompressionType.bzip2
      ]) {
        final zip = ZipEncoder().encodeBytes(
            Archive()..add(ArchiveFile.bytes('a.txt', data)..compression = type));
        final entry = ZipDecoder().decodeBytes(zip).single;
        expect(entry.compression, type);
        final out = entry.readBytes()!;
        expect(out, data, reason: '$type');
        expect(out.buffer.lengthInBytes, data.length, reason: '$type');
      }
      final lzma = ZipDecoder()
          .decodeBytes(File('test/_data/zip/lzma_near.zip').readAsBytesSync())
          .files
          .firstWhere((file) => file.isFile);
      expect(lzma.compression, CompressionType.lzma);
      final out = lzma.readBytes()!;
      expect(out.length, 1024);
      expect(out.buffer.lengthInBytes, out.length);
    });

    test('encode password', () {
      final archive = Archive();
      final bdata = 'hello world';
      final bytes = Uint8List.fromList(bdata.codeUnits);
      final name = 'abc.txt';
      final afile = ArchiveFile.bytes(name, bytes);
      archive.add(afile);

      final zipData = ZipEncoder(password: 'abc123').encodeBytes(archive);

      File(p.join(testOutputPath, 'zip_password.zip'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(zipData);

      final arc = ZipDecoder().decodeBytes(zipData, password: 'abc123');
      expect(arc.length, equals(1));
      final arcData = arc[0].readBytes()!;
      expect(arcData.length, equals(bdata.length));
      for (var i = 0; i < arcData.length; ++i) {
        expect(arcData[i], equals(bdata.codeUnits[i]));
      }
    });

    test('decode/encode', () {
      final file = File(p.join('test/_data/test.zip'));
      final bytes = file.readAsBytesSync();

      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(archive.length, equals(2));

      final b = File(p.join('test/_data/cat.jpg'));
      final bBytes = b.readAsBytesSync();
      final aBytes = aTxt.codeUnits;

      for (var i = 0; i < archive.length; ++i) {
        final zBytes = archive[i].readBytes()!;
        if (archive[i].name == 'a.txt') {
          compareBytes(zBytes, aBytes);
        } else if (archive[i].name == 'cat.jpg') {
          compareBytes(zBytes, bBytes);
        } else {
          throw TestFailure('Invalid file found');
        }
      }

      // Encode the archive we just decoded
      final zipped = ZipEncoder().encodeBytes(archive);

      final f = File(p.join(testOutputPath, 'test.zip'));
      f.createSync(recursive: true);
      f.writeAsBytesSync(zipped);

      // Decode the archive we just encoded
      final archive2 = ZipDecoder().decodeBytes(zipped, verify: true);

      expect(archive2.length, equals(archive.length));
      for (var i = 0; i < archive2.length; ++i) {
        expect(archive2[i].name, equals(archive[i].name));
        expect(archive2[i].size, equals(archive[i].size));
      }
    });

    test('symlink', () async {
      final stream = InputMemoryStream(
          File('test/_data/zip/symlink.zip').readAsBytesSync());
      final archive = ZipDecoder().decodeStream(stream);
      expect(archive[0].isSymbolicLink, equals(true));
    });

    test('a symlink is written as a link and read back', () {
      final archive = Archive()
        ..add(ArchiveFile.string('a.txt', 'hello'))
        ..add(ArchiveFile.symlink('link', 'a.txt'))
        ..add(ArchiveFile.symlink('dir/up', '../a.txt'));
      for (final encoder in [ZipEncoder(), ZipEncoder(streamed: true)]) {
        final decoder = ZipDecoder();
        final back = decoder.decodeBytes(encoder.encodeBytes(archive));
        expect(back.findFile('a.txt')!.isSymbolicLink, isFalse);
        expect(back.findFile('link')!.symbolicLink, 'a.txt');
        expect(back.findFile('dir/up')!.symbolicLink, '../a.txt');
        expect(back.findFile('link')!.mode & 0xf000, 0xa000);
        final hosts = {
          for (final h in decoder.directory.fileHeaders)
            h.filename: h.versionMadeBy >> 8
        };
        expect(hosts, {'a.txt': 0, 'link': 3, 'dir/up': 3});
      }
    });

    test('a symlink target in a legacy code page keeps later entries', () {
      final zip = ZipEncoder(filenameEncoding: latin1).encodeBytes(Archive()
        ..add(ArchiveFile.string('a.txt', 'a'))
        ..add(ArchiveFile.symlink('link', 'target'))
        ..add(ArchiveFile.string('b.txt', 'b')));
      zip[String.fromCharCodes(zip).indexOf('target')] = 0xe9;
      for (final throwOnError in [false, true]) {
        final archive =
            ZipDecoder().decodeBytes(zip, throwOnError: throwOnError);
        expect(archive.files.map((f) => f.name), ['a.txt', 'link', 'b.txt'],
            reason: 'throwOnError $throwOnError');
        expect(archive.findFile('link')!.isSymbolicLink, isTrue,
            reason: 'throwOnError $throwOnError');
      }
    });

    test('a hard link named above the archive root is still encoded', () {
      final archive = Archive()
        ..add(ArchiveFile.string('a.txt', 'hello'))
        ..add(ArchiveFile.symlink('../up', 'a.txt')..isHardLink = true)
        ..add(ArchiveFile.string('b.txt', 'b'));
      expect(() => ZipEncoder().encodeBytes(archive), returnsNormally);
      final back = ZipDecoder().decodeBytes(ZipEncoder().encodeBytes(archive));
      expect(back.files.map((f) => f.name), ['a.txt', '../up', 'b.txt']);
      expect(back.findFile('../up')!.isSymbolicLink, isTrue);
    });

    test('decode many files (100k)', () async {
      final fp = InputFileStream(
        p.join('test/_data/test_100k_files.zip'),
        bufferSize: 1024 * 1024,
      );
      final archive = ZipDecoder().decodeStream(fp);

      final totalArchiveEntriesCount = archive.length;
      expect(archive.length, equals(100000));

      int nextEntryIndex = 0;
      while (nextEntryIndex < totalArchiveEntriesCount) {
        final file = archive[nextEntryIndex];
        if (!file.isFile) {
          nextEntryIndex++;
          continue;
        }
        final f = file;
        final String filename = f.name;
        final data = f.getContent();
        f.clear();
        expect(
          filename.trim(),
          isNotEmpty,
          reason: 'Archive file check error: file name empty',
        );
        expect(
          data,
          isNotNull,
          reason: 'Archive file check error: content for $filename is null',
        );
        nextEntryIndex++;
      }
    });

    for (final Z in zipTests) {
      final z = Z as Map<String, dynamic>;
      test('unzip ${z['Name']}', () {
        final file = File(p.join(z['Name'] as String));
        final bytes = file.readAsBytesSync();

        final zipDecoder = ZipDecoder();
        final archive = zipDecoder.decodeBytes(bytes, verify: true);
        final zipFiles = zipDecoder.directory.fileHeaders;

        if (z.containsKey('Comment')) {
          expect(zipDecoder.directory.zipFileComment, z['Comment']);
        }

        if (!z.containsKey('File')) {
          return;
        }
        expect(zipFiles.length, equals(z['File'].length));

        for (var i = 0; i < zipFiles.length; ++i) {
          final zipFileHeader = zipFiles[i];
          final zipFile = zipFileHeader.file;

          final hdr = z['File'][i] as Map<String, dynamic>;

          if (hdr.containsKey('Name')) {
            expect(zipFile!.filename, equals(hdr['Name']));
          }
          if (hdr.containsKey('Content')) {
            expect(zipFile!.getStream().toUint8List(), equals(hdr['Content']));
          }
          if (hdr.containsKey('VerifyChecksum')) {
            expect(zipFile!.verifyCrc32(), equals(hdr['VerifyChecksum']));
          }
          if (hdr.containsKey('isFile')) {
            expect(archive.find(zipFile!.filename)?.isFile, hdr['isFile']);
          }
          if (hdr.containsKey('isSymbolicLink')) {
            expect(archive.find(zipFile!.filename)?.isSymbolicLink,
                hdr['isSymbolicLink']);
            expect(archive.find(zipFile.filename)?.symbolicLink,
                utf8.decode(hdr['Content'] as List<int>));
          }
        }
      });
    }
  });

  group('zip encoder headers', () {
    test('an entry with no content leaves the local headers walkable', () {
      for (final password in <String?>[null, 'secret']) {
        final encoder = ZipEncoder(password: password);
        final output = OutputMemoryStream();
        encoder.startEncode(output);
        encoder.add(ArchiveFile.string('a.txt', 'aaaa'));
        encoder.add(ArchiveFile.directory('dir'));
        encoder.add(ArchiveFile.string('b.txt', 'bbbb'));
        encoder.endEncode();
        expect(_walkLocalHeaders(output.getBytes()), ['a.txt', 'dir/', 'b.txt'],
            reason: 'password=$password');
      }
    });

    test('the archive is the same in a big endian output', () {
      Archive archive() => Archive()
        ..add(ArchiveFile.string('a.txt', 'hello' * 100))
        ..add(ArchiveFile.directory('dir'))
        ..add(ArchiveFile.noCompress('b.txt', 4, utf8.encode('bbbb')));
      final modified = DateTime(2024, 1, 2, 3, 4, 6);
      for (final streamed in [false, true]) {
        final expected = ZipEncoder(streamed: streamed)
            .encodeBytes(archive(), modified: modified);
        final output = OutputMemoryStream(byteOrder: ByteOrder.bigEndian);
        ZipEncoder(streamed: streamed)
            .encodeStream(archive(), output, modified: modified);
        expect(output.getBytes(), expected, reason: 'streamed $streamed');
        expect(output.byteOrder, ByteOrder.bigEndian,
            reason: 'streamed $streamed');
      }
    });

    test('the local and central headers agree on the filename encoding', () {
      final encoder = ZipEncoder(filenameEncoding: const Latin1Codec());
      final output = OutputMemoryStream();
      encoder.startEncode(output);
      encoder.add(ArchiveFile.string('café.txt', 'x'));
      encoder.endEncode();
      final bytes = output.getBytes();
      final central = _centralDirectoryOffset(bytes);
      // Bit 11 claims the name is UTF-8, and with this encoding it is latin1
      expect((bytes[central + 8] | (bytes[central + 9] << 8)) & 0x800,
          (bytes[6] | (bytes[7] << 8)) & 0x800);
    });

    test('a non-ASCII UTF-8 name is not marked as an OEM name', () {
      Map<String, int> madeBy(ZipEncoder encoder) {
        final archive = Archive()
          ..add(ArchiveFile.string('plain.txt', 'x'))
          ..add(ArchiveFile.string('café.txt', 'x'));
        final decoder = ZipDecoder(filenameEncoding: encoder.filenameEncoding)
          ..decodeBytes(encoder.encodeBytes(archive));
        return {
          for (final h in decoder.directory.fileHeaders)
            h.filename: h.versionMadeBy
        };
      }

      expect(madeBy(ZipEncoder()), {'plain.txt': 20, 'café.txt': 40});
      expect(madeBy(ZipEncoder(filenameEncoding: const Latin1Codec())),
          {'plain.txt': 20, 'café.txt': 20});
    });

    test('an encrypted entry with no content has room for the AES fields', () {
      final encoder = ZipEncoder(password: 'secret');
      final output = OutputMemoryStream();
      encoder.startEncode(output);
      encoder.add(ArchiveFile.noData('n.txt'));
      encoder.endEncode();
      final bytes = output.getBytes();
      final encrypted = (bytes[6] | (bytes[7] << 8)) & 1 != 0;
      final compressed = _uint32(bytes, 18);
      const salt = 16;
      const passwordVerifier = 2;
      const mac = 10;
      expect(!encrypted || compressed >= salt + passwordVerifier + mac, isTrue,
          reason: 'encrypted=$encrypted with $compressed bytes of data');
    });
  });
}

/// Walks the local headers the way a forward-only reader does and returns the
/// names it finds. It stops as soon as one header does not lead to the next
List<String> _walkLocalHeaders(Uint8List bytes) {
  final names = <String>[];
  var at = 0;
  while (at + 30 <= bytes.length) {
    if (_uint32(bytes, at) != 0x04034b50) {
      break;
    }
    final nameLength = bytes[at + 26] | (bytes[at + 27] << 8);
    final extraLength = bytes[at + 28] | (bytes[at + 29] << 8);
    final compressed = _uint32(bytes, at + 18);
    names.add(ascii.decode(bytes.sublist(at + 30, at + 30 + nameLength)));
    at += 30 + nameLength + extraLength + compressed;
  }
  return names;
}

class _RawEntry {
  _RawEntry(this.name, this.madeBy, this.attributes,
      {this.content = const [], this.extra = const []});

  final List<int> name;
  final int madeBy;
  final int attributes;
  final List<int> content;
  final List<int> extra;
}

Uint8List _rawZip(List<_RawEntry> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final e in entries) {
    final crc = getCrc32(e.content);
    central
      ..add((ByteData(46)
            ..setUint32(0, 0x02014b50, Endian.little)
            ..setUint16(4, e.madeBy, Endian.little)
            ..setUint16(6, 10, Endian.little)
            ..setUint32(16, crc, Endian.little)
            ..setUint32(20, e.content.length, Endian.little)
            ..setUint32(24, e.content.length, Endian.little)
            ..setUint16(28, e.name.length, Endian.little)
            ..setUint16(30, e.extra.length, Endian.little)
            ..setUint32(38, e.attributes, Endian.little)
            ..setUint32(42, out.length, Endian.little))
          .buffer
          .asUint8List())
      ..add(e.name)
      ..add(e.extra);
    out
      ..add((ByteData(30)
            ..setUint32(0, 0x04034b50, Endian.little)
            ..setUint16(4, 10, Endian.little)
            ..setUint32(14, crc, Endian.little)
            ..setUint32(18, e.content.length, Endian.little)
            ..setUint32(22, e.content.length, Endian.little)
            ..setUint16(26, e.name.length, Endian.little)
            ..setUint16(28, e.extra.length, Endian.little))
          .buffer
          .asUint8List())
      ..add(e.name)
      ..add(e.extra)
      ..add(e.content);
  }
  final centralOffset = out.length;
  final centralLength = central.length;
  out
    ..add(central.takeBytes())
    ..add((ByteData(22)
          ..setUint32(0, 0x06054b50, Endian.little)
          ..setUint16(8, entries.length, Endian.little)
          ..setUint16(10, entries.length, Endian.little)
          ..setUint32(12, centralLength, Endian.little)
          ..setUint32(16, centralOffset, Endian.little))
        .buffer
        .asUint8List());
  return out.takeBytes();
}

int _centralDirectoryOffset(Uint8List bytes) {
  for (var at = bytes.length - 22; at >= 0; at--) {
    if (bytes[at] == 0x50 &&
        bytes[at + 1] == 0x4b &&
        bytes[at + 2] == 0x05 &&
        bytes[at + 3] == 0x06) {
      return _uint32(bytes, at + 16);
    }
  }
  throw StateError('no end of central directory record');
}

int _uint32(Uint8List bytes, int at) =>
    bytes[at] |
    (bytes[at + 1] << 8) |
    (bytes[at + 2] << 16) |
    (bytes[at + 3] << 24);

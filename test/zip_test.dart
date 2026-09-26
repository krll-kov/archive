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

    test('decode', () async {
      var file = File(p.join('test/_data/zip/android-javadoc.zip'));
      var bytes = file.readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(archive.length, equals(102));
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
      expect(arc[0].lastModTime, equals(1008795648));
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
        expect(ZipDecoder().decodeBytes(bytes).files[i].readBytes(),
            contents[i]);
      }
      for (final f in ZipDecoder().decodeBytes(encrypted, password: 'pw').files) {
        expect(f.crc32, getCrc32(f.readBytes()!), reason: f.name);
      }

      final data = Uint8List.fromList(List<int>.generate(1000, (i) => i & 0xff));
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
          throwsException);
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
          final again = ZipDecoder().decodeBytes(encoded, password: newPassword);
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
        expectLzmaArchive(ZipDecoder().decodeBytes(
            File(path).readAsBytesSync(),
            verify: true,
            password: password));
        final input = InputFileStream(path);
        expectLzmaArchive(
            ZipDecoder().decodeStream(input, verify: true, password: password));
        input.closeSync();
      });
    }

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

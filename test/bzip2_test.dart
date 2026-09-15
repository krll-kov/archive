import 'dart:io' as io;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('decode', () {
    final orig = io.File(p.join('test/_data/bzip2/test.bz2')).readAsBytesSync();

    BZip2Decoder().decodeBytes(orig, verify: true);
  });

  test('encode', () {
    final file = io.File(p.join('test/_data/cat.jpg')).readAsBytesSync();

    final compressed = BZip2Encoder().encodeBytes(file);

    final d2 = BZip2Decoder().decodeBytes(compressed, verify: true);

    expect(d2.length, equals(file.length));
    for (var i = 0, len = d2.length; i < len; ++i) {
      expect(d2[i], equals(file[i]));
    }
  });

  test('encode rejects a block size outside the format', () {
    expect(() => BZip2Encoder().encodeBytes([1, 2, 3], blockSize100k: 10),
        throwsA(isA<ArchiveException>()));
  });

  // After a stream bzip2 1.0.8 reads BZh and a digit from 1 to 9. If a byte
  // differs, bzip2 ignores the rest as trailing garbage and exits 0
  test('bytes after a stream that start no stream are ignored on every path',
      () async {
    final data = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    final stream = BZip2Encoder().encodeBytes(data);
    for (final tail in [
      [0x41, 0x41, 0x41],
      [0x42, 0x41],
      [0x42, 0x5A, 0x68, 0x30],
      [0x42, 0x5A, 0x68, 0x78],
    ]) {
      final archive = Uint8List.fromList([...stream, ...tail]);
      final output = OutputMemoryStream();
      expect(
          BZip2Decoder()
              .decodeStream(InputMemoryStream(archive), output, verify: true),
          isTrue,
          reason: 'decodeStream, tail $tail');
      expect(output.getBytes(), data);
      expect(BZip2Decoder().decodeBytes(archive, verify: true), data,
          reason: 'decodeBytes, tail $tail');
      expect(bzip2Codec.decode(archive), data, reason: 'converter, tail $tail');
      // One byte at a time. The converter gets the tail in pieces
      final pieces = await Stream.fromIterable([
        for (final byte in archive) [byte]
      ]).transform(bzip2Codec.decoder).expand((piece) => piece).toList();
      expect(pieces, data, reason: 'converter by bytes, tail $tail');
    }
  });

  // The input ends inside BZh and the digit. bzip2 1.0.8 exits 2 on it
  test('a tail that ends inside a stream signature is an error on every path',
      () {
    final data = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    final stream = BZip2Encoder().encodeBytes(data);
    for (final tail in [
      [0x42],
      [0x42, 0x5A],
      [0x42, 0x5A, 0x68],
      [0x42, 0x5A, 0x68, 0x39],
    ]) {
      final archive = Uint8List.fromList([...stream, ...tail]);
      expect(
          BZip2Decoder().decodeStream(
              InputMemoryStream(archive), OutputMemoryStream(),
              verify: true),
          isFalse,
          reason: 'decodeStream, tail $tail');
      expect(() => bzip2Codec.decode(archive), throwsA(isA<ArchiveException>()),
          reason: 'converter, tail $tail');
    }
  });

  test('a cut archive is a failure on both input streams', () async {
    // A file reads zeros past its end and memory throws, so the bit reader
    // stops at the end itself, or the verdict depends on the stream given
    final source = Uint8List(400000);
    for (var i = 0; i < source.length; i++) {
      source[i] = (i * 17 + (i >> 5)) & 0xff;
    }
    final whole = BZip2Encoder().encodeBytes(source, blockSize100k: 1);
    final dir = io.Directory.systemTemp.createTempSync('bz_cut');
    try {
      for (var cut = 4; cut < whole.length; cut += whole.length ~/ 12) {
        final bytes = Uint8List.sublistView(whole, 0, cut);
        final file = io.File('${dir.path}/cut.bz2')..writeAsBytesSync(bytes);

        expect(
            BZip2Decoder()
                .decodeStream(InputMemoryStream(bytes), OutputMemoryStream()),
            isFalse,
            reason: 'memory, cut at $cut');
        final input = InputFileStream(file.path);
        expect(
            BZip2Decoder().decodeStream(input, OutputMemoryStream()), isFalse,
            reason: 'file, cut at $cut');
        input.closeSync();
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('a zip entry with damaged bzip2 data reports it', () {
    final source = Uint8List(200000);
    for (var i = 0; i < source.length; i++) {
      source[i] = (i * 29 + (i >> 4)) & 0xff;
    }
    final archive = Archive()
      ..add(ArchiveFile.bytes('a.bin', source)
        ..compression = CompressionType.bzip2);
    final zip = ZipEncoder().encodeBytes(archive);
    final bad = Uint8List.fromList(zip);
    for (var i = 120; i < 400 && i < bad.length; i++) {
      bad[i] = bad[i] ^ 0xff;
    }

    final entry = ZipDecoder().decodeBytes(bad).files.single;
    expect(entry.readBytes, throwsA(isA<ArchiveException>()));
  });

  test('a signature naming block size zero is refused on every path', () async {
    final good = BZip2Encoder().encodeBytes([1, 2, 3]);
    final bad = Uint8List.fromList(good)..[3] = 0x30;

    expect(BZip2Decoder().decodeBytes(bad, verify: true), isEmpty);
    expect(
        BZip2Decoder()
            .decodeStream(InputMemoryStream(bad), OutputMemoryStream()),
        isFalse);
    await expectLater(
        Stream<List<int>>.fromIterable([bad]).transform(bzip2Codec.decoder),
        emitsError(isA<ArchiveException>()));
  });
}

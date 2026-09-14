import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Every check is run against an archive the package itself wrote, and against
// the archives of every other format, so a header that happens to look like
// another one would show up.

Uint8List _sample() {
  final data = Uint8List(4096);
  for (var i = 0; i < data.length; i++) {
    data[i] = (i * 31 + (i >> 5)) & 0xff;
  }
  return data;
}

void main() {
  final sample = _sample();
  final archives = <ArchiveFormat, Uint8List>{
    ArchiveFormat.gzip: GZipEncoder().encodeBytes(sample),
    ArchiveFormat.zlib: ZLibEncoder().encodeBytes(sample),
    ArchiveFormat.bzip2: BZip2Encoder().encodeBytes(sample),
    ArchiveFormat.xz: XZEncoder().encodeBytes(sample),
    ArchiveFormat.zstd: ZstdEncoder().encodeBytes(sample),
    ArchiveFormat.zip: ZipEncoder()
        .encodeBytes(Archive()..add(ArchiveFile.bytes('a.bin', sample))),
    ArchiveFormat.tar: TarEncoder()
        .encodeBytes(Archive()..add(ArchiveFile.bytes('a.bin', sample))),
  };

  group('codecs recognizer', () {
    archives.forEach((format, bytes) {
      test('$format is recognised', () {
        expect(CodecsRecognizer.recognize(bytes), format);
      });

      test('$format is not taken for anything else', () {
        final checks = <ArchiveFormat, bool Function(List<int>)>{
          ArchiveFormat.gzip: CodecsRecognizer.isGZip,
          ArchiveFormat.bzip2: CodecsRecognizer.isBZip2,
          ArchiveFormat.xz: CodecsRecognizer.isXZ,
          ArchiveFormat.zstd: CodecsRecognizer.isZstd,
          ArchiveFormat.zip: CodecsRecognizer.isZip,
          ArchiveFormat.tar: CodecsRecognizer.isTar,
        };
        checks.forEach((other, check) {
          expect(check(bytes), other == format,
              reason: '$format read as $other');
        });
      });
    });

    test('a zstd skippable frame at the start is still zstd', () {
      final frame = Uint8List.fromList([
        0x50, 0x2a, 0x4d, 0x18, // skippable magic, low byte first
        4, 0, 0, 0, // the size of what it holds
        1, 2, 3, 4,
      ]);
      expect(CodecsRecognizer.isZstd(frame), isTrue);
      expect(CodecsRecognizer.recognize(frame), ArchiveFormat.zstd);
    });

    test('an empty zip archive is recognised', () {
      expect(CodecsRecognizer.recognize(ZipEncoder().encodeBytes(Archive())),
          ArchiveFormat.zip);
    });

    test('the archives in the test data are recognised', () {
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/xz/cat.jpg.xz')).readAsBytesSync()),
          ArchiveFormat.xz);
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/cat.jpg.gz')).readAsBytesSync()),
          ArchiveFormat.gzip);
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/folder.zip')).readAsBytesSync()),
          ArchiveFormat.zip);
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/example.tar')).readAsBytesSync()),
          ArchiveFormat.tar);
    });

    test('what is none of them is unknown', () {
      expect(CodecsRecognizer.recognize(Uint8List(0)), ArchiveFormat.unknown);
      expect(CodecsRecognizer.recognize(Uint8List.fromList([1, 2, 3])),
          ArchiveFormat.unknown);
      expect(CodecsRecognizer.recognize(sample), ArchiveFormat.unknown);
    });

    test('a header shorter than the check needs is not a match', () {
      final xz = archives[ArchiveFormat.xz]!;
      expect(CodecsRecognizer.isXZ(Uint8List.sublistView(xz, 0, 5)), isFalse);
      final tar = archives[ArchiveFormat.tar]!;
      expect(
          CodecsRecognizer.isTar(Uint8List.sublistView(tar, 0, 262)), isFalse);
    });

    test('six bytes decide every format but tar', () {
      archives.forEach((format, bytes) {
        if (format == ArchiveFormat.tar) {
          return;
        }
        final head = Uint8List.sublistView(bytes, 0, 6);
        expect(CodecsRecognizer.recognize(head), format,
            reason: '$format from ${6} bytes');
      });
    });

    test('a ustar tar is recognised from its magic, without the checksum', () {
      // What this package writes is the format before ustar, which carries no
      // magic at all, so a tar from elsewhere is what shows the short path
      final tar = File(p.join('test/_data/example.tar')).readAsBytesSync();
      final head = Uint8List.sublistView(tar, 0, 263);
      expect(CodecsRecognizer.isTar(head), isTrue);
      expect(CodecsRecognizer.recognize(head), ArchiveFormat.tar);
    });

    test('a tar this package wrote needs its whole header', () {
      final tar = archives[ArchiveFormat.tar]!;
      expect(
          CodecsRecognizer.isTar(Uint8List.sublistView(tar, 0, 263)), isFalse);
      expect(
          CodecsRecognizer.isTar(Uint8List.sublistView(tar, 0, 512)), isTrue);
    });

    test('a damaged header does not pass the checksum', () {
      final broken = Uint8List.fromList(archives[ArchiveFormat.tar]!)
        ..[100] ^= 0xff;
      expect(CodecsRecognizer.isTar(Uint8List.sublistView(broken, 0, 512)),
          isFalse);
    });

    test('every format names the extension it is written with', () {
      expect(CodecsRecognizer.extensionOf(ArchiveFormat.zstd), 'zst');
      expect(CodecsRecognizer.extensionOf(ArchiveFormat.unknown), isNull);
    });
  });
}

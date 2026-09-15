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
        expect(CodecsRecognizer.recognize(bytes, withZLib: true), format);
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
      expect(CodecsRecognizer.recognize(frame, withZLib: true),
          ArchiveFormat.zstd);
    });

    test('an empty zip archive is recognised', () {
      expect(
          CodecsRecognizer.recognize(ZipEncoder().encodeBytes(Archive()),
              withZLib: true),
          ArchiveFormat.zip);
    });

    test('the archives in the test data are recognised', () {
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/xz/cat.jpg.xz')).readAsBytesSync(),
              withZLib: true),
          ArchiveFormat.xz);
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/cat.jpg.gz')).readAsBytesSync(),
              withZLib: true),
          ArchiveFormat.gzip);
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/folder.zip')).readAsBytesSync(),
              withZLib: true),
          ArchiveFormat.zip);
      expect(
          CodecsRecognizer.recognize(
              File(p.join('test/_data/example.tar')).readAsBytesSync(),
              withZLib: true),
          ArchiveFormat.tar);
    });

    test('what is none of them is unknown', () {
      expect(CodecsRecognizer.recognize(Uint8List(0), withZLib: true),
          ArchiveFormat.unknown);
      expect(
          CodecsRecognizer.recognize(Uint8List.fromList([1, 2, 3]),
              withZLib: true),
          ArchiveFormat.unknown);
      expect(CodecsRecognizer.recognize(sample, withZLib: true),
          ArchiveFormat.unknown);
    });

    test('zlib needs a deflate block header that could be real', () {
      // A git ref passes the two byte check. Its "0" sets the preset
      // dictionary bit
      expect(CodecsRecognizer.isZLib('80cc39b4'.codeUnits), isFalse);
      // Type 3 is reserved
      expect(CodecsRecognizer.isZLib([0x78, 0x01, 0x06]), isFalse);
      // NLEN is not the inverse of LEN in this stored block
      expect(CodecsRecognizer.isZLib([0x78, 0x01, 0x01, 5, 0, 0, 0]), isFalse);
      for (var level = 0; level <= 9; level++) {
        for (final input in [sample, Uint8List(0)]) {
          expect(
              CodecsRecognizer.isZLib(
                  ZLibEncoder().encodeBytes(input, level: level)),
              isTrue,
              reason: 'level $level, ${input.length} bytes');
        }
      }
    });

    test('reserved header bits and a missing bzip2 block are refused', () {
      final gzip = Uint8List.fromList(archives[ArchiveFormat.gzip]!)
        ..[3] |= 0x20;
      expect(CodecsRecognizer.isGZip(gzip), isFalse);
      final zstd = Uint8List.fromList(archives[ArchiveFormat.zstd]!)
        ..[4] |= 0x08;
      expect(CodecsRecognizer.isZstd(zstd), isFalse);
      // We change the check type. The stream flags no longer match their CRC32
      final xz = Uint8List.fromList(archives[ArchiveFormat.xz]!)..[7] ^= 0x01;
      expect(CodecsRecognizer.isXZ(xz), isFalse);
      // This text starts with the bzip2 magic. The next six bytes are not a
      // block magic
      expect(
          CodecsRecognizer.isBZip2('BZh9 is not a block'.codeUnits), isFalse);
      expect(CodecsRecognizer.isBZip2(BZip2Encoder().encodeBytes([])), isTrue);
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
        expect(CodecsRecognizer.recognize(head, withZLib: true), format,
            reason: '$format from ${6} bytes');
      });
    });

    test('a ustar tar is recognised from its magic, without the checksum', () {
      // What this package writes is the format before ustar, which carries no
      // magic at all, so a tar from elsewhere is what shows the short path
      final tar = File(p.join('test/_data/example.tar')).readAsBytesSync();
      final head = Uint8List.sublistView(tar, 0, 263);
      expect(CodecsRecognizer.isTar(head), isTrue);
      expect(
          CodecsRecognizer.recognize(head, withZLib: true), ArchiveFormat.tar);
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
      expect(
          CodecsRecognizer.extensionOf(ArchiveFormat.zstd).toString(), 'zst');
      expect(CodecsRecognizer.extensionOf(ArchiveFormat.unknown), isNull);
    });
  });
}

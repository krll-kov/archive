import 'dart:typed_data';

import '../codecs/tar/tar_file.dart';

/// What [CodecsRecognizer.recognize] found at the start of the data
enum ArchiveFormat {
  gzip,
  zlib,
  bzip2,
  xz,
  zstd,
  zip,
  tar,
  unknown,
}

/// Reads the first bytes of an archive and says what wrote them.
///
/// Every check reads the header alone, so a file may be recognised from the
/// piece a stream has handed over so far rather than from all of it. What each
/// one needs:
///
/// | format | bytes |
/// | --- | --- |
/// | zlib | 2 |
/// | gzip | 3 |
/// | bzip2, zstd, zip | 4 |
/// | xz | 6 |
/// | tar | 263 for the ustar magic, 512 for the header checksum |
///
/// A tar written before ustar, which is what this package's own encoder still
/// writes, carries no magic and needs the whole 512 byte header
///
/// So six bytes decide everything but tar, and [headerBytes] decides all of it.
/// A format with no header of its own, raw LZMA and raw deflate among them,
/// cannot be recognised this way and is not here
abstract final class CodecsRecognizer {
  /// The most bytes any of these checks reads, which is one tar header
  static const headerBytes = 512;

  /// `1f 8b`, then the compression method, which the format fixes at eight
  static bool isGZip(List<int> data) =>
      data.length >= 3 && data[0] == 0x1f && data[1] == 0x8b && data[2] == 0x08;

  /// zlib has no magic: the first byte names the method and the window, and
  /// the two together are a multiple of thirty one
  static bool isZLib(List<int> data) {
    if (data.length < 2) {
      return false;
    }
    final cmf = data[0];
    final flg = data[1];
    return (cmf & 0x0f) == 8 && (cmf >> 4) <= 7 && ((cmf << 8) | flg) % 31 == 0;
  }

  /// `BZh` and the block size, which is one of nine hundred kilobyte steps
  static bool isBZip2(List<int> data) =>
      data.length >= 4 &&
      data[0] == 0x42 &&
      data[1] == 0x5a &&
      data[2] == 0x68 &&
      data[3] >= 0x31 &&
      data[3] <= 0x39;

  /// `fd 37 7a 58 5a 00`
  static bool isXZ(List<int> data) =>
      data.length >= 6 &&
      data[0] == 0xfd &&
      data[1] == 0x37 &&
      data[2] == 0x7a &&
      data[3] == 0x58 &&
      data[4] == 0x5a &&
      data[5] == 0x00;

  /// A zstd frame, or one of the skippable frames an archive may start with,
  /// whose magic is `184d2a50` to `184d2a5f` written low byte first
  static bool isZstd(List<int> data) {
    if (data.length < 4) {
      return false;
    }
    if (data[0] == 0x28 &&
        data[1] == 0xb5 &&
        data[2] == 0x2f &&
        data[3] == 0xfd) {
      return true;
    }
    return data[0] >= 0x50 &&
        data[0] <= 0x5f &&
        data[1] == 0x2a &&
        data[2] == 0x4d &&
        data[3] == 0x18;
  }

  /// `PK` and the record that follows: a local file, an empty archive's end of
  /// directory, or the first piece of a split one
  static bool isZip(List<int> data) {
    if (data.length < 4 || data[0] != 0x50 || data[1] != 0x4b) {
      return false;
    }
    final kind = (data[2] << 8) | data[3];
    return kind == 0x0304 || kind == 0x0506 || kind == 0x0708;
  }

  /// A tar header is 512 bytes, and the versions before ustar carry no magic,
  /// so the checksum it holds is what identifies those. The eight bytes the
  /// checksum sits in count as spaces, and old writers summed them as signed.
  ///
  /// With less than a whole header the ustar magic still answers, which is
  /// what everything written this century carries
  static bool isTar(List<int> data) {
    if (data.length < 512) {
      // 263 bytes reach past the ustar magic at 257
      return data.length >= 263 &&
          data[257] == 0x75 && // u
          data[258] == 0x73 && // s
          data[259] == 0x74 && // t
          data[260] == 0x61 && // a
          data[261] == 0x72; //  r
    }
    return tarHeaderChecksumMatches(
        data is Uint8List ? data : Uint8List.fromList(data.sublist(0, 512)));
  }

  /// The format the data starts with, or [ArchiveFormat.unknown].
  ///
  /// The order matters only for zlib, whose header is two bytes with no magic
  /// and can be read out of another format's first bytes, so it is tried last
  static ArchiveFormat recognize(List<int> data) {
    if (isGZip(data)) {
      return ArchiveFormat.gzip;
    }
    if (isXZ(data)) {
      return ArchiveFormat.xz;
    }
    if (isZstd(data)) {
      return ArchiveFormat.zstd;
    }
    if (isBZip2(data)) {
      return ArchiveFormat.bzip2;
    }
    if (isZip(data)) {
      return ArchiveFormat.zip;
    }
    if (isTar(data)) {
      return ArchiveFormat.tar;
    }
    if (isZLib(data)) {
      return ArchiveFormat.zlib;
    }
    return ArchiveFormat.unknown;
  }

  /// The extension the format is usually written with, without the dot
  static String? extensionOf(ArchiveFormat format) => switch (format) {
        ArchiveFormat.gzip => 'gz',
        ArchiveFormat.zlib => 'zz',
        ArchiveFormat.bzip2 => 'bz2',
        ArchiveFormat.xz => 'xz',
        ArchiveFormat.zstd => 'zst',
        ArchiveFormat.zip => 'zip',
        ArchiveFormat.tar => 'tar',
        ArchiveFormat.unknown => null,
      };
}

/// Reads the header of [data] the way [CodecsRecognizer.recognize] does
ArchiveFormat recognizeArchiveFormat(Uint8List data) =>
    CodecsRecognizer.recognize(data);

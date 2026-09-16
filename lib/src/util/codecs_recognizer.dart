import 'dart:typed_data';

import '../codecs/tar/tar_file.dart';
import 'crc32.dart';

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
/// Every check reads the header alone. A file may be recognised from the piece
/// a stream has handed over so far rather than from all of it. What each one
/// needs. The first number is where a check can answer. The second number is
/// where it has read every field it checks:
///
/// | format | answers from | checks everything at |
/// | --- | --- | --- |
/// | zlib | 2 | 7 |
/// | gzip | 3 | 4 |
/// | zip | 4 | 4 |
/// | zstd | 4 | 5 |
/// | bzip2 | 4 | 10 |
/// | xz | 6 | 12 |
/// | tar | 263 for the ustar magic | 512 for the header checksum |
///
/// A check with fewer bytes than the second number skips the fields it has not
/// reached. It can then pass data that a whole header would fail
///
/// A tar written before ustar carries no magic and needs the whole 512 byte
/// header. This package's own encoder always writes the magic
///
/// Six bytes give an answer for every format but tar. Twelve bytes run every
/// check but the tar checksum. [headerBytes] decides all of it.
/// A format with no header of its own, raw LZMA and raw deflate among them,
/// cannot be recognised this way and is not here
abstract final class CodecsRecognizer {
  /// The most bytes any of these checks reads, one tar header
  static const headerBytes = 512;

  /// `1f 8b`, then the compression method. The format fixes it at eight
  ///
  /// RFC 1952 reserves the top three bits of FLG. A decoder must refuse a member
  /// that sets them
  static bool isGZip(List<int> data) =>
      data.length >= 3 &&
      data[0] == 0x1f &&
      data[1] == 0x8b &&
      data[2] == 0x08 &&
      (data.length < 4 || (data[3] & 0xe0) == 0);

  /// zlib has no magic: the first byte names the method and the window, and
  /// the two together are a multiple of thirty one. Be warned that this one
  /// might give a rare false positive on non-zlib files, there's no real way
  /// to verify zlib by header only.
  static bool isZLib(List<int> data) {
    if (data.length < 2) {
      return false;
    }
    final cmf = data[0];
    final flg = data[1];
    if ((cmf & 0x0f) != 8 ||
        (cmf >> 4) > 7 ||
        ((cmf << 8) | flg) % 31 != 0 ||
        (flg & 0x20) != 0) {
      return false;
    }
    if (data.length < 3) {
      return true;
    }
    final block = data[2];
    switch ((block >> 1) & 3) {
      case 0:
        // A stored block starts on the next byte with LEN, then NLEN
        return data.length < 7 ||
            (data[3] | data[4] << 8) == (~(data[5] | data[6] << 8) & 0xffff);
      case 1:
        return true;
      case 2:
        // HLIT is the top five bits of this byte. HDIST is the low five bits
        // of the next byte
        return (block >> 3) <= 29 &&
            (data.length < 4 || (data[3] & 0x1f) <= 29);
      default:
        return false;
    }
  }

  /// `BZh` and the block size, one of nine hundred kilobyte steps
  ///
  /// The magic is plain text. The six bytes after it are matched too when the
  /// data has them. A stream with blocks has the block magic there. An empty
  /// stream has the end of stream magic there
  static bool isBZip2(List<int> data) {
    if (data.length < 4 ||
        data[0] != 0x42 ||
        data[1] != 0x5a ||
        data[2] != 0x68 ||
        data[3] < 0x31 ||
        data[3] > 0x39) {
      return false;
    }
    var block = true;
    var end = true;
    for (var i = 4; i < data.length && i < 10; i++) {
      block = block && data[i] == _bzip2BlockMagic[i - 4];
      end = end && data[i] == _bzip2EndMagic[i - 4];
    }
    return block || end;
  }

  static const _bzip2BlockMagic = [0x31, 0x41, 0x59, 0x26, 0x53, 0x59];
  static const _bzip2EndMagic = [0x17, 0x72, 0x45, 0x38, 0x50, 0x90];

  /// `fd 37 7a 58 5a 00`
  ///
  /// Two bytes of stream flags follow the magic. Their CRC32 follows the flags.
  /// Every stream header has this CRC32. The check type of the blocks does not
  /// change that. The first flag byte must be zero. The top four bits of the
  /// second flag byte must be zero. Each field is checked once the data
  /// reaches it
  static bool isXZ(List<int> data) {
    if (data.length < 6 ||
        data[0] != 0xfd ||
        data[1] != 0x37 ||
        data[2] != 0x7a ||
        data[3] != 0x58 ||
        data[4] != 0x5a ||
        data[5] != 0x00) {
      return false;
    }
    if (data.length >= 7 && data[6] != 0) {
      return false;
    }
    if (data.length >= 8 && (data[7] & 0xf0) != 0) {
      return false;
    }
    if (data.length < 12) {
      return true;
    }
    final crc = data[8] | data[9] << 8 | data[10] << 16 | data[11] << 24;
    return getCrc32([data[6], data[7]]) == crc;
  }

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
      // Bit 3 of the frame header descriptor is reserved and must be zero
      return data.length < 5 || (data[4] & 0x08) == 0;
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

  /// A tar header is 512 bytes and the versions before ustar carry no magic.
  /// The checksum it holds is what identifies those. The eight bytes the
  /// checksum sits in count as spaces, and old writers summed them as signed.
  ///
  /// With less than a whole header the ustar magic still answers. Everything
  /// written this century carries it.
  ///
  /// A whole header with a bad checksum is not a tar, even when the magic is
  /// there. `file` calls it data and libarchive's `archive_read_format_tar_bid`
  /// returns 0 before it ever looks at the magic, where it only adds points.
  /// Do not add a magic fallback here. It would make this package the only
  /// reader calling such a file a tar
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
  /// The order matters only for zlib. Its header is two bytes with no magic and
  /// can be read out of another format's first bytes. zlib is tried last
  ///
  /// [withZLib] is set to false on purpose. It has no magic so its byte
  /// verification sometimes gives false positives
  static ArchiveFormat recognize(List<int> data, {bool withZLib = false}) {
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
    if (withZLib && isZLib(data)) {
      return ArchiveFormat.zlib;
    }
    return ArchiveFormat.unknown;
  }

  /// The extension the format is usually written with, without the dot
  ///
  /// [ArchiveExtension.tar] and [ArchiveExtension.tarShort] give the extension
  /// of a tar wrapped in the format, tar.bz2, tbz, etc.
  static ArchiveExtension? extensionOf(ArchiveFormat format) =>
      switch (format) {
        ArchiveFormat.gzip =>
          const ArchiveExtension('gz', tar: 'tar.gz', tarShort: 'tgz'),
        ArchiveFormat.zlib => const ArchiveExtension('zz'),
        ArchiveFormat.bzip2 =>
          const ArchiveExtension('bz2', tar: 'tar.bz2', tarShort: 'tbz'),
        ArchiveFormat.xz =>
          const ArchiveExtension('xz', tar: 'tar.xz', tarShort: 'txz'),
        ArchiveFormat.zstd =>
          const ArchiveExtension('zst', tar: 'tar.zst', tarShort: 'tzst'),
        ArchiveFormat.zip => const ArchiveExtension('zip'),
        ArchiveFormat.tar => const ArchiveExtension('tar'),
        ArchiveFormat.unknown => null,
      };
}

/// The extensions a format is written with, without the dot
final class ArchiveExtension {
  const ArchiveExtension(this.defaultName, {this.tar, this.tarShort});

  /// The format alone, `gz`
  final String defaultName;

  /// A tar inside the format, `tar.gz`. It is null for
  /// just tar, zip, zlib or other formats that are not compression-wrappers
  final String? tar;

  /// The one word name of a tar inside the format, `tgz`. It is null for
  /// just tar, zip, zlib or other formats that are not compression-wrappers
  final String? tarShort;

  @override
  String toString() => defaultName;
}

/// Reads the header of [data] the way [CodecsRecognizer.recognize] does
ArchiveFormat recognizeArchiveFormat(Uint8List data) =>
    CodecsRecognizer.recognize(data);

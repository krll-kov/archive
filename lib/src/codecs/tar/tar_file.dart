import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/src/util/output_memory_stream.dart';

import '../../util/archive_exception.dart';
import '../../util/file_content.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';

/*  File Header (512 bytes)
 *  Offset Size Field
 *      Pre-POSIX Header
 *  0     100  File name
 *  100   8    File mode
 *  108   8    Owner's numeric user ID
 *  116   8    Group's numeric user ID
 *  124   12   File size in bytes (octal basis)
 *  136   12   Last modification time in numeric Unix time format (octal)
 *  148   8    Checksum for header record
 *  156   1    Type flag
 *  157   100  Name of linked file
 *      UStar Format
 *  257   6    UStar indicator "ustar"
 *  263   2    UStar version "00"
 *  265   32   Owner user name
 *  297   32   Owner group name
 *  329   8    Device major number
 *  337   8    Device minor number
 *  345   155  Filename prefix
 */

/// A file entry decoded by [TarDecoder].
class TarFile {
  static const String normalFile = '0';
  static const String hardLink = '1';
  static const String symbolicLink = '2';
  static const String charSpec = '3';
  static const String blockSpec = '4';
  static const String directory = '5';
  static const String fifo = '6';
  static const String contFile = '7';
  // GNU headers whose content is the next entry's name, or the next entry's
  // link target, when it doesn't fit the 100 byte field.
  static const String longName = 'L';
  static const String longLinkName = 'K';
  // global extended header with meta data (POSIX.1-2001)
  static const String gExHeader = 'g';
  static const String gExHeader2 = 'G';
  // extended header with meta data for the next file in the archive
  // (POSIX.1-2001)
  static const String exHeader = 'x';
  static const String exHeader2 = 'X';

  /// The widest magnitude a base-256 numeric header field is written or read
  /// with: 2^53-1, the largest integer exact on every platform. A tar field
  /// can hold more, but it would not survive the trip through an int.
  static const int maxNumericField = 9007199254740991;

  // Pre-POSIX Format
  late String filename; // 100 bytes
  int mode = 644; // 8 bytes
  int ownerId = 0; // 8 bytes
  int groupId = 0; // 8 bytes
  int fileSize = 0; // 12 bytes
  int lastModTime = 0; // 12 bytes
  int checksum = 0; // 8 bytes
  String typeFlag = '0'; // 1 byte
  String? nameOfLinkedFile; // 100 bytes
  // UStar Format
  String ustarIndicator = ''; // 6 bytes (ustar)
  String ustarVersion = ''; // 2 bytes (00)
  String ownerUserName = ''; // 32 bytes
  String ownerGroupName = ''; // 32 bytes
  int deviceMajorNumber = 0; // 8 bytes
  int deviceMinorNumber = 0; // 8 bytes
  String filenamePrefix = ''; // 155 bytes
  InputStream? _rawContent;
  FileContent? _content;

  TarFile();

  /// Reads an entry from [input]. [size] is the size given by a preceding
  /// PAX header, which overrides the one in this entry's own header.
  TarFile.read(InputStream input,
      {bool storeData = true, Encoding? encoding, int? size}) {
    final header = input.readBytes(512);

    // The name, linkname, magic, uname, and gname are null-terminated
    // character strings. All other fields are zero-filled octal numbers in
    // ASCII. Each numeric field of width w contains w minus 1 digits, and a
    // null.
    filename = _parseString(header, 100, encoding, false);
    mode = _parseInt(header, 8);
    ownerId = _parseInt(header, 8);
    groupId = _parseInt(header, 8);
    fileSize = _parseInt(header, 12);
    lastModTime = _parseInt(header, 12);
    checksum = _parseInt(header, 8);
    typeFlag = _parseString(header, 1);
    nameOfLinkedFile = _parseString(header, 100, encoding, false);

    ustarIndicator = _parseString(header, 6);
    if (ustarIndicator == 'ustar') {
      ustarVersion = _parseString(header, 2);
      ownerUserName = _parseString(header, 32);
      ownerGroupName = _parseString(header, 32);
      deviceMajorNumber = _parseInt(header, 8);
      deviceMinorNumber = _parseInt(header, 8);
      filenamePrefix = _parseString(header, 155, null, false);
      if (filenamePrefix.isNotEmpty) {
        filename = '$filenamePrefix/$filename';
      }
    }

    final isMetadata = filename == '././@LongLink' ||
        typeFlag == longName ||
        typeFlag == longLinkName ||
        typeFlag == exHeader ||
        typeFlag == exHeader2 ||
        typeFlag == gExHeader ||
        typeFlag == gExHeader2;

    // A pax size record describes the entry it precedes, not the metadata
    // headers that may sit in between. Applying it to one of those would read
    // the wrong number of bytes and leave the stream mid-header.
    if (size != null && !isMetadata) {
      fileSize = size;
    }
    // A size field can hold a negative number, which no entry can have.
    if (fileSize < 0) {
      throw ArchiveException('Invalid tar file size: $fileSize');
    }

    // The decoder needs the content of the headers that carry the next
    // entry's metadata, even when it isn't storing file data.
    if (storeData ||
        filename == '././@LongLink' ||
        typeFlag == longName ||
        typeFlag == longLinkName ||
        typeFlag == exHeader ||
        typeFlag == exHeader2) {
      _rawContent = input.readBytes(fileSize);
    } else {
      input.skip(fileSize);
    }

    if (isFile && fileSize > 0) {
      final remainder = fileSize % 512;
      var skiplen = 0;
      if (remainder != 0) {
        skiplen = 512 - remainder;
        input.skip(skiplen);
      }
    }
  }

  bool get isFile => typeFlag != TarFile.directory;

  bool get isSymLink => typeFlag == TarFile.symbolicLink;

  InputStream? get rawContent => _rawContent;

  FileContent? get content {
    // What was set, or what was read, whichever there is
    if (_content == null && _rawContent != null) {
      _content = FileContentMemory(_rawContent!.toUint8List());
    }
    return _content;
  }

  set content(FileContent? data) => _content = data;

  Uint8List? get contentBytes => content?.readBytes();

  set contentBytes(Uint8List? data) =>
      data == null ? _content = null : _content = FileContentMemory(data);

  int get size => fileSize;

  @override
  String toString() => '[$filename, $mode, $fileSize]';

  /// With [headerOnly] the content and its padding are left to the caller, who
  /// can then stream them out a piece at a time rather than through one call
  void write(OutputStream output,
      {Encoding? filenameEncoder, bool headerOnly = false}) {
    fileSize = size;

    // The name, linkname, magic, uname, and gname are null-terminated
    // character strings. All other fields are zero-filled octal numbers in
    // ASCII. Each numeric field of width w contains w minus 1 digits, and a null.
    final header = OutputMemoryStream();
    _writeString(header, filename, 100, filenameEncoder);
    _writeInt(header, mode, 8);
    _writeInt(header, ownerId, 8);
    _writeInt(header, groupId, 8);
    _writeInt(header, fileSize, 12);
    _writeInt(header, lastModTime, 12);
    _writeString(header, '        ', 8); // checksum placeholder
    _writeString(header, typeFlag, 1);
    if (nameOfLinkedFile != null) {
      _writeString(header, nameOfLinkedFile!, 100, filenameEncoder);
    } else {
      _writeString(header, '', 100);
    }

    final remainder = 512 - header.length;
    header.writeBytes(Uint8List(remainder)); // typed arrays default to 0

    final headerBytes = header.getBytes();

    // The checksum is calculated by taking the sum of the unsigned byte values
    // of the header record with the eight checksum bytes taken to be ascii
    // spaces (decimal value 32). It is stored as a six digit octal number
    // with leading zeroes followed by a NUL and then a space.
    var sum = 0;
    for (var b in headerBytes) {
      sum += b;
    }

    var sumStr = sum.toRadixString(8); // octal basis
    while (sumStr.length < 6) {
      sumStr = '0$sumStr';
    }

    var checksumIndex = 148; // checksum is at 148th byte
    for (var i = 0; i < 6; ++i) {
      headerBytes[checksumIndex++] = sumStr.codeUnits[i];
    }
    headerBytes[154] = 0;
    headerBytes[155] = 32;

    output.writeBytes(header.getBytes());

    if (headerOnly) {
      return;
    }
    final body = contentStream;
    if (body != null) {
      output.writeStream(body);
    }

    final pad = padding;
    if (pad > 0) {
      output.writeBytes(Uint8List(pad));
    }
  }

  /// The payload stream following the header, read in chunks to avoid
  /// altering the read position of the original input
  InputStream? get contentStream {
    if (_content != null) {
      return _content!.getStream().subset();
    }
    return _rawContent?.subset();
  }

  /// The zeros that bring the content up to a 512 byte boundary
  int get padding {
    if (!isFile || fileSize <= 0) {
      return 0;
    }
    final remainder = fileSize % 512;
    return remainder == 0 ? 0 : 512 - remainder;
  }

  int _parseInt(InputStream input, int numBytes) {
    final bytes = input.readBytes(numBytes).toUint8List();

    // GNU tar stores values that don't fit the octal field, such as the size
    // of a file of 8GB or more, in base 256: the high bit of the first byte
    // marks the encoding, and the rest is a big endian two's complement
    // integer, with a set bit 0x40 meaning the value is negative.
    if (bytes.isNotEmpty && (bytes[0] & 0x80) != 0) {
      final inv = (bytes[0] & 0x40) != 0 ? 0xff : 0x00;
      var x = 0;
      for (var i = 0; i < bytes.length; ++i) {
        var c = bytes[i] ^ inv;
        if (i == 0) {
          c &= 0x7f;
        }
        // The field is wide enough for 88 bits, more than an int holds, and
        // a value that doesn't fit would come back as something unrelated
        // rather than as an error, so refuse anything wider than
        // maxNumericField. Checked before the multiply, so the bound is
        // divided by the base.
        // Built by arithmetic rather than shifts, because on the web an int
        // is a double and the bitwise operators there are 32 bit.
        if (x > maxNumericField ~/ 256) {
          throw ArchiveException('Tar header field is out of range');
        }
        x = x * 256 + c;
      }
      return inv == 0xff ? -x - 1 : x;
    }

    // Otherwise the field is a null or space terminated octal number.
    final end = bytes.indexOf(0);
    final s =
        String.fromCharCodes(bytes.sublist(0, end < 0 ? null : end)).trim();
    if (s.isEmpty) {
      return 0;
    }
    var x = 0;
    try {
      x = int.parse(s, radix: 8);
    } catch (e) {
      // Catch to fix a crash with bad group_id and owner_id values.
      // This occurs for POSIX archives, where some attributes like uid and
      // gid are stored in a separate PaxHeader file.
    }
    return x;
  }

  /// Parses a NUL-terminated or fixed-width field. Enabling [trim] drops
  /// space padding used in ustar magic and owner fields, but shouldn't
  /// be used for file names where spaces are significant. " .codecov.yml"`
  /// is not the same file as `".codecov.yml"`
  String _parseString(InputStream input, int numBytes,
      [Encoding? encoding, bool trim = true]) {
    final codes = input.readBytes(numBytes).toUint8List();
    final r = codes.indexOf(0);
    final s = codes.sublist(0, r < 0 ? null : r);
    final String text;
    try {
      text = encoding != null ? encoding.decode(s) : utf8.decode(s);
    } catch (e) {
      return trim ? String.fromCharCodes(s).trim() : String.fromCharCodes(s);
    }
    return trim ? text.trim() : text;
  }

  void _writeString(OutputStream output, String value, int numBytes,
      [Encoding? encoding]) {
    final codes = Uint8List(numBytes);
    final stringCodes = encoding?.encode(value) ?? utf8.encode(value);
    final end = min(stringCodes.length, numBytes);
    codes.setRange(0, end, stringCodes);
    output.writeBytes(codes);
  }

  void _writeInt(OutputStream output, int value, int numBytes) {
    var s = value.toRadixString(8);
    // Too wide for the octal field: base 256, which _parseInt reads back
    // Switched a digit later than GNU tar, because digits with no terminator
    // are read by older versions of this package and base 256 is not
    if (value < 0 || s.length > numBytes) {
      final bytes = Uint8List(numBytes);
      var m = value < 0 ? -value - 1 : value;
      // The same bound _parseInt reads back to, so wider is refused on both
      // sides
      if (m > maxNumericField) {
        throw ArchiveException('Tar header field is out of range: $value');
      }
      for (var i = numBytes - 1; i >= 0; --i) {
        bytes[i] = value < 0 ? 255 - (m % 256) : m % 256;
        m = m ~/ 256;
      }
      // Bits 0x80 and 0x40 of the first byte are the marker and the sign
      if (m != 0 || (value < 0 ? bytes[0] < 0xc0 : bytes[0] >= 0x40)) {
        throw ArchiveException('Tar header field is out of range: $value');
      }
      bytes[0] |= 0x80;
      output.writeBytes(bytes);
      return;
    }
    while (s.length < numBytes - 1) {
      s = '0$s';
    }
    _writeString(output, s, numBytes);
  }
}

/// Metadata from headers that carry no payload but describe the next entry,
/// such as GNU long names, links, and PAX records. Shared here for both
/// TarDecoder and the streamed reader
class TarMetadata {
  static const _space = 0x20;
  static const _equals = 0x3d;
  static const _newline = 0x0a;

  String? name;
  String? linkName;
  int? modTime;
  int? ownerId;
  int? groupId;

  /// A PAX size record that overrides the size of the upcoming entry
  int? size;

  /// True where [file] is one of those headers rather than an entry
  static bool describesNext(TarFile file) =>
      file.filename == '././@LongLink' ||
      file.typeFlag == TarFile.longName ||
      file.typeFlag == TarFile.longLinkName ||
      file.typeFlag == TarFile.gExHeader ||
      file.typeFlag == TarFile.gExHeader2 ||
      file.typeFlag == TarFile.exHeader ||
      file.typeFlag == TarFile.exHeader2;

  /// Takes what such a header carries, its content already in `rawContent`
  bool take(TarFile file, [Encoding? encoding]) {
    // GNU tar puts filenames in files when they exceed tar's native length.
    // Both kinds are named '././@LongLink', so only the type flag says
    // whether the content is the next entry's name or its link target.
    if (file.filename == '././@LongLink' ||
        file.typeFlag == TarFile.longName ||
        file.typeFlag == TarFile.longLinkName) {
      final codes = file.rawContent!.toUint8List();
      final end = codes.indexOf(0);
      final value = Uint8List.sublistView(codes, 0, end < 0 ? null : end);
      String text;
      // TarEncoder writes a long name with filenameEncoding, so decoding it
      // as UTF-8 breaks the round trip of any name over 100 bytes
      try {
        text = (encoding ?? utf8).decode(value);
      } catch (_) {
        text = String.fromCharCodes(value);
      }
      if (file.typeFlag == TarFile.longLinkName) {
        linkName = text;
      } else {
        name = text;
      }
      return true;
    }
    if (file.typeFlag == TarFile.gExHeader ||
        file.typeFlag == TarFile.gExHeader2) {
      // TODO handle PAX global header.
      return true;
    }
    if (file.typeFlag == TarFile.exHeader ||
        file.typeFlag == TarFile.exHeader2) {
      _readRecords(file.rawContent!.toUint8List());
      return true;
    }
    return false;
  }

  /// Applies the parsed metadata to the entry it describes and clears the state,
  /// ensuring it only affects a single entry
  void applyTo(TarFile file) {
    size = null;
    if (name != null) {
      file.filename = name!;
      name = null;
    }
    if (linkName != null) {
      file.nameOfLinkedFile = linkName;
      linkName = null;
    }
    if (modTime != null) {
      file.lastModTime = modTime!;
      modTime = null;
    }
    if (ownerId != null) {
      file.ownerId = ownerId!;
      ownerId = null;
    }
    if (groupId != null) {
      file.groupId = groupId!;
      groupId = null;
    }
  }

  /// Records are "%d %s=%s\n", the length covering the whole record. Walked by
  /// that length rather than split on newlines, and not decoded as UTF-8 up
  /// front: SCHILY.xattr and its kind hold raw bytes with embedded newlines
  void _readRecords(List<int> records) {
    var pos = 0;
    while (pos < records.length) {
      // The length field, terminated by a space.
      var sp = pos;
      while (sp < records.length && records[sp] != _space) {
        sp++;
      }
      if (sp == records.length) {
        break;
      }
      final length = int.tryParse(String.fromCharCodes(records, pos, sp));
      // A record has to at least hold the length field and its space,
      // and can't run past the end of the header.
      if (length == null ||
          length <= sp - pos + 1 ||
          pos + length > records.length) {
        break;
      }
      final recordEnd = pos + length;
      pos = recordEnd;

      // The keyword, terminated by '='. Keywords are portable
      // characters, so decoding them as ASCII is safe.
      var eq = sp + 1;
      while (eq < recordEnd && records[eq] != _equals) {
        eq++;
      }
      if (eq == recordEnd) {
        continue;
      }
      final keyword = String.fromCharCodes(records, sp + 1, eq);
      if (keyword != 'path' &&
          keyword != 'linkpath' &&
          keyword != 'size' &&
          keyword != 'mtime' &&
          keyword != 'uid' &&
          keyword != 'gid') {
        // TODO: support other pax headers.
        continue;
      }

      // The value runs to the end of the record, minus the newline.
      var valueEnd = recordEnd;
      if (records[valueEnd - 1] == _newline) {
        valueEnd--;
      }
      // The values of these keywords are UTF-8, but don't let a malformed
      // one abort the whole archive
      final value =
          utf8.decode(records.sublist(eq + 1, valueEnd), allowMalformed: true);
      switch (keyword) {
        case 'path':
          name = value;
          break;
        case 'linkpath':
          linkName = value;
          break;
        case 'size':
          // A pax size record overrides the header's own field. A file of 8GB
          // or more is stored that way in this format.
          size = int.tryParse(value);
          break;
        case 'mtime':
          // Stored as seconds, with an optional fractional part that the
          // archive has nowhere to keep. Truncated off the string rather
          // than through a double, which for a long enough fraction would
          // round up and report the wrong second.
          final dot = value.indexOf('.');
          modTime = int.tryParse(dot < 0 ? value : value.substring(0, dot));
          break;
        case 'uid':
          ownerId = int.tryParse(value);
          break;
        case 'gid':
          groupId = int.tryParse(value);
          break;
      }
    }
  }
}

/// Validates the 512-byte [header] against its own checksum
/// (calculated with the checksum field replaced by spaces).
/// Because tar headers lack strict magic numbers, this is the
/// only proof that the block is actually a tar header
bool tarHeaderChecksumMatches(Uint8List header) {
  const space = 0x20;
  if (header.length < 512) {
    return false;
  }
  var unsigned = 0;
  var signed = 0;
  for (var i = 0; i < 512; ++i) {
    final b = (i >= 148 && i < 156) ? space : header[i];
    unsigned += b;
    // Implementations that predate unsigned char summed these signed
    signed += b > 127 ? b - 256 : b;
  }
  // The stored value is octal, padded with spaces or nulls on either side of
  // the digits
  var p = 148;
  while (p < 156 && (header[p] == space || header[p] == 0)) {
    p++;
  }
  var digits = '';
  while (p < 156 && header[p] != space && header[p] != 0) {
    digits += String.fromCharCode(header[p]);
    p++;
  }
  final stored = int.tryParse(digits, radix: 8);
  return stored == unsigned || stored == signed;
}

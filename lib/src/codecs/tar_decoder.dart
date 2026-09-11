import 'dart:convert';

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../util/archive_exception.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import 'tar/tar_file.dart';

/// Decode a tar formatted buffer into an [Archive] object.
class TarDecoder {
  static const _space = 0x20;

  final Encoding filenameEncoding;
  List<TarFile> files = [];

  TarDecoder({this.filenameEncoding = const Utf8Codec()});

  /// Decode [data] as a tar archive. With [verify], every entry's header
  /// checksum is checked and an [ArchiveException] thrown if one is wrong,
  /// which is what tells a tar apart from an unrelated file.
  Archive decodeBytes(List<int> data,
      {bool verify = false, bool storeData = true, ArchiveCallback? callback}) {
    return decodeStream(InputMemoryStream(data),
        verify: verify, storeData: storeData, callback: callback);
  }

  /// Decode [input] as a tar archive. With [verify], every entry's header
  /// checksum is checked and an [ArchiveException] thrown if one is wrong,
  /// which is what tells a tar apart from an unrelated file.
  Archive decodeStream(InputStream input,
      {bool verify = false, bool storeData = true, ArchiveCallback? callback}) {
    final archive = Archive();
    files.clear();

    final metadata = TarMetadata();

    // TarFile paxHeader = null;
    while (!input.isEOS) {
      // The end of the archive is a block of zeros; two of them can't be told
      // from a damaged header, which is what verify is there to catch
      final endCheck = input.peekBytes(verify ? 512 : 2).toUint8List();
      if (verify
          ? !endCheck.any((b) => b != 0)
          : endCheck.length < 2 || (endCheck[0] == 0 && endCheck[1] == 0)) {
        break;
      }
      // Fewer bytes than a header block can't be an entry. Without verify
      // that is the end of the archive rather than an entry read from junk;
      // with it, the header check below reports it
      if (!verify && input.length < 512) {
        break;
      }

      if (verify) {
        // A tar header carries a checksum of its own 512 bytes, taking the
        // eight bytes of the checksum field itself as spaces. It is the only
        // thing that tells a tar apart from an unrelated file, since every
        // other field is free-form enough to read as something.
        final h = endCheck;
        if (h.length < 512) {
          throw ArchiveException('Invalid tar header');
        }
        var unsigned = 0;
        var signed = 0;
        for (var i = 0; i < 512; ++i) {
          final b = (i >= 148 && i < 156) ? _space : h[i];
          unsigned += b;
          // Implementations that predate unsigned char summed these signed.
          signed += b > 127 ? b - 256 : b;
        }
        // The stored value is octal, padded with spaces or nulls on either
        // side of the digits.
        var p = 148;
        while (p < 156 && (h[p] == _space || h[p] == 0)) {
          p++;
        }
        var digits = '';
        while (p < 156 && h[p] != _space && h[p] != 0) {
          digits += String.fromCharCode(h[p]);
          p++;
        }
        final stored = int.tryParse(digits, radix: 8);
        if (stored != unsigned && stored != signed) {
          throw ArchiveException('Invalid tar header checksum');
        }
      }

      final tf = TarFile.read(input,
          storeData: storeData,
          encoding: filenameEncoding,
          size: metadata.size);
      // A header that carries the next entry's name or its PAX records is not
      // an entry of its own
      if (metadata.take(tf)) {
        continue;
      }
      metadata.applyTo(tf);
      files.add(tf);

      final filename = tf.filename;

      if (tf.isFile) {
        final file = storeData
            ? ArchiveFile.stream(filename, tf.rawContent!)
            : ArchiveFile.noData(filename);

        file.mode = tf.mode;
        file.ownerId = tf.ownerId;
        file.groupId = tf.groupId;
        file.lastModTime = tf.lastModTime;
        // Every header has the field; only a link has anything in it
        if (tf.nameOfLinkedFile?.isNotEmpty ?? false) {
          file.symbolicLink = tf.nameOfLinkedFile!;
        }

        archive.add(file);

        if (callback != null) {
          callback(file);
        }
      } else {
        final file = ArchiveFile.directory(filename);
        file.mode = tf.mode;
        file.ownerId = tf.ownerId;
        file.groupId = tf.groupId;
        file.lastModTime = tf.lastModTime;
        // Every header has the field; only a link has anything in it
        if (tf.nameOfLinkedFile?.isNotEmpty ?? false) {
          file.symbolicLink = tf.nameOfLinkedFile!;
        }

        archive.add(file);

        if (callback != null) {
          callback(file);
        }
      }
    }

    return archive;
  }
}

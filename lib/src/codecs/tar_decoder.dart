import 'dart:convert';

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../util/archive_exception.dart';
import '../util/decode_guard.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import 'tar/tar_file.dart';

/// Decode a tar formatted buffer into an [Archive] object.
/// A hard link is decoded as [ArchiveFile.symbolicLink] with target relative
/// to archive root and [ArchiveFile.isHardLink] set, so after extraction the
/// link points to its target
class TarDecoder {
  final Encoding filenameEncoding;
  List<TarFile> files = [];

  TarDecoder({this.filenameEncoding = const Utf8Codec()});

  /// Decode [data] as a tar archive. With [verify], every entry's header
  /// checksum is checked and an [ArchiveException] thrown if one is wrong,
  /// which is what tells a tar apart from an unrelated file.
  ///
  /// With [storeData] false the entries hold no content, only their headers
  ///
  /// {@macro archive.decoder_callback}
  ///
  /// {@macro archive.verify_throw_on_error}
  Archive decodeBytes(List<int> data,
      {bool verify = false,
      bool throwOnError = false,
      bool storeData = true,
      ArchiveCallback? callback}) {
    return decodeStream(InputMemoryStream(data),
        verify: verify,
        throwOnError: throwOnError,
        storeData: storeData,
        callback: callback);
  }

  /// Decode [input] as a tar archive. With [verify], every entry's header
  /// checksum is checked and an [ArchiveException] thrown if one is wrong,
  /// which is what tells a tar apart from an unrelated file.
  ///
  /// With [storeData] false the entries hold no content, only their headers
  ///
  /// {@macro archive.decoder_callback}
  ///
  /// {@macro archive.verify_throw_on_error}
  Archive decodeStream(InputStream input,
      {bool verify = false,
      bool throwOnError = false,
      bool storeData = true,
      ArchiveCallback? callback}) {
    final archive = Archive();
    files.clear();
    guardDecode('tar', verify, throwOnError, () {
      _decode(input, archive, verify || throwOnError, storeData, callback);
      return true;
    });
    return archive;
  }

  void _decode(InputStream input, Archive archive, bool verify, bool storeData,
      ArchiveCallback? callback) {
    final metadata = TarMetadata();
    void add(TarFile tf) => _add(archive, tf, storeData, callback);

    // TarFile paxHeader = null;
    while (!input.isEOS) {
      // The end of the archive is a block of zeros; two of them can't be told
      // from a damaged header, which is what verify is there to catch
      final endCheck = input.peekBytes(verify ? 512 : 2).toUint8List();
      if (verify && endCheck.length < 512 && !endCheck.any((b) => b != 0)) {
        throw ArchiveException('Unexpected end of tar data');
      }
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
        if (endCheck.length < 512) {
          throw ArchiveException('Invalid tar header');
        }
        // Tar has no magic bytes, so only the header checksum rejects a file
        // that is not tar. The checksum guards structure, so either flag
        // checks it and a mismatch throws ArchiveException.
        if (!tarHeaderChecksumMatches(endCheck)) {
          throw ArchiveException('Invalid tar header checksum');
        }
      }

      final available = input.length;
      final tf = TarFile.read(input,
          storeData: storeData,
          encoding: filenameEncoding,
          size: metadata.size);
      if (verify && available < 512 + tf.fileSize + tf.padding) {
        throw ArchiveException('Unexpected end of tar data');
      }
      // A header that carries the next entry's name or its PAX records is not
      // an entry of its own
      if (metadata.take(tf, filenameEncoding)) {
        final orphan = metadata.takeOrphan();
        if (orphan != null) {
          add(orphan);
        }
        continue;
      }
      metadata.applyTo(tf);
      final orphan = metadata.takeOrphan();
      if (orphan != null) {
        add(orphan);
      }
      add(tf);
    }
    final orphan = metadata.takeOrphan(true);
    if (orphan != null) {
      add(orphan);
    }
  }

  void _add(
      Archive archive, TarFile tf, bool storeData, ArchiveCallback? callback) {
    files.add(tf);

    final filename = tf.filename;

    final v7Directory = (tf.typeFlag == TarFile.normalFile ||
            tf.typeFlag == '' ||
            tf.typeFlag == '\u0000') &&
        filename.endsWith('/');
    if (tf.isFile && !v7Directory && tf.typeFlag != 'D') {
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
        file.isHardLink = tf.typeFlag == TarFile.hardLink;
      }

      archive.add(file);

      if (callback != null) {
        try {
          callback(file);
        } catch (error, stackTrace) {
          throw CallbackFailure(error, stackTrace);
        }
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
        try {
          callback(file);
        } catch (error, stackTrace) {
          throw CallbackFailure(error, stackTrace);
        }
      }
    }
  }
}

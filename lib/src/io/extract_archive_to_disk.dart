import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import '../archive/archive.dart';
import '../archive/archive_file.dart';
import '../codecs/bzip2_decoder.dart';
import '../codecs/gzip_decoder.dart';
import '../codecs/tar_decoder.dart';
import '../codecs/xz_decoder.dart';
import '../codecs/zip_decoder.dart';
import '../codecs/zstd_decoder.dart';
import '../util/archive_exception.dart';
import '../util/codecs_recognizer.dart';
import '../util/decode_guard.dart';
import '../util/input_file_stream.dart';
import '../util/input_stream.dart';
import '../util/output_file_stream.dart';
import '../util/output_stream.dart';
import 'posix.dart' as posix;

// Ensure filePath is contained in the outputDir folder, to make sure archives
// aren't trying to write to some system path.
bool _isWithinOutputPath(String? realOut, String filePath) {
  final file = _realPath(filePath, followDangling: true);
  return realOut != null && file != null && path.isWithin(realOut, file);
}

bool _isEntryWithinOutputPath(String? realOut, String filePath) {
  final dir = _realPath(path.dirname(filePath));
  return realOut != null &&
      dir != null &&
      path.isWithin(realOut, path.join(dir, path.basename(filePath)));
}

/// canonicalize ignores symlinks out of outputPath, so we resolve them on disk
String? _realPath(String filePath,
    {bool followDangling = false, int depth = 0}) {
  var existing = path.absolute(filePath);
  final rest = <String>[];
  while (FileSystemEntity.typeSync(existing, followLinks: false) ==
      FileSystemEntityType.notFound) {
    if (path.dirname(existing) == existing) {
      return path.canonicalize(filePath);
    }
    rest.insert(0, path.basename(existing));
    existing = path.dirname(existing);
  }
  try {
    return path.joinAll([File(existing).resolveSymbolicLinksSync(), ...rest]);
  } on FileSystemException {
    // A dangling symlink throws, so we follow its target ourselves. A loop
    // stops after 40 links, as on Linux, and the entry counts as outside
    if (!followDangling ||
        depth >= 40 ||
        FileSystemEntity.typeSync(existing, followLinks: false) !=
            FileSystemEntityType.link) {
      return null;
    }
    final target = Link(existing).targetSync();
    return _realPath(
        path.joinAll([
          path.isAbsolute(target)
              ? target
              : path.join(path.dirname(existing), target),
          ...rest
        ]),
        followDangling: true,
        depth: depth + 1);
  }
}

String _entryPath(String outputPath, String name) => path.join(
    outputPath, path.normalize(name.replaceFirst(RegExp(r'^[/\\]+'), '')));

bool _isValidSymLink(
    String outputPath, String? realOut, ArchiveFile file, bool allowAbsolute) {
  final filePath = path.dirname(_entryPath(outputPath, file.name));
  final linkPath = path.normalize(_linkTarget(file));
  if (path.isAbsolute(linkPath)) {
    // Don't allow decoding of files outside of the output path.
    return allowAbsolute;
  }
  final realPath = _realPath(filePath);
  if (realPath == null ||
      !_isWithinOutputPath(realOut, path.join(realPath, linkPath))) {
    // Don't allow decoding of files outside of the output path.
    return false;
  }
  return true;
}

/// A hard link names its target from the archive root and a symlink from its
/// own folder. dart:io cannot make a hard link and a copy would double disk use,
/// so it becomes a symlink with the target rewritten from its folder
String _linkTarget(ArchiveFile file) {
  final text = file.symbolicLink ?? '';
  if (!file.isHardLink) {
    return text;
  }
  String clean(String p) =>
      path.posix.normalize(p.replaceFirst(RegExp('^/+'), ''));
  return path.posix
      .relative(clean(text), from: path.posix.dirname(clean(file.name)));
}

/// Windows needs \ in a relative link target, and normalizing the text would
/// change where a link through another link points
String _linkText(ArchiveFile file) {
  final text = _linkTarget(file);
  return Platform.isWindows ? text.replaceAll('/', r'\') : text;
}

void _clearPath(String filePath) {
  final type = FileSystemEntity.typeSync(filePath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    Link(filePath).deleteSync();
  } else if (type == FileSystemEntityType.file) {
    File(filePath).deleteSync();
  }
}

void _prepareOutDir(String outDirPath) {
  final outDir = Directory(outDirPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }
}

String? _prepareArchiveFilePath(ArchiveFile archiveFile, String outputPath,
    String? realOut, bool allowAbsoluteSymlinks) {
  final filePath = _entryPath(outputPath, archiveFile.name);

  if ((archiveFile.isDirectory && !archiveFile.isSymbolicLink) ||
      !_isEntryWithinOutputPath(realOut, filePath)) {
    return null;
  }

  if (archiveFile.isSymbolicLink) {
    if (!_isValidSymLink(
        outputPath, realOut, archiveFile, allowAbsoluteSymlinks)) {
      return null;
    }
  }

  return filePath;
}

void _extractArchiveEntryToDiskSync(
  ArchiveFile entry,
  String filePath, {
  int? bufferSize,
  bool throwOnError = false,
}) {
  if (entry.isSymbolicLink) {
    _clearPath(filePath);
    final link = Link(filePath);
    link.createSync(_linkText(entry), recursive: true);
  } else {
    if (entry.isFile) {
      _clearPath(filePath);
      final output = OutputFileStream(filePath, bufferSize: bufferSize);
      try {
        entry.writeContent(output);
      } catch (err) {
        if (err is ArchivePasswordException) {
          output.closeSync();
          try {
            File(filePath).deleteSync();
          } catch (_) {}
          rethrow;
        }
        if (!isDecodeDataError(err)) {
          output.closeSync();
          try {
            File(filePath).deleteSync();
          } catch (_) {}
          rethrow;
        }
        if (throwOnError) {
          output.closeSync();
          try {
            File(filePath).deleteSync();
          } catch (_) {}
          rethrow;
        }
        //
        output.closeSync();
        try {
          File(filePath).deleteSync();
        } catch (_) {}
        return;
      }
      output.closeSync();
    } else {
      Directory(filePath).createSync(recursive: true);
    }
  }
}

/// Writes the entries of [archive] into [outputPath]
///
/// With [throwOnError] a damaged entry throws `ArchiveException`, without it
/// the entry is skipped and leaves no file
///
/// {@macro archive.extract.allow_absolute_symlinks}
void extractArchiveToDiskSync(
  Archive archive,
  String outputPath, {
  int? bufferSize,
  bool throwOnError = false,
  bool allowAbsoluteSymlinks = false,
}) {
  _prepareOutDir(outputPath);
  final realOut = _realPath(outputPath);
  for (final entry in archive) {
    final filePath = _prepareArchiveFilePath(
        entry, outputPath, realOut, allowAbsoluteSymlinks);
    if (filePath != null) {
      _extractArchiveEntryToDiskSync(entry, filePath,
          bufferSize: bufferSize, throwOnError: throwOnError);
    }
  }
}

/// Writes the entries of [archive] into [outputPath]
///
/// With [throwOnError] a damaged entry throws `ArchiveException`, without it
/// the entry is skipped and leaves no file
///
/// {@macro archive.extract.allow_absolute_symlinks}
Future<void> extractArchiveToDisk(Archive archive, String outputPath,
    {int? bufferSize,
    bool throwOnError = false,
    bool allowAbsoluteSymlinks = false}) async {
  final outDir = Directory(outputPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }
  final realOut = _realPath(outputPath);

  for (final entry in archive) {
    final filePath = _entryPath(outputPath, entry.name);

    if ((entry.isDirectory && !entry.isSymbolicLink) ||
        !_isEntryWithinOutputPath(realOut, filePath)) {
      continue;
    }

    if (entry.isSymbolicLink) {
      if (!_isValidSymLink(outputPath, realOut, entry, allowAbsoluteSymlinks)) {
        continue;
      }

      _clearPath(filePath);
      final link = Link(filePath);
      await link.create(_linkText(entry), recursive: true);
      continue;
    }

    if (entry.isDirectory) {
      await Directory(filePath).create(recursive: true);
      continue;
    }

    ArchiveFile file = entry;

    bufferSize ??= OutputFileStream.kDefaultBufferSize;
    final fileSize = file.size;
    final fileBufferSize = fileSize < bufferSize ? fileSize : bufferSize;
    _clearPath(filePath);
    final output = OutputFileStream(filePath, bufferSize: fileBufferSize);
    try {
      file.writeContent(output);
    } catch (err) {
      if (err is ArchivePasswordException) {
        await output.close();
        try {
          File(filePath).deleteSync();
        } catch (_) {}
        rethrow;
      }
      if (!isDecodeDataError(err)) {
        await output.close();
        try {
          File(filePath).deleteSync();
        } catch (_) {}
        rethrow;
      }
      if (throwOnError) {
        await output.close();
        try {
          File(filePath).deleteSync();
        } catch (_) {}
        rethrow;
      }
      //
      await output.close();
      try {
        File(filePath).deleteSync();
      } catch (_) {}
      continue;
    }
    await output.close();
  }
}

// a utility function to get the extension of the input file.
String getInputExtension(String inputPath) {
  final lowerPath = inputPath.toLowerCase();
  if (lowerPath.endsWith('.tar.gz')) {
    return '.tar.gz';
  } else if (lowerPath.endsWith('.tar.bz2')) {
    return '.tar.bz2';
  } else if (lowerPath.endsWith('.tar.xz')) {
    return '.tar.xz';
  } else if (lowerPath.endsWith('.tar.zst')) {
    return '.tar.zst';
  }
  return path.extension(lowerPath);
}

/// Extracts the archive at [inputPath] into [outputPath]
///
/// {@macro archive.verify_throw_on_error}
///
/// If neither option is specified, damaged or incomplete entries are skipped,
/// and only complete ones are extracted
///
/// {@macro archive.extract.allow_absolute_symlinks}
Future<void> extractFileToDisk(String inputPath, String outputPath,
    {String? password,
    int? bufferSize,
    ArchiveCallback? callback,
    bool verify = false,
    bool throwOnError = false,
    bool allowAbsoluteSymlinks = false}) async {
  final strict = verify || throwOnError;
  Directory? tempDir;
  var archivePath = inputPath;

  var posixSupported = posix.isPosixSupported();

  const String extensionMsg =
      '.tar.gz, .tgz, .tar.bz2, .tbz, .tar.xz, .txz, .tar.zst, .tzst, .tar '
      'or .zip';

  // get the extension of the input file with up to 2 components
  // e.g. for file.tar.gz, it will return '.tar.gz'
  final archiveExt = getInputExtension(archivePath);

  // Check header to avoid attempts for all formats
  RandomAccessFile? raf;
  Uint8List headerBytes;
  try {
    raf = await File(inputPath).open(mode: FileMode.read);
    headerBytes = await raf.read(CodecsRecognizer.headerBytes);
  } catch (_) {
    headerBytes = Uint8List(0);
  } finally {
    try {
      await raf?.close();
    } catch (_) {
      /* Do nothing */
    }
  }

  ArchiveFormat recognized = CodecsRecognizer.recognize(headerBytes);
  if (recognized == ArchiveFormat.unknown) {
    for (final ArchiveFormat format in ArchiveFormat.values) {
      final ArchiveExtension? aExt = CodecsRecognizer.extensionOf(format);
      if (aExt == null) continue;

      if (archiveExt == '.${aExt.defaultName}' ||
          (aExt.tar != null && archiveExt == '.${aExt.tar}') ||
          (aExt.tarShort != null && archiveExt == '.${aExt.tarShort}')) {
        recognized = format;
        break;
      }
    }
  }

  if (recognized == ArchiveFormat.unknown) {
    throw ArgumentError.value(
      inputPath,
      'inputPath',
      'No file extension detected, must end with $extensionMsg',
    );
  }

  // Each of these throws where the archive ran out part way through.
  // If neither `verify` nor `throwOnError` is set, exceptions are suppressed,
  // and only complete tar entries are extracted
  Future<void> unwrap(
      bool Function(InputStream input, OutputStream output) decode) async {
    final directory = Directory.systemTemp.createTempSync('dart_archive');
    final target = path.join(directory.path, 'temp.tar');
    tempDir = directory;
    archivePath = target;
    final input = InputFileStream(inputPath);
    final output = OutputFileStream(target, bufferSize: bufferSize);
    try {
      decode(input, output);
    } catch (error) {
      if (strict || !isDecodeDataError(error)) {
        rethrow;
      }
    } finally {
      await input.close();
      await output.close();
    }
    recognized = ArchiveFormat.tar;
  }

  InputStream? toClose;
  try {
    if (recognized == ArchiveFormat.gzip) {
      await unwrap((input, output) => GZipDecoder()
          .decodeStream(input, output, verify: verify, throwOnError: true));
    } else if (recognized == ArchiveFormat.bzip2) {
      await unwrap((input, output) => BZip2Decoder()
          .decodeStream(input, output, verify: verify, throwOnError: true));
    } else if (recognized == ArchiveFormat.xz) {
      await unwrap((input, output) => XZDecoder()
          .decodeStream(input, output, verify: verify, throwOnError: true));
    } else if (recognized == ArchiveFormat.zstd) {
      await unwrap((input, output) => ZstdDecoder()
          .decodeStream(input, output, verify: verify, throwOnError: true));
    }

    final whole = Archive();
    Object? callbackError;
    void collect(ArchiveFile file) {
      whole.add(file);
      if (callback != null) {
        try {
          callback(file);
        } catch (error) {
          callbackError = error;
          rethrow;
        }
      }
    }

    Archive archive;
    if (recognized == ArchiveFormat.tar) {
      final input = InputFileStream(archivePath);
      toClose = input;
      // tar has no magic bytes. The file under the gzip or zstd might not be a
      // tar at all. The header checksum rejects it. Without the check a
      // .sql.gz is extracted as tar entries
      // Truncated tar entry throws before it is written. bsdtar and python
      // tarfile leave partial file on disk, but they report error too
      try {
        archive =
            TarDecoder().decodeStream(input, verify: true, callback: collect);
      } catch (error) {
        if (strict ||
            !isDecodeDataError(error) ||
            identical(error, callbackError)) {
          rethrow;
        }
        archive = whole;
      }
    } else if (recognized == ArchiveFormat.zip) {
      final input = InputFileStream(archivePath);
      toClose = input;
      try {
        archive = ZipDecoder().decodeStream(input,
            verify: verify,
            throwOnError: true,
            password: password,
            callback: collect);
      } catch (error) {
        if (strict ||
            !isDecodeDataError(error) ||
            identical(error, callbackError)) {
          rethrow;
        }
        archive = whole;
      }
    } else {
      throw ArgumentError.value(
          inputPath, 'inputPath', 'Must end $extensionMsg');
    }

    final realOut = _realPath(outputPath);
    for (final file in archive) {
      final filePath = _entryPath(outputPath, file.name);
      if (!_isEntryWithinOutputPath(realOut, filePath)) {
        continue;
      }

      if (file.isSymbolicLink) {
        if (!_isValidSymLink(
            outputPath, realOut, file, allowAbsoluteSymlinks)) {
          continue;
        }
      }

      if (file.isDirectory && !file.isSymbolicLink) {
        Directory(filePath).createSync(recursive: true);
        continue;
      }

      if (file.isSymbolicLink) {
        _clearPath(filePath);
        final link = Link(filePath);
        link.createSync(_linkText(file), recursive: true);
      } else if (file.isFile) {
        _clearPath(filePath);
        final output = OutputFileStream(filePath, bufferSize: bufferSize);
        try {
          file.writeContent(output);
        } catch (error) {
          // A partial file from a failed entry looked extracted, so we delete
          // it
          try {
            await output.close();
          } catch (_) {}
          // Windows deleteSync throws on an open file, so we ignore the error
          try {
            File(filePath).deleteSync();
          } catch (_) {}
          if (error is ArchivePasswordException) {
            rethrow;
          }
          if (!isDecodeDataError(error)) {
            rethrow;
          }
          if (strict) {
            rethrow;
          }
          continue;
        }
        if (posixSupported) {
          posix.chmod(filePath, file.unixPermissions.toRadixString(8));
        }

        await output.close();
      }
    }

    await archive.clear();
  } finally {
    // The temporary tar file and its handle are scoped to this call. If an
    // error occurs midway, they are automatically cleaned up to avoid leaving
    // orphaned files in the system temp directory
    await toClose?.close();
    final created = tempDir;
    if (created != null) {
      await created.delete(recursive: true);
    }
  }
}

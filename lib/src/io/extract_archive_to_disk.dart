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
import '../util/input_file_stream.dart';
import '../util/input_stream.dart';
import '../util/output_file_stream.dart';
import '../util/output_stream.dart';
import 'posix.dart' as posix;

// Ensure filePath is contained in the outputDir folder, to make sure archives
// aren't trying to write to some system path.
bool _isWithinOutputPath(String outputDir, String filePath) {
  return path.isWithin(
      path.canonicalize(outputDir), path.canonicalize(filePath));
}

bool _isValidSymLink(String outputPath, ArchiveFile file) {
  final filePath =
      path.dirname(path.join(outputPath, path.normalize(file.name)));
  final linkPath = path.normalize(file.symbolicLink ?? "");
  if (path.isAbsolute(linkPath)) {
    // Don't allow decoding of files outside of the output path.
    return false;
  }
  final absLinkPath = path.normalize(path.join(filePath, linkPath));
  if (!_isWithinOutputPath(outputPath, absLinkPath)) {
    // Don't allow decoding of files outside of the output path.
    return false;
  }
  return true;
}

void _prepareOutDir(String outDirPath) {
  final outDir = Directory(outDirPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }
}

String? _prepareArchiveFilePath(ArchiveFile archiveFile, String outputPath) {
  final filePath = path.join(outputPath, path.normalize(archiveFile.name));

  if ((archiveFile.isDirectory && !archiveFile.isSymbolicLink) ||
      !_isWithinOutputPath(outputPath, filePath)) {
    return null;
  }

  if (archiveFile.isSymbolicLink) {
    if (!_isValidSymLink(outputPath, archiveFile)) {
      return null;
    }
  }

  return filePath;
}

void _extractArchiveEntryToDiskSync(
  ArchiveFile entry,
  String filePath, {
  int? bufferSize,
}) {
  if (entry.isSymbolicLink) {
    final link = Link(filePath);
    link.createSync(path.normalize(entry.symbolicLink ?? ""), recursive: true);
  } else {
    if (entry.isFile) {
      final output = OutputFileStream(filePath, bufferSize: bufferSize);
      try {
        entry.writeContent(output);
      } catch (err) {
        //
      }
      output.closeSync();
    } else {
      Directory(filePath).createSync(recursive: true);
    }
  }
}

void extractArchiveToDiskSync(
  Archive archive,
  String outputPath, {
  int? bufferSize,
}) {
  _prepareOutDir(outputPath);
  for (final entry in archive) {
    final filePath = _prepareArchiveFilePath(entry, outputPath);
    if (filePath != null) {
      _extractArchiveEntryToDiskSync(entry, filePath, bufferSize: bufferSize);
    }
  }
}

Future<void> extractArchiveToDisk(Archive archive, String outputPath,
    {int? bufferSize}) async {
  final outDir = Directory(outputPath);
  if (!outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }

  for (final entry in archive) {
    final filePath = path.normalize(path.join(outputPath, entry.name));

    if ((entry.isDirectory && !entry.isSymbolicLink) ||
        !_isWithinOutputPath(outputPath, filePath)) {
      continue;
    }

    if (entry.isSymbolicLink) {
      if (!_isValidSymLink(outputPath, entry)) {
        continue;
      }

      final link = Link(filePath);
      await link.create(path.normalize(entry.symbolicLink ?? ""),
          recursive: true);
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
    final output = OutputFileStream(filePath, bufferSize: fileBufferSize);
    try {
      file.writeContent(output);
    } catch (err) {
      //
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

Future<void> extractFileToDisk(String inputPath, String outputPath,
    {String? password, int? bufferSize, ArchiveCallback? callback}) async {
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
    await raf?.close();
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

  // Each of these returns false where the archive ran out part way through.
  // Dropping that leaves a truncated tar behind, and the entries that did
  // arrive are then extracted as if the whole thing had been read
  Future<void> unwrap(
      bool Function(InputStream input, OutputStream output) decode,
      String what) async {
    final directory = Directory.systemTemp.createTempSync('dart_archive');
    final target = path.join(directory.path, 'temp.tar');
    tempDir = directory;
    archivePath = target;
    final input = InputFileStream(inputPath);
    final output = OutputFileStream(target, bufferSize: bufferSize);
    final bool ok;
    try {
      ok = decode(input, output);
    } finally {
      await input.close();
      await output.close();
    }
    if (!ok) {
      throw ArchiveException('Could not read the whole $what archive');
    }
    recognized = ArchiveFormat.tar;
  }

  InputStream? toClose;
  try {
    if (recognized == ArchiveFormat.gzip) {
      await unwrap(
          (input, output) => GZipDecoder().decodeStream(input, output), 'gzip');
    } else if (recognized == ArchiveFormat.bzip2) {
      await unwrap(
          (input, output) => BZip2Decoder().decodeStream(input, output),
          'bzip2');
    } else if (recognized == ArchiveFormat.xz) {
      await unwrap(
          (input, output) => XZDecoder().decodeStream(input, output), 'xz');
    } else if (recognized == ArchiveFormat.zstd) {
      await unwrap(
          (input, output) => ZstdDecoder().decodeStream(input, output), 'zstd');
    }

    Archive archive;
    if (recognized == ArchiveFormat.tar) {
      final input = InputFileStream(archivePath);
      toClose = input;
      // tar has no magic bytes. The file under the gzip or zstd might not be a
      // tar at all. The header checksum rejects it. Without the check a
      // .sql.gz is extracted as tar entries
      archive =
          TarDecoder().decodeStream(input, verify: true, callback: callback);
    } else if (recognized == ArchiveFormat.zip) {
      final input = InputFileStream(archivePath);
      toClose = input;
      archive = ZipDecoder()
          .decodeStream(input, password: password, callback: callback);
    } else {
      throw ArgumentError.value(
          inputPath, 'inputPath', 'Must end $extensionMsg');
    }

    for (final file in archive) {
      final filePath = path.join(outputPath, path.normalize(file.name));
      if (!_isWithinOutputPath(outputPath, filePath)) {
        continue;
      }

      if (file.isSymbolicLink) {
        if (!_isValidSymLink(outputPath, file)) {
          continue;
        }
      }

      if (file.isDirectory && !file.isSymbolicLink) {
        Directory(filePath).createSync(recursive: true);
        continue;
      }

      if (file.isSymbolicLink) {
        final link = Link(filePath);
        final p = path.normalize(file.symbolicLink ?? "");
        link.createSync(p, recursive: true);
      } else if (file.isFile) {
        final output = OutputFileStream(filePath, bufferSize: bufferSize);
        try {
          file.writeContent(output);
        } catch (_) {}
        if (posixSupported) {
          posix.chmod(filePath, file.unixPermissions.toRadixString(8));
        }

        await output.close();
      }
    }

    await archive.clear();
  } finally {
    // The temporary tar and the handle on it are this call's, so a failure part
    // way through takes them with it rather than leaving them in the system
    // temporary directory
    await toClose?.close();
    final created = tempDir;
    if (created != null) {
      await created.delete(recursive: true);
    }
  }
}

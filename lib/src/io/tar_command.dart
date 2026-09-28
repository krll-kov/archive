// ignore_for_file: avoid_print
import 'dart:io';

import '../../archive_io.dart';

/// Print the entries in the given tar file.
void listTarFiles(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    _fail('$path does not exist');
  }

  final input = InputFileStream(path);
  final dir = Directory.systemTemp.createTempSync('foo');
  final tempTarPath = '${dir.path}${Platform.pathSeparator}temp.tar';
  final output = OutputFileStream(tempTarPath);
  InputFileStream? tarInput;
  try {
    var tarPath = path;

    //List<int> data = file.readAsBytesSync();
    if (path.endsWith('tar.gz') || path.endsWith('tgz')) {
      GZipDecoder().decodeStream(input, output, throwOnError: true);
      tarPath = tempTarPath;
    } else if (path.endsWith('tar.bz2') || path.endsWith('tbz')) {
      BZip2Decoder().decodeStream(input, output, throwOnError: true);
      tarPath = tempTarPath;
    }
    output.closeSync();

    tarInput = InputFileStream(tarPath);

    final tarArchive = TarDecoder();
    // Tell the decoder not to store the actual file data since we don't need
    // it.
    tarArchive.decodeStream(tarInput, throwOnError: true, storeData: false);

    print('${tarArchive.files.length} file(s)');
    for (final f in tarArchive.files) {
      print('  $f');
    }
  } finally {
    input.closeSync();
    output.closeSync();
    tarInput?.closeSync();
    dir.deleteSync(recursive: true);
  }
}

/// Extract the entries in the given tar file to a directory.
Directory extractTarFiles(String inputPath, String outputPath) {
  Directory? tempDir;
  var tarPath = inputPath;

  try {
    if (inputPath.endsWith('tar.gz') || inputPath.endsWith('tgz')) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      tarPath = '${tempDir.path}${Platform.pathSeparator}temp.tar';
      final input = InputFileStream(inputPath);
      final tarOutput = OutputFileStream(tarPath);
      try {
        GZipDecoder().decodeStream(input, tarOutput, throwOnError: true);
      } finally {
        input.closeSync();
        tarOutput.closeSync();
      }
    }

    final outDir = Directory(outputPath);
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    final input = InputFileStream(tarPath);
    try {
      final tarArchive = TarDecoder().decodeStream(input, throwOnError: true);

      for (final entry in tarArchive) {
        final path = '$outputPath${Platform.pathSeparator}${entry.name}';
        if (entry.isDirectory) {
          Directory(path).createSync(recursive: true);
        } else {
          final output = OutputFileStream(path);
          try {
            entry.writeContent(output);
            print('  extracted ${path}');
          } finally {
            output.closeSync();
          }
        }
      }

      input.closeSync();
      tarArchive.clearSync();
    } finally {
      input.closeSync();
    }

    return outDir;
  } finally {
    tempDir?.deleteSync(recursive: true);
  }
}

Future<void> createTarFile(String dirPath) async {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) {
    _fail('$dirPath does not exist');
  }

  // Encode a directory from disk to disk, no memory
  final encoder = TarFileEncoder();
  await encoder.tarDirectory(dir, compression: TarFileEncoder.gzip);
}

void _fail(String message) {
  print(message);
  exit(1);
}

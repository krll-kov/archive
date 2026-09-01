import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Compresses [input] by shelling out to xz, so that the archives under test
// are made by the reference implementation rather than by this package.
Uint8List xzCompress(Uint8List input, List<String> args) {
  final dir = Directory.systemTemp.createTempSync('archive_xz_parallel');
  try {
    final file = File(p.join(dir.path, 'input.bin'))..writeAsBytesSync(input);
    final result = Process.runSync('xz', [...args, '-z', '-c', file.path],
        stdoutEncoding: null);
    if (result.exitCode != 0) {
      throw StateError('xz exited with ${result.exitCode}: ${result.stderr}');
    }
    return Uint8List.fromList(result.stdout as List<int>);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Where one block sits in an archive, as reported by xz itself.
class BlockInfo {
  final int compOffset;
  final int uncompOffset;
  final int totalSize;
  final int uncompSize;
  final int headerSize;

  BlockInfo(this.compOffset, this.uncompOffset, this.totalSize, this.uncompSize,
      this.headerSize);

  /// Offset of the first byte of compressed data, past the block header.
  int get dataOffset => compOffset + headerSize;

  /// Offset of the check field, which is the tail of the block.
  int checkOffset(int checkSize) => compOffset + totalSize - checkSize;
}

/// Asks xz where the blocks of [archivePath] are, so that a test can corrupt
/// one block on purpose rather than a byte somewhere in the middle.
List<BlockInfo> blocksOf(String archivePath) {
  final result = Process.runSync('xz', ['--robot', '-l', '-vv', archivePath]);
  final blocks = <BlockInfo>[];
  for (final line in (result.stdout as String).split('\n')) {
    final fields = line.split('\t');
    if (fields.isEmpty || fields[0] != 'block') {
      continue;
    }
    blocks.add(BlockInfo(
      int.parse(fields[4]),
      int.parse(fields[5]),
      int.parse(fields[6]),
      int.parse(fields[7]),
      int.parse(fields[11]),
    ));
  }
  return blocks;
}

/// Compresses [input] and reports where its blocks ended up.
({Uint8List bytes, List<BlockInfo> blocks}) buildArchive(
    Uint8List input, List<String> args) {
  final dir = Directory.systemTemp.createTempSync('archive_xz_blocks');
  try {
    final source = File(p.join(dir.path, 'input.bin'))..writeAsBytesSync(input);
    final result = Process.runSync('xz', [...args, '-z', '-f', source.path]);
    if (result.exitCode != 0) {
      throw StateError('xz exited with ${result.exitCode}: ${result.stderr}');
    }
    final archivePath = '${source.path}.xz';
    return (
      bytes: File(archivePath).readAsBytesSync(),
      blocks: blocksOf(archivePath),
    );
  } finally {
    dir.deleteSync(recursive: true);
  }
}

bool get hasXz {
  try {
    return Process.runSync('xz', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Something that compresses well enough to be worth several blocks, with
/// enough variety that a block boundary landing in the wrong place shows up.
Uint8List sampleData(int length) {
  final data = Uint8List(length);
  var state = 0x2545f491;
  for (var i = 0; i < length; i++) {
    state ^= (state << 13) & 0xffffffff;
    state ^= state >> 17;
    state ^= (state << 5) & 0xffffffff;
    // Mostly a repeating pattern, with occasional noise.
    data[i] = (i % 251) ^ ((state & 0xff) < 16 ? state & 0xff : 0);
  }
  return data;
}

Future<Uint8List> decodeBytesOnIsolates(Uint8List compressed,
    {bool verify = false, int? workers, int? memoryBudget}) {
  final completer = Completer<Uint8List>();
  final returned = XZDecoder().decodeBytes(compressed,
      verify: verify,
      multithread: XZMultithreadOptions(
        onDone: completer.complete,
        onError: completer.completeError,
        workers: workers,
        memoryBudget: memoryBudget,
      ));
  // Documented: in multithreaded mode the return value carries nothing.
  expect(returned, isEmpty);
  return completer.future;
}

Future<bool> decodeStreamOnIsolates(InputStream input, OutputStream output,
    {bool verify = false, int? workers, int? memoryBudget}) {
  final completer = Completer<bool>();
  final returned = XZDecoder().decodeStream(input, output,
      verify: verify,
      multithread: XZMultithreadOptions(
        onDone: completer.complete,
        onError: completer.completeError,
        workers: workers,
        memoryBudget: memoryBudget,
      ));
  expect(returned, isFalse);
  return completer.future;
}

void main() {
  group('xz multithreaded', () {
    final expected = sampleData(1200000);

    setUpAll(() {
      if (!hasXz) {
        throw StateError(
            'the xz command line tool is required for these tests');
      }
    });

    test('multi block archive matches the single threaded decode', () async {
      final compressed =
          xzCompress(expected, ['--block-size=65536', '--lzma2=preset=1']);
      // A single block would make the whole exercise pointless.
      expect(XZDecoder().uncompressedSize(compressed), expected.length);

      final sequential = XZDecoder().decodeBytes(compressed);
      final parallel = await decodeBytesOnIsolates(compressed, workers: 4);

      expect(sequential, equals(expected));
      expect(parallel, equals(expected));
    });

    test('applies the BCJ x86 filter across blocks', () async {
      final compressed = xzCompress(
          expected, ['--block-size=65536', '--x86', '--lzma2=preset=1']);
      final parallel = await decodeBytesOnIsolates(compressed, workers: 4);
      expect(parallel, equals(expected));
      expect(XZDecoder().decodeBytes(compressed), equals(expected));
    });

    test('verifies CRC32 while streaming the output back', () async {
      final compressed = xzCompress(expected,
          ['--block-size=65536', '--check=crc32', '--lzma2=preset=1']);
      final parallel =
          await decodeBytesOnIsolates(compressed, verify: true, workers: 4);
      expect(parallel, equals(expected));
    });

    test('verifies CRC64 while streaming the output back', () async {
      final compressed = xzCompress(expected,
          ['--block-size=65536', '--check=crc64', '--lzma2=preset=1']);
      final parallel =
          await decodeBytesOnIsolates(compressed, verify: true, workers: 4);
      expect(parallel, equals(expected));
    });

    group('corrupt archives', () {
      late Uint8List pristine;
      late List<BlockInfo> blocks;

      setUp(() {
        final built =
            buildArchive(expected, ['--block-size=65536', '--lzma2=preset=1']);
        pristine = built.bytes;
        blocks = built.blocks;
        // Several blocks, so that a corrupt one has intact neighbours.
        expect(blocks.length, greaterThan(4));
      });

      // Whatever a failed decode hands back has to be genuine as far as it
      // goes: a prefix of the real data, never bytes that were never there.
      void expectGenuinePrefix(Uint8List result, String label) {
        expect(result.length, lessThanOrEqualTo(expected.length),
            reason: label);
        expect(
            result, equals(Uint8List.sublistView(expected, 0, result.length)),
            reason: label);
      }

      Uint8List damaged(int offset, [int runLength = 64]) {
        final data = Uint8List.fromList(pristine);
        for (var i = 0; i < runLength; i++) {
          data[offset + i] ^= 0xff;
        }
        return data;
      }

      test('a corrupt second block leaves the first one intact', () async {
        final data = damaged(blocks[1].dataOffset + 8);

        final sequential = XZDecoder().decodeBytes(data);
        final parallel = await decodeBytesOnIsolates(data, workers: 4);

        expectGenuinePrefix(sequential, 'sequential');
        expectGenuinePrefix(parallel, 'parallel');
        // The undamaged first block survives in both.
        expect(sequential.length, greaterThanOrEqualTo(blocks[1].uncompOffset));
        expect(parallel.length, greaterThanOrEqualTo(blocks[1].uncompOffset));
        // And neither pretends the rest of the archive decoded.
        expect(sequential.length, lessThan(expected.length));
        expect(parallel.length, lessThan(expected.length));

        expect(
            XZDecoder()
                .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
            isFalse);
        expect(
            await decodeStreamOnIsolates(
                InputMemoryStream(data), OutputMemoryStream(),
                workers: 4),
            isFalse);
      });

      test('a corrupt first block fails both modes', () async {
        final data = damaged(blocks[0].dataOffset + 8);

        expectGenuinePrefix(XZDecoder().decodeBytes(data), 'sequential');
        expectGenuinePrefix(
            await decodeBytesOnIsolates(data, workers: 4), 'parallel');

        expect(
            XZDecoder()
                .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
            isFalse);
        expect(
            await decodeStreamOnIsolates(
                InputMemoryStream(data), OutputMemoryStream(),
                workers: 4),
            isFalse);
      });

      test('a corrupt block is caught with verify even at the last byte',
          () async {
        // Only the check field is damaged, so the data still decodes. Nothing
        // but the checksum can tell that this archive is not what was stored.
        final data = damaged(blocks[1].checkOffset(8), 8);

        // Without verification both modes decode it happily, as documented.
        expect(XZDecoder().decodeBytes(data), equals(expected));
        expect(await decodeBytesOnIsolates(data, workers: 4), equals(expected));

        // With verification both refuse it.
        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(data), OutputMemoryStream(),
                verify: true),
            isFalse);
        expect(
            await decodeStreamOnIsolates(
                InputMemoryStream(data), OutputMemoryStream(),
                verify: true, workers: 4),
            isFalse);

        // The parallel decode stops at the block whose check failed rather
        // than handing back bytes it could not vouch for.
        final parallel =
            await decodeBytesOnIsolates(data, verify: true, workers: 4);
        expectGenuinePrefix(parallel, 'parallel');
        expect(parallel.length, equals(blocks[1].uncompOffset));
      });

      test('a truncated archive fails both modes', () async {
        // The index and the footer are gone, so the layout cannot be read and
        // the parallel path has to fall back to decoding the stream whole.
        final data = Uint8List.sublistView(pristine, 0, pristine.length - 40);
        expect(XZDecoder().uncompressedSize(data), isNull);

        expectGenuinePrefix(XZDecoder().decodeBytes(data), 'sequential');
        expectGenuinePrefix(
            await decodeBytesOnIsolates(data, workers: 4), 'parallel');

        expect(
            XZDecoder()
                .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
            isFalse);
        expect(
            await decodeStreamOnIsolates(
                InputMemoryStream(data), OutputMemoryStream(),
                workers: 4),
            isFalse);
      });

      test('a corrupt index falls back and still fails cleanly', () async {
        // Land inside the index, which sits between the last block and the
        // twelve byte footer.
        final data = damaged(pristine.length - 12 - 8, 4);
        expect(XZDecoder().uncompressedSize(data), isNull);

        expectGenuinePrefix(XZDecoder().decodeBytes(data), 'sequential');
        expectGenuinePrefix(
            await decodeBytesOnIsolates(data, workers: 4), 'parallel');

        expect(
            await decodeStreamOnIsolates(
                InputMemoryStream(data), OutputMemoryStream(),
                workers: 4),
            isFalse);
      });

      test('a corrupt block in a file source behaves the same', () async {
        final data = damaged(blocks[2].dataOffset + 8);
        final dir = Directory.systemTemp.createTempSync('archive_xz_corrupt');
        try {
          final archivePath = p.join(dir.path, 'data.xz');
          File(archivePath).writeAsBytesSync(data);

          final input = InputFileStream(archivePath);
          final output = OutputFileStream(p.join(dir.path, 'out.bin'));
          final ok = await decodeStreamOnIsolates(input, output, workers: 4);
          await input.close();
          await output.close();

          expect(ok, isFalse);
          expectGenuinePrefix(
              File(p.join(dir.path, 'out.bin')).readAsBytesSync(), 'file');
        } finally {
          dir.deleteSync(recursive: true);
        }
      });
    });

    test('one worker still decodes the whole archive', () async {
      final compressed =
          xzCompress(expected, ['--block-size=65536', '--lzma2=preset=1']);
      expect(await decodeBytesOnIsolates(compressed, workers: 1),
          equals(expected));
    });

    test('a worker count above the core count is clamped, not rejected',
        () async {
      final compressed =
          xzCompress(expected, ['--block-size=65536', '--lzma2=preset=1']);
      expect(await decodeBytesOnIsolates(compressed, workers: 999),
          equals(expected));
    });

    test('a memory budget too small for two workers still decodes', () async {
      final compressed =
          xzCompress(expected, ['--block-size=65536', '--lzma2=preset=1']);
      expect(
          await decodeBytesOnIsolates(compressed, workers: 8, memoryBudget: 1),
          equals(expected));
    });

    test('rejects settings that cannot be honoured', () {
      // These all feed the arithmetic that sizes the pool, where a nonsense
      // value does not fail loudly. A negative read buffer in particular makes
      // the per worker cost come out negative, which skips the memory budget
      // and hands out more workers than the budget allows.
      final compressed =
          xzCompress(expected, ['--block-size=65536', '--lzma2=preset=1']);
      final cases = <String, XZMultithreadOptions<Uint8List>>{
        'workers: 0': XZMultithreadOptions(onDone: (_) {}, workers: 0),
        'workers: -1': XZMultithreadOptions(onDone: (_) {}, workers: -1),
        'memoryBudget: 0':
            XZMultithreadOptions(onDone: (_) {}, memoryBudget: 0),
        'memoryBudget: -1':
            XZMultithreadOptions(onDone: (_) {}, memoryBudget: -1),
        'fileReadBufferSize: 0':
            XZMultithreadOptions(onDone: (_) {}, fileReadBufferSize: 0),
        'fileReadBufferSize negative': XZMultithreadOptions(
            onDone: (_) {}, fileReadBufferSize: -300000000),
      };
      cases.forEach((label, options) {
        expect(() => XZDecoder().decodeBytes(compressed, multithread: options),
            throwsArgumentError,
            reason: label);
      });
    });

    test('accepts the smallest settings that make sense', () async {
      final compressed =
          xzCompress(expected, ['--block-size=65536', '--lzma2=preset=1']);
      final completer = Completer<Uint8List>();
      XZDecoder().decodeBytes(compressed,
          multithread: XZMultithreadOptions(
            onDone: completer.complete,
            onError: completer.completeError,
            workers: 1,
            memoryBudget: 1,
            fileReadBufferSize: 1,
          ));
      expect(await completer.future, equals(expected));
    });

    test('a single block archive still reports through onDone', () async {
      final compressed = xzCompress(expected, ['--lzma2=preset=1']);
      expect(await decodeBytesOnIsolates(compressed), equals(expected));
    });

    test('decodes concatenated streams', () async {
      final file = File(p.join('test/_data/xz/hello-hello-hello.xz'));
      final compressed = file.readAsBytesSync();
      expect(await decodeBytesOnIsolates(compressed),
          equals(XZDecoder().decodeBytes(compressed)));
    });

    test('decodes every archive in the test data the same way', () async {
      final dir = Directory('test/_data/xz');
      for (final entry in dir.listSync()) {
        if (entry is! File || !entry.path.endsWith('.xz')) {
          continue;
        }
        final compressed = entry.readAsBytesSync();
        final sequential = XZDecoder().decodeBytes(compressed);
        final parallel = await decodeBytesOnIsolates(compressed);
        expect(parallel, equals(sequential), reason: entry.path);
      }
    });

    test('uncompressedSize agrees with what is decoded', () {
      final dir = Directory('test/_data/xz');
      for (final entry in dir.listSync()) {
        if (entry is! File || !entry.path.endsWith('.xz')) {
          continue;
        }
        final compressed = entry.readAsBytesSync();
        final size = XZDecoder().uncompressedSize(compressed);
        if (size == null) {
          continue;
        }
        // Some of the archives here are deliberately corrupt in their payload
        // while carrying an intact index, so the size is readable even though
        // the data is not.
        if (!XZDecoder().decodeStream(
            InputMemoryStream(compressed), OutputMemoryStream())) {
          continue;
        }
        expect(size, equals(XZDecoder().decodeBytes(compressed).length),
            reason: entry.path);
      }
    });

    test('streams a file straight from disk into a file', () async {
      final compressed =
          xzCompress(expected, ['--block-size=65536', '--lzma2=preset=1']);
      final dir = Directory.systemTemp.createTempSync('archive_xz_files');
      try {
        final archivePath = p.join(dir.path, 'data.xz');
        File(archivePath).writeAsBytesSync(compressed);
        final outputPath = p.join(dir.path, 'data.bin');

        final input = InputFileStream(archivePath);
        final output = OutputFileStream(outputPath);
        final ok = await decodeStreamOnIsolates(input, output, workers: 4);
        await input.close();
        await output.close();

        expect(ok, isTrue);
        expect(File(outputPath).readAsBytesSync(), equals(expected));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('repeated file decodes do not leak file handles', () async {
      // A killed isolate does not release its file descriptors, so a worker
      // that kept the archive open between blocks would leak one per decode.
      final compressed =
          xzCompress(expected, ['--block-size=65536', '--lzma2=preset=1']);
      final dir = Directory.systemTemp.createTempSync('archive_xz_handles');
      try {
        final archivePath = p.join(dir.path, 'data.xz');
        File(archivePath).writeAsBytesSync(compressed);
        final outputPath = p.join(dir.path, 'data.bin');

        for (var round = 0; round < 8; round++) {
          final input = InputFileStream(archivePath);
          final output = OutputFileStream(outputPath);
          final ok = await decodeStreamOnIsolates(input, output, workers: 4);
          await input.close();
          await output.close();
          expect(ok, isTrue);
        }

        if (Platform.isMacOS || Platform.isLinux) {
          final lsof = Process.runSync('sh', [
            '-c',
            'lsof -p $pid 2>/dev/null | grep -c "${p.basename(archivePath)}"'
          ]);
          expect(int.tryParse((lsof.stdout as String).trim()), 0);
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('exposes the file region a stream reads from', () {
      final compressed =
          xzCompress(expected, ['--block-size=65536', '--lzma2=preset=1']);
      final dir = Directory.systemTemp.createTempSync('archive_xz_region');
      try {
        final path = p.join(dir.path, 'data.xz');
        File(path).writeAsBytesSync(compressed);

        // These are what let the decoder find the file behind a stream and
        // hand disjoint ranges of it to isolates.
        final whole = InputFileStream(path);
        expect(whole.fileOffset, 0);
        expect(whole.fileLength, compressed.length);
        expect(whole.fileBuffer.length, compressed.length);

        final part =
            InputFileStream.fromFileStream(whole, position: 64, length: 128);
        expect(part.fileOffset, 64);
        expect(part.fileLength, 128);

        whole.closeSync();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('falls back for a stream that is neither memory nor a file', () async {
      // A RAM backed file stream has no path for workers to read, so it is
      // documented to decode on the calling isolate, still reporting through
      // onDone.
      final compressed =
          xzCompress(expected, ['--block-size=65536', '--lzma2=preset=1']);
      final input = await InputFileStream.asRamFile(
          Stream.value(compressed), compressed.length);
      final output = OutputMemoryStream();

      final ok = await decodeStreamOnIsolates(input, output, workers: 4);

      expect(ok, isTrue);
      expect(output.getBytes(), equals(expected));
    });

    test('streams memory into a memory stream in block order', () async {
      final compressed =
          xzCompress(expected, ['--block-size=65536', '--lzma2=preset=1']);
      final output = OutputMemoryStream();
      final ok = await decodeStreamOnIsolates(
          InputMemoryStream(compressed), output,
          workers: 4);
      expect(ok, isTrue);
      expect(output.getBytes(), equals(expected));
    });
  });
}

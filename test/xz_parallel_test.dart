import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/src/codecs/xz/xz_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The archives under test are made by the reference tool, not by this package,
// so they are kept as fixtures rather than written here: a test suite runs
// where no xz binary does. Each one is `sampleData(1200000)` through
// `xz -z -c` with these options, and `huge` is 48 blocks of 64 MiB of zeros
// through `xz -0 -T4 --block-size=64MiB`:
//   blocks       --block-size=65536 --lzma2=preset=1
//   whole        --lzma2=preset=1
//   crc64        --check=crc64 --lzma2=preset=1
//   crc32        --block-size=65536 --check=crc32 --lzma2=preset=1
//   crc64-blocks --block-size=65536 --check=crc64 --lzma2=preset=1
//   x86          --block-size=65536 --x86 --lzma2=preset=1
Uint8List fixture(String name) =>
    File('test/_data/xz/parallel/$name.xz').readAsBytesSync();

/// Where one block sits in an archive, read from the index the archive carries
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

/// The blocks of [bytes], so that a test can damage one block on purpose
/// rather than a byte somewhere in the middle
List<BlockInfo> blocksOf(Uint8List bytes) {
  final layout = parseXZLayout(XZMemorySource(bytes))!;
  return [
    for (final block in layout.blocks)
      BlockInfo(
        block.compressedOffset,
        block.outputOffset,
        block.compressedLength,
        block.uncompressedLength,
        (bytes[block.compressedOffset] + 1) * 4,
      ),
  ];
}

/// A fixture and where its blocks are
({Uint8List bytes, List<BlockInfo> blocks}) buildArchive(String name) {
  final bytes = fixture(name);
  return (bytes: bytes, blocks: blocksOf(bytes));
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

    test('multi block archive matches the single threaded decode', () async {
      final compressed =
          fixture('blocks');
      // A single block would make the whole exercise pointless.
      expect(XZDecoder().uncompressedSize(compressed), expected.length);

      final sequential = XZDecoder().decodeBytes(compressed);
      final parallel = await decodeBytesOnIsolates(compressed, workers: 4);

      expect(sequential, equals(expected));
      expect(parallel, equals(expected));
    });

    test('applies the BCJ x86 filter across blocks', () async {
      final compressed = fixture('x86');
      final parallel = await decodeBytesOnIsolates(compressed, workers: 4);
      expect(parallel, equals(expected));
      expect(XZDecoder().decodeBytes(compressed), equals(expected));
    });

    test('verifies CRC32 while streaming the output back', () async {
      final compressed = fixture('crc32');
      final parallel =
          await decodeBytesOnIsolates(compressed, verify: true, workers: 4);
      expect(parallel, equals(expected));
    });

    test('verifies CRC64 while streaming the output back', () async {
      final compressed = fixture('crc64-blocks');
      final parallel =
          await decodeBytesOnIsolates(compressed, verify: true, workers: 4);
      expect(parallel, equals(expected));
    });

    group('corrupt archives', () {
      late Uint8List pristine;
      late List<BlockInfo> blocks;

      setUp(() {
        final built =
            buildArchive('blocks');
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

      test('throwOnError reports a bad block while the index still reads',
          () async {
        // Truncating an archive takes its index with it, which sends the
        // decode down the growing buffer path. Damaging a block in place
        // leaves the index readable, so the output is allocated up front from
        // it, and that is a separate place for the failure to be noticed.
        final data = damaged(blocks[1].dataOffset + 8);
        expect(XZDecoder().uncompressedSize(data), equals(expected.length));

        final completer = Completer<Object?>();
        XZDecoder().decodeBytes(data,
            throwOnError: true,
            multithread: XZMultithreadOptions<Uint8List>(
              onDone: (r) => completer.complete(r),
              onError: (e, _) => completer.complete(e),
              workers: 4,
            ));
        expect(await completer.future, isA<ArchiveException>());

        expect(() => XZDecoder().decodeBytes(data, throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });

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

        // Both stop in the same place, and that place is the end of the block
        // whose check failed: writing straight through to an output stream
        // cannot take those bytes back, so the single threaded decode leaves
        // them behind and the parallel one matches it rather than inventing a
        // stricter rule for itself. Neither vouches for them; both reported
        // the failure above.
        final sequential = XZDecoder().decodeBytes(data, verify: true);
        final parallel =
            await decodeBytesOnIsolates(data, verify: true, workers: 4);
        expectGenuinePrefix(sequential, 'sequential');
        expectGenuinePrefix(parallel, 'parallel');
        expect(parallel.length, equals(sequential.length));
        expect(parallel.length,
            equals(blocks[1].uncompOffset + blocks[1].uncompSize));
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
          fixture('blocks');
      expect(await decodeBytesOnIsolates(compressed, workers: 1),
          equals(expected));
    });

    test('a worker count above the core count is clamped, not rejected',
        () async {
      final compressed =
          fixture('blocks');
      expect(await decodeBytesOnIsolates(compressed, workers: 999),
          equals(expected));
    });

    test('a memory budget too small for two workers still decodes', () async {
      final compressed =
          fixture('blocks');
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
          fixture('blocks');
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
          fixture('blocks');
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
      final compressed = fixture('whole');
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
          fixture('blocks');
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
      // that kept the archive open between blocks would leak four a round.
      // Enough rounds and that runs the process out of descriptors, and the
      // round that cannot open the archive fails here: no tool has to be asked
      // how many are open, the limit answers.
      final dir = Directory.systemTemp.createTempSync('archive_xz_handles');
      try {
        final archivePath = p.join(dir.path, 'data.xz');
        File(archivePath).writeAsBytesSync(fixture('blocks'));
        final outputPath = p.join(dir.path, 'data.bin');

        for (var round = 0; round < 256; round++) {
          final input = InputFileStream(archivePath);
          final output = OutputFileStream(outputPath);
          final ok = await decodeStreamOnIsolates(input, output, workers: 4);
          await input.close();
          await output.close();
          expect(ok, isTrue, reason: 'round $round');
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('splits an archive whose output is too large to preallocate',
        () async {
      // Above the ceiling on preallocation, decodeBytes cannot take the size in
      // the index on trust and grows its buffer instead. That is about the
      // buffer, not about the work: the blocks still have to be handed out to
      // isolates, and an earlier version fell back to a single one here, which
      // cost about ninefold on a three gigabyte archive.
      //
      // Off by default because it allocates over three gigabytes.
      // Zeros reach ratios in the thousands, so the fixture stays small.
      final compressed = fixture('huge');
      // Beyond the ceiling the size is not reported at all.
      expect(XZDecoder().uncompressedSize(compressed), isNull);

      final decoded = await decodeBytesOnIsolates(compressed, workers: 4);
      expect(decoded.length, equals(48 * 64 * 1024 * 1024));
      expect(decoded[0], 0);
      expect(decoded[decoded.length - 1], 0);
    },
        skip: Platform.environment['ARCHIVE_SLOW_TESTS'] == null
            ? 'set ARCHIVE_SLOW_TESTS=1 to run; needs over 3 GB of memory'
            : null);

    test('exposes the file region a stream reads from', () {
      final compressed =
          fixture('blocks');
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
          fixture('blocks');
      final input = await InputFileStream.asRamFile(
          Stream.value(compressed), compressed.length);
      final output = OutputMemoryStream();

      final ok = await decodeStreamOnIsolates(input, output, workers: 4);

      expect(ok, isTrue);
      expect(output.getBytes(), equals(expected));
    });

    test('keeps the same partial output when a block fails while verifying',
        () async {
      // Verifying a CRC32 or CRC64 check makes the decoder keep the block, so
      // that it can be summed after the fact. That buffer used to be dropped
      // when the block failed part way through, but only for outputs that
      // cannot be read back: writing to memory took the other branch and kept
      // what had been decoded. Workers always write to a port, so a corrupt
      // archive gave nothing on isolates and a partial result without them.
      final source =
          fixture('crc64');
      final full = XZDecoder().decodeBytes(source).length;

      // Cutting the archive in half leaves a block that decodes for a while
      // and then runs out of input, which is the shape being tested and does
      // not depend on where a particular xz build put its chunk boundaries.
      final compressed = Uint8List.sublistView(source, 0, source.length ~/ 2);
      final partial = XZDecoder().decodeBytes(compressed, verify: true).length;
      expect(partial, greaterThan(0));
      expect(partial, lessThan(full));

      // Every way of asking has to stop in the same place, whether or not the
      // check is verified and whether or not the output can be read back.
      expect(XZDecoder().decodeBytes(compressed).length, equals(partial));
      expect(await decodeBytesOnIsolates(compressed), hasLength(partial));
      expect(await decodeBytesOnIsolates(compressed, verify: true),
          hasLength(partial));

      final dir = Directory.systemTemp.createTempSync('archive_xz_partial');
      try {
        for (final verify in [false, true]) {
          final path = p.join(dir.path, 'out_$verify.bin');
          final output = OutputFileStream(path);
          expect(
              XZDecoder().decodeStream(InputMemoryStream(compressed), output,
                  verify: verify),
              isFalse);
          await output.close();
          expect(File(path).lengthSync(), equals(partial),
              reason: 'sync, verify: $verify');
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    group('archive wrapper', () {
      // Splitting an archive up means finding the blocks through the index and
      // decoding each one on its own, so nothing afterwards ever looks at the
      // stream header or footer again. Whatever the single threaded decode
      // checks in them has to be checked here instead, or a damaged archive
      // that xz rejects decodes without complaint.
      late Uint8List pristine;

      setUp(() {
        pristine = fixture('crc64-blocks');
        expect(XZDecoder().uncompressedSize(pristine), equals(expected.length));
      });

      Uint8List flipped(int offset) {
        final data = Uint8List.fromList(pristine);
        data[offset] ^= 0xff;
        return data;
      }

      test('rejects a damaged stream header CRC', () async {
        // Bytes 8..11 of the archive. They cover the two flag bytes in front
        // of them and nothing else reads them.
        for (var i = 8; i < 12; i++) {
          final data = flipped(i);
          expect(XZDecoder().uncompressedSize(data), isNull, reason: 'byte $i');
          expect(
              await decodeStreamOnIsolates(
                  InputMemoryStream(data), OutputMemoryStream(),
                  workers: 4),
              isFalse,
              reason: 'byte $i');
        }
      });

      test('rejects a damaged stream footer CRC', () async {
        // The last twelve bytes are the footer, and its CRC32 leads.
        final footerStart = pristine.length - 12;
        for (var i = footerStart; i < footerStart + 4; i++) {
          final data = flipped(i);
          expect(XZDecoder().uncompressedSize(data), isNull, reason: 'byte $i');
          expect(
              await decodeStreamOnIsolates(
                  InputMemoryStream(data), OutputMemoryStream(),
                  workers: 4),
              isFalse,
              reason: 'byte $i');
        }
      });

      test('agrees with the single threaded decode on every wrapper byte',
          () async {
        // The header, the footer and the index between them. Damaging any one
        // byte has to reach the same verdict either way, which is the property
        // the two tests above are specific cases of.
        final offsets = <int>[
          for (var i = 0; i < 12; i++) i,
          for (var i = pristine.length - 64; i < pristine.length; i++) i,
        ];
        for (final i in offsets) {
          final data = flipped(i);
          final sequential = XZDecoder()
              .decodeStream(InputMemoryStream(data), OutputMemoryStream());
          final parallel = await decodeStreamOnIsolates(
              InputMemoryStream(data), OutputMemoryStream(),
              workers: 4);
          expect(parallel, equals(sequential), reason: 'byte $i');
        }
      });
    });

    group('throwOnError', () {
      // The exception cannot reach the caller, whose stack is gone by the time
      // the workers finish, so it is delivered to onError instead. Without the
      // flag a corrupt archive is not an error and reaches onDone.
      late Uint8List broken;
      late Uint8List whole;

      setUpAll(() {
        whole =
            fixture('blocks');
        broken = Uint8List.sublistView(whole, 0, whole.length ~/ 2);
      });

      /// Runs a decode and reports which callback it ended up in.
      Future<({Object? error, Object? done})> outcome(
          void Function(void Function(Object? done) onDone,
                  void Function(Object, StackTrace) onError)
              start) {
        final completer = Completer<({Object? error, Object? done})>();
        start(
          (done) => completer.complete((error: null, done: done)),
          (error, _) => completer.complete((error: error, done: null)),
        );
        return completer.future;
      }

      Future<({Object? error, Object? done})> bytes(Uint8List compressed,
              {required bool throwOnError, bool verify = false}) =>
          outcome((onDone, onError) => XZDecoder().decodeBytes(compressed,
              verify: verify,
              throwOnError: throwOnError,
              multithread: XZMultithreadOptions<Uint8List>(
                onDone: onDone,
                onError: onError,
                workers: 4,
              )));

      Future<({Object? error, Object? done})> stream(Uint8List compressed,
              {required bool throwOnError, bool verify = false}) =>
          outcome((onDone, onError) => XZDecoder()
              .decodeStream(InputMemoryStream(compressed), OutputMemoryStream(),
                  verify: verify,
                  throwOnError: throwOnError,
                  multithread: XZMultithreadOptions<bool>(
                    onDone: onDone,
                    onError: onError,
                    workers: 4,
                  )));

      test('decodeBytes routes a corrupt archive to onError', () async {
        final r = await bytes(broken, throwOnError: true);
        expect(r.error, isA<ArchiveException>());
        expect(r.done, isNull);
      });

      test('decodeBytes without it reports the partial output to onDone',
          () async {
        final r = await bytes(broken, throwOnError: false);
        expect(r.error, isNull);
        expect(r.done, isA<Uint8List>());
        expect(r.done as Uint8List, isNotEmpty);
        expect((r.done as Uint8List).length, lessThan(expected.length));
      });

      test('decodeBytes stays on onDone for a valid archive', () async {
        final r = await bytes(whole, throwOnError: true);
        expect(r.error, isNull);
        expect(r.done, equals(expected));
      });

      test('decodeStream routes a corrupt archive to onError', () async {
        final r = await stream(broken, throwOnError: true);
        expect(r.error, isA<ArchiveException>());
        expect(r.done, isNull);
      });

      test('decodeStream without it reports false to onDone', () async {
        final r = await stream(broken, throwOnError: false);
        expect(r.error, isNull);
        expect(r.done, isFalse);
      });

      test('decodeStream stays on onDone for a valid archive', () async {
        final r = await stream(whole, throwOnError: true);
        expect(r.error, isNull);
        expect(r.done, isTrue);
      });

      test('reaches onError while verifying too', () async {
        expect((await bytes(broken, throwOnError: true, verify: true)).error,
            isA<ArchiveException>());
        expect((await stream(broken, throwOnError: true, verify: true)).error,
            isA<ArchiveException>());
      });

      test('reaches onError on a single block archive as well', () async {
        // One block is decoded whole on one isolate rather than being split,
        // which is a separate path through the worker.
        final single = fixture('whole');
        final r = await bytes(
            Uint8List.sublistView(single, 0, single.length ~/ 2),
            throwOnError: true);
        expect(r.error, isA<ArchiveException>());
        expect(r.done, isNull);
      });

      test('reaches onError for a file the workers read themselves', () async {
        final dir = Directory.systemTemp.createTempSync('archive_xz_throw');
        try {
          final archivePath = p.join(dir.path, 'data.xz');
          File(archivePath).writeAsBytesSync(broken);
          final input = InputFileStream(archivePath);
          final output = OutputFileStream(p.join(dir.path, 'out.bin'));
          final r = await outcome(
              (onDone, onError) => XZDecoder().decodeStream(input, output,
                  throwOnError: true,
                  multithread: XZMultithreadOptions<bool>(
                    onDone: onDone,
                    onError: onError,
                    workers: 4,
                  )));
          await input.close();
          await output.close();
          expect(r.error, isA<ArchiveException>());
          expect(r.done, isNull);
        } finally {
          dir.deleteSync(recursive: true);
        }
      });

      test('carries the reason back out of the workers', () async {
        // The reason is worked out inside an isolate, so it has to survive the
        // trip home; without that the caller is told only that something was
        // wrong somewhere.
        final notXz = Uint8List.fromList(
            List<int>.generate(200000, (i) => (i * 37) & 0xff));
        final r = await bytes(notXz, throwOnError: true);
        expect(r.error, isA<ArchiveException>());
        expect((r.error as ArchiveException).message,
            contains('Invalid XZ stream header signature'));

        // And a failure that is about the data rather than the wrapper. The
        // check of a block sits at its end, so breaking that alone leaves the
        // data itself decodable and only a verifying decode objects.
        final built = buildArchive('crc64-blocks');
        final badCheck = Uint8List.fromList(built.bytes);
        badCheck[built.blocks[0].checkOffset(8)] ^= 0xff;
        expect(
            await decodeBytesOnIsolates(badCheck, workers: 4), equals(expected),
            reason: 'only the stored check should be broken');

        final checked = await bytes(badCheck, throwOnError: true, verify: true);
        expect(checked.error, isA<ArchiveException>());
        expect((checked.error as ArchiveException).message,
            contains('check failed'));
      });

      test('is refused when there is nowhere to deliver the exception', () {
        // Asking to be told and leaving no onError would put the failure back
        // where it started, so it is rejected while the caller can still hear.
        expect(
            () => XZDecoder().decodeBytes(broken,
                throwOnError: true,
                multithread: XZMultithreadOptions(onDone: (_) {})),
            throwsArgumentError);
        expect(
            () => XZDecoder().decodeStream(
                InputMemoryStream(broken), OutputMemoryStream(),
                throwOnError: true,
                multithread: XZMultithreadOptions(onDone: (_) {})),
            throwsArgumentError);
      });

      test('omitting onError is still fine without it', () async {
        final completer = Completer<Uint8List>();
        XZDecoder().decodeBytes(broken,
            multithread: XZMultithreadOptions<Uint8List>(
                onDone: completer.complete, workers: 4));
        expect(await completer.future, isNotEmpty);
      });
    });

    group('a block that outgrows its record in the index', () {
      // Damage inside a block header can raise the uncompressed size it
      // declares, leaving it larger than what the index records for that block.
      // decodeBytes preallocates from the index, so such a block has more to
      // write than the buffer holds. That has to be reported the way every
      // other damaged archive is, not raised from inside the chunk callback:
      // the caller's stack is gone by then, so a throw would arrive as a bare
      // RangeError even when failures were asked for by return value.
      //
      // The offsets are from test/_data/xz/good-1-lzma2-1.xz, which is checked
      // in, so they are fixed. 31 of its 424 bytes have this effect; these two
      // are the first and the one that overshoots furthest.
      late Uint8List original;

      setUpAll(() {
        original = File('test/_data/xz/good-1-lzma2-1.xz').readAsBytesSync();
      });

      Uint8List damagedAt(int offset) {
        final data = Uint8List.fromList(original);
        data[offset] ^= 0xFF;
        return data;
      }

      for (final offset in const [240, 316]) {
        test('at byte $offset reaches onDone without throwOnError', () async {
          final data = damagedAt(offset);
          final declared = XZDecoder().uncompressedSize(data)!;
          // The premise: the single threaded decode really does produce more
          // than the index accounts for, which is what has nowhere to go.
          expect(XZDecoder().decodeBytes(data).length, greaterThan(declared));

          final completer = Completer<({Object? error, Uint8List? done})>();
          XZDecoder().decodeBytes(data,
              multithread: XZMultithreadOptions<Uint8List>(
                workers: 4,
                onDone: (d) => completer.complete((error: null, done: d)),
                onError: (e, _) => completer.complete((error: e, done: null)),
              ));
          final result = await completer.future;
          expect(result.error, isNull,
              reason: 'a corrupt archive is not an error without throwOnError');
          // Clipped at the index, which is the size the buffer was allocated
          // against and the only one of the two the archive can be held to.
          expect(result.done, hasLength(declared));
        });

        test('at byte $offset reports the mismatch with throwOnError',
            () async {
          final data = damagedAt(offset);
          final completer = Completer<Object?>();
          XZDecoder().decodeBytes(data,
              throwOnError: true,
              multithread: XZMultithreadOptions<Uint8List>(
                workers: 4,
                onDone: (_) => completer.complete(null),
                onError: (e, _) => completer.complete(e),
              ));
          final error = await completer.future;
          expect(error, isA<ArchiveException>());
          // The same reason the single threaded decode gives, rather than the
          // RangeError of a buffer that ran out of room. Damage this far into
          // the block is caught by the range coder at the end of the chunk,
          // before the index it disagrees with is ever read.
          expect((error as ArchiveException).message,
              contains('LZMA data is corrupt'));
        });
      }

      test('decodeStream is unaffected, because its output can grow', () async {
        final data = damagedAt(316);
        final sequential = OutputMemoryStream();
        final sequentialOk =
            XZDecoder().decodeStream(InputMemoryStream(data), sequential);

        final parallel = OutputMemoryStream();
        final completer = Completer<bool>();
        XZDecoder().decodeStream(InputMemoryStream(data), parallel,
            multithread: XZMultithreadOptions<bool>(
              workers: 4,
              onDone: completer.complete,
              onError: (e, _) => completer.completeError(e),
            ));

        expect(await completer.future, equals(sequentialOk));
        expect(parallel.getBytes(), equals(sequential.getBytes()));
      });
    });

    test('streams memory into a memory stream in block order', () async {
      final compressed =
          fixture('blocks');
      final output = OutputMemoryStream();
      final ok = await decodeStreamOnIsolates(
          InputMemoryStream(compressed), output,
          workers: 4);
      expect(ok, isTrue);
      expect(output.getBytes(), equals(expected));
    });

    // The pull decoder, the converter and the isolate pool are three readers of
    // the same header bytes, and a check that lives in one of them shows up
    // here as a disagreement. The block header carries the fields the wrapper
    // sweep above never reaches: the block flags and the filter properties
    group('a damaged archive reaches the same verdict on every path', () {
      late Uint8List pristine;
      late List<int> offsets;

      setUpAll(() {
        pristine =
            fixture('blocks');
        final blockHeader = (pristine[12] + 1) * 4;
        offsets = <int>[
          for (var i = 0; i < 12; i++) i,
          for (var i = 12; i < 12 + blockHeader; i++) i,
          for (var i = 12 + blockHeader; i < pristine.length - 64; i += 4093) i,
          for (var i = pristine.length - 64; i < pristine.length; i++) i,
        ];
      });

      bool pull(Uint8List data, OutputStream output) =>
          XZDecoder().decodeStream(InputMemoryStream(data), output,
              verify: true);

      bool push(Uint8List data, BytesBuilder output) {
        try {
          final sink = xzCodec.decoder.startChunkedConversion(
              ByteConversionSink.withCallback(output.add));
          for (var at = 0; at < data.length; at += 4096) {
            final end = at + 4096 < data.length ? at + 4096 : data.length;
            sink.add(Uint8List.sublistView(data, at, end));
          }
          sink.close();
          return true;
        } catch (_) {
          return false;
        }
      }

      test('every wrapper, block header and sampled payload byte', () async {
        for (final at in offsets) {
          final data = Uint8List.fromList(pristine)..[at] ^= 0xff;

          final sequential = OutputMemoryStream();
          final sequentialOk = pull(data, sequential);
          final chunked = BytesBuilder();
          final chunkedOk = push(data, chunked);
          final parallelOut = OutputMemoryStream();
          final parallelOk = await decodeStreamOnIsolates(
              InputMemoryStream(data), parallelOut,
              verify: true, workers: 4);

          expect(chunkedOk, equals(sequentialOk), reason: 'byte $at, converter');
          expect(parallelOk, equals(sequentialOk), reason: 'byte $at, workers');
          if (sequentialOk) {
            expect(sequential.getBytes(), equals(expected), reason: 'byte $at');
            expect(chunked.toBytes(), equals(expected), reason: 'byte $at');
            expect(parallelOut.getBytes(), equals(expected), reason: 'byte $at');
          }
        }
      });

      test('a reserved bit in the flags is refused on every path', () async {
        final blockHeader = (pristine[12] + 1) * 4;
        final cases = <String, Uint8List>{
          'stream flags': Uint8List.fromList(pristine)..[7] |= 0x10,
          'block flags': Uint8List.fromList(pristine)..[13] |= 0x04,
        };
        for (final entry in cases.entries) {
          final data = entry.value;
          // The CRC would catch these first, so it is recomputed
          final view = ByteData.sublistView(data);
          if (entry.key == 'stream flags') {
            view.setUint32(8, getCrc32(data.sublist(6, 8)), Endian.little);
          } else {
            view.setUint32(12 + blockHeader - 4,
                getCrc32(data.sublist(12, 12 + blockHeader - 4)), Endian.little);
          }
          expect(pull(data, OutputMemoryStream()), isFalse, reason: entry.key);
          expect(push(data, BytesBuilder()), isFalse, reason: entry.key);
          expect(
              await decodeStreamOnIsolates(
                  InputMemoryStream(data), OutputMemoryStream(),
                  verify: true, workers: 4),
              isFalse,
              reason: entry.key);
        }
      });
    });
  });

  // The converter on isolates has to write what the converter on one thread
  // writes, and on a failure no more than the whole blocks before it
  group('xz stream decoder on isolates', () {
    final expected = sampleData(1200000);
    const options = XZMultithreadOptions<Object?>(workers: 4);

    Stream<List<int>> pieces(Uint8List bytes, int size) async* {
      for (var at = 0; at < bytes.length; at += size) {
        final end = at + size < bytes.length ? at + size : bytes.length;
        yield Uint8List.sublistView(bytes, at, end);
      }
    }

    Future<({Uint8List bytes, Object? error})> collect(
        Stream<List<int>> stream) async {
      final out = BytesBuilder(copy: false);
      try {
        await for (final piece in stream) {
          out.add(piece);
        }
        return (bytes: out.toBytes(), error: null);
      } catch (error) {
        return (bytes: out.toBytes(), error: error);
      }
    }

    Future<({Uint8List bytes, Object? error})> threaded(Stream<List<int>> s,
            [XZMultithreadOptions<Object?> with_ = options]) =>
        collect(s.transform(XzCodec(multithread: with_).decoder))
            .timeout(const Duration(seconds: 60));

    Future<({Uint8List bytes, Object? error})> single(Stream<List<int>> s) =>
        collect(s.transform(xzCodec.decoder));

    bool isPrefix(List<int> part, List<int> whole) {
      if (part.length > whole.length) {
        return false;
      }
      for (var i = 0; i < part.length; i++) {
        if (part[i] != whole[i]) {
          return false;
        }
      }
      return true;
    }

    // Two failed decodes each stop somewhere in the true output, so they agree
    // as far as the shorter one goes. Neither has to be the longer one: the
    // single threaded sink loses what it gathered when it fails
    bool agreeSoFar(List<int> a, List<int> b) =>
        a.length <= b.length ? isPrefix(a, b) : isPrefix(b, a);

    test('every archive decodes as it does on one thread', () async {
      final files = [
        ...Directory('test/_data/xz/parallel').listSync(),
        ...Directory('test/_data/xz').listSync(),
      ].whereType<File>().where(
          (f) => f.path.endsWith('.xz') && !f.path.endsWith('huge.xz'));
      for (final file in files) {
        final bytes = file.readAsBytesSync();
        for (final size in [4096, 1 << 16, bytes.length + 1]) {
          final one = await single(pieces(bytes, size));
          final many = await threaded(pieces(bytes, size));
          final label = '${file.path} in pieces of $size';
          expect(many.error == null, one.error == null, reason: label);
          if (one.error == null) {
            expect(many.bytes, one.bytes, reason: label);
          } else {
            expect(agreeSoFar(many.bytes, one.bytes), isTrue, reason: label);
          }
        }
      }
    });

    test('one byte at a time', () async {
      for (final name in ['x86.xz', 'concatenated.xz', 'stream_padding.xz']) {
        final bytes = File('test/_data/xz/$name').readAsBytesSync();
        expect((await threaded(pieces(bytes, 1))).bytes,
            (await single(pieces(bytes, 1))).bytes,
            reason: name);
      }
    });

    test('blocks without lengths come out in order between the others',
        () async {
      // A stream whose blocks declare their lengths, one whose blocks do not,
      // and another that does, back to back
      final bytes = Uint8List.fromList([
        ...fixture('blocks'),
        ...File('test/_data/xz/crc32.xz').readAsBytesSync(),
        ...fixture('x86'),
      ]);
      final one = await single(pieces(bytes, 1 << 16));
      expect(one.error, isNull);
      final many = await threaded(pieces(bytes, 1 << 16));
      expect(many.error, isNull);
      expect(many.bytes, one.bytes);
    });

    test('a budget that affords one worker writes the same bytes', () async {
      final bytes = fixture('blocks');
      final many = await threaded(pieces(bytes, 1 << 16),
          const XZMultithreadOptions(workers: 4, memoryBudget: 10 << 20));
      expect(many.error, isNull);
      expect(many.bytes, expected);
    });

    test('an input that stops part way is refused with whole blocks out',
        () async {
      final built = buildArchive('blocks');
      final bytes = built.bytes;
      final blocks = built.blocks;
      final ends = {
        for (final block in blocks) block.uncompOffset,
        expected.length,
      };
      final indexStart = blocks.last.compOffset + blocks.last.totalSize;
      final cuts = <String, int>{
        'inside the first block': blocks[0].dataOffset + 100,
        'inside the third block': blocks[2].dataOffset + 100,
        'on the boundary of the fourth block': blocks[3].compOffset,
        'after the last block': indexStart,
        'inside the index': indexStart + 2,
        'inside the footer': bytes.length - 3,
      };
      for (final cut in cuts.entries) {
        final part = Uint8List.sublistView(bytes, 0, cut.value);
        final many = await threaded(pieces(part, 4096));
        expect(many.error, isA<ArchiveException>(), reason: cut.key);
        expect(isPrefix(many.bytes, expected), isTrue, reason: cut.key);
        expect(ends.contains(many.bytes.length), isTrue,
            reason: '${cut.key}: ${many.bytes.length} is not a block boundary');
      }
    });

    test('a source that fails part way ends with that error', () async {
      final bytes = fixture('blocks');
      for (final at in [100, bytes.length ~/ 2, bytes.length - 20]) {
        final source = StreamController<List<int>>();
        final result = threaded(source.stream);
        source.add(Uint8List.sublistView(bytes, 0, at));
        source.addError(StateError('source failed'));
        final outcome = await result;
        expect(outcome.error, isA<StateError>(), reason: 'at $at');
        expect(isPrefix(outcome.bytes, expected), isTrue, reason: 'at $at');
        expect(source.hasListener, isFalse, reason: 'at $at');
        await source.close();
      }
    });

    test('a silent input can be cancelled and is let go', () async {
      // Nothing sent, and a header followed by part of a block: in both the
      // decoder is parked waiting on an input that neither sends nor closes
      for (final start in [<int>[], fixture('blocks').sublist(0, 1000)]) {
        final source = StreamController<List<int>>();
        final subscription = source.stream
            .transform(const XzCodec(multithread: options).decoder)
            .listen((_) {});
        if (start.isNotEmpty) {
          source.add(start);
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await subscription.cancel().timeout(const Duration(seconds: 10));
        expect(source.hasListener, isFalse, reason: '${start.length} bytes');
        await source.close();
      }
    });

    test('whole archives come out before the input closes', () async {
      for (final archive in [
        fixture('x86'),
        XZEncoder().encodeBytes(Uint8List.sublistView(expected, 0, 3000)),
        // One block whose header declares both lengths, so it goes to a worker
        // and no second block ever comes to start the pool
        fixture('whole'),
      ]) {
        final want = XZDecoder().decodeBytes(archive);
        final source = StreamController<List<int>>();
        var got = 0;
        final arrived = Completer<void>();
        final subscription = source.stream
            .transform(const XzCodec(multithread: options).decoder)
            .listen((piece) {
          got += piece.length;
          if (got >= want.length && !arrived.isCompleted) {
            arrived.complete();
          }
        });
        source.add(archive);
        await arrived.future.timeout(const Duration(seconds: 30));
        expect(got, want.length);
        await subscription.cancel().timeout(const Duration(seconds: 10));
        expect(source.hasListener, isFalse);
        await source.close();
      }
    });

    test('cancelling the output cancels the input', () async {
      final source = StreamController<List<int>>();
      final bytes = fixture('blocks');
      final first = Completer<void>();
      final subscription = source.stream
          .transform(const XzCodec(multithread: options).decoder)
          .listen((_) {
        if (!first.isCompleted) {
          first.complete();
        }
      });
      source.add(bytes);
      await first.future.timeout(const Duration(seconds: 30));
      await subscription.cancel();
      expect(source.hasListener, isFalse);
      await source.close();
    });

    test('a damaged archive reaches the same verdict', () async {
      final built = buildArchive('blocks');
      final pristine = built.bytes;
      final ends = {
        for (final block in built.blocks) block.uncompOffset,
        expected.length,
      };
      final blockHeader = (pristine[12] + 1) * 4;
      final offsets = [
        for (var i = 0; i < 12 + blockHeader; i++) i,
        for (var i = 12 + blockHeader; i < pristine.length; i += 4093) i,
        for (var i = pristine.length - 64; i < pristine.length; i++) i,
      ];
      for (final at in offsets) {
        final data = Uint8List.fromList(pristine)..[at] ^= 0xff;
        final one = await single(pieces(data, 1 << 16));
        final many = await threaded(pieces(data, 1 << 16));
        expect(many.error == null, one.error == null, reason: 'byte $at');
        if (one.error == null) {
          expect(many.bytes, one.bytes, reason: 'byte $at');
        } else {
          // Blocks off a worker come out whole and checked, so a failure
          // leaves true output ending where a block does
          expect(isPrefix(many.bytes, expected), isTrue, reason: 'byte $at');
          expect(ends.contains(many.bytes.length), isTrue,
              reason: 'byte $at: ${many.bytes.length} is not a block boundary');
        }
      }
    });

    test('a sink refuses the options, since it cannot wait for a worker', () {
      const codec = XzCodec(multithread: options);
      expect(() => codec.decoder.startChunkedConversion(BytesBuilderSink()),
          throwsArgumentError);
      expect(() => codec.decoder.convert(fixture('whole')), throwsArgumentError);
    });

    test('settings that cannot be honoured are refused', () async {
      for (final bad in [
        const XZMultithreadOptions<Object?>(workers: 0),
        const XZMultithreadOptions<Object?>(memoryBudget: 0),
      ]) {
        final outcome = await threaded(pieces(fixture('whole'), 4096), bad);
        expect(outcome.error, isA<ArgumentError>());
      }
    });

    test('decodeBytes still needs onDone', () {
      expect(
          () => XZDecoder().decodeBytes(fixture('whole'),
              multithread: const XZMultithreadOptions<Uint8List>(workers: 2)),
          throwsArgumentError);
    });
  });
}

class BytesBuilderSink implements Sink<List<int>> {
  final builder = BytesBuilder();

  @override
  void add(List<int> data) => builder.add(data);

  @override
  void close() {}
}

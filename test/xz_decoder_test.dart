import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Decoder behaviours that the archives in xz_test.dart do not reach. Each one
// here is either a format feature the upstream decoder rejected or got wrong,
// or an API this package added, and every archive was produced by xz itself
// and checked with `xz -t`.

Uint8List archiveBytes(String name) =>
    File(p.join('test/_data/xz', name)).readAsBytesSync();

/// The content of `pb4.xz`, rebuilt rather than committed beside it.
Uint8List pb4Sample() {
  const pattern = 'the quick brown fox jumps over the lazy dog 0123456789\n';
  final bytes = <int>[];
  while (bytes.length < 500) {
    bytes.addAll(pattern.codeUnits);
  }
  return Uint8List.fromList(bytes.sublist(0, 500));
}

/// The content of `x86.xz`. The e8 call operands are what the BCJ x86 filter
/// rewrites, so decoding without the filter gives visibly different bytes.
Uint8List x86Sample() {
  final data = <int>[];
  var i = 0;
  while (data.length < 4000) {
    if (i % 17 == 0) {
      final target = (i * 7919) & 0xffffffff;
      data.addAll([
        0xe8,
        target & 0xff,
        (target >> 8) & 0xff,
        (target >> 16) & 0xff,
        (target >> 24) & 0xff,
      ]);
    } else {
      data.add((i * 31) & 0xff);
    }
    i++;
  }
  return Uint8List.fromList(data.sublist(0, 4000));
}

void main() {
  group('xz decoder', () {
    test('decodes an archive written with pb=4', () {
      // Four position bits is legal and rarely used, and reading the position
      // state a bit too narrowly makes the decoder run off the end of its
      // probability tables partway through.
      final data = XZDecoder().decodeBytes(archiveBytes('pb4.xz'));
      expect(data, equals(pb4Sample()));
    });

    test('decodes an archive written with pb=4 while verifying', () {
      final data =
          XZDecoder().decodeBytes(archiveBytes('pb4.xz'), verify: true);
      expect(data, equals(pb4Sample()));
    });

    test('applies the BCJ x86 filter', () {
      final data = XZDecoder().decodeBytes(archiveBytes('x86.xz'));
      expect(data, equals(x86Sample()));
    });

    test('decodes concatenated streams', () {
      // Three separate streams in one file. A decoder that stops after the
      // first one returns only 'one\n', or nothing at all when the first
      // stream is empty, without reporting a failure.
      final data = XZDecoder().decodeBytes(archiveBytes('concatenated.xz'));
      expect(utf8.decode(data), equals('one\ntwo\nthree\n'));
    });

    test('skips stream padding between and after streams', () {
      // Streams may be followed by padding in multiples of four zero bytes.
      final data = XZDecoder().decodeBytes(archiveBytes('stream_padding.xz'));
      expect(utf8.decode(data), equals('one\ntwo\n'));
    });

    test('decodeStream reports success for each of them', () {
      for (final name in [
        'pb4.xz',
        'x86.xz',
        'concatenated.xz',
        'stream_padding.xz',
      ]) {
        final output = OutputMemoryStream();
        expect(
            XZDecoder()
                .decodeStream(InputMemoryStream(archiveBytes(name)), output),
            isTrue,
            reason: name);
        expect(output.length, greaterThan(0), reason: name);
      }
    });

    group('match distance', () {
      test('accepts distances up to the declared dictionary', () {
        // Encoded with a 64 KiB dictionary over data whose period is 8 KiB, so
        // the matches reach well past any smaller window. This guards the
        // check below against being too strict.
        final data = XZDecoder().decodeBytes(archiveBytes('long_distance.xz'));
        expect(data.length, equals(4 * 1024 * 1024));
        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(archiveBytes('long_distance.xz')),
                OutputMemoryStream()),
            isTrue);
      });

      test('refuses a match that reaches past the declared dictionary', () {
        // The same archive with one byte changed: the block header now
        // declares a 4 KiB dictionary, with the header CRC recomputed so the
        // header itself is well formed. The matches still reach 8 KiB back, so
        // xz rejects this file as corrupt and so must this decoder.
        //
        // Accepting it is not only wrong output. The dictionary buffer is
        // larger than the declared dictionary, so an over long distance is
        // remembered, and trimDictionary then moves the write position back
        // below it. The next literal decoded in matched state indexes the
        // dictionary at a negative offset, and that read has its bounds check
        // disabled by a pragma.
        final compressed = archiveBytes('dict_overrun.xz');
        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream()),
            isFalse);
        expect(
            () => XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream(),
                throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });
    });

    test('accepts a plain List<int> as well as a Uint8List', () {
      // The other overload copies into a Uint8List first, which is a separate
      // path through decodeBytes.
      final asList = archiveBytes('pb4.xz').toList();
      expect(XZDecoder().decodeBytes(asList), equals(pb4Sample()));
    });

    group('throwOnError', () {
      test('stays quiet on a valid archive', () {
        final output = OutputMemoryStream();
        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(archiveBytes('pb4.xz')), output,
                throwOnError: true),
            isTrue);
        expect(output.getBytes(), equals(pb4Sample()));
      });

      test('turns a refusal into an exception', () {
        // Without it a malformed archive is reported by the return value, and
        // whatever was decoded is left in the output.
        final compressed = Uint8List.fromList(archiveBytes('pb4.xz'));
        compressed[compressed.length - 6] ^= 0xff; // stream footer flags

        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream()),
            isFalse);
        expect(
            () => XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream(),
                throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });

      test('turns a thrown decode failure into an exception too', () {
        // Corrupting the compressed data makes the LZMA decoder itself throw,
        // which has to surface as the same exception rather than escaping raw.
        final compressed = Uint8List.fromList(archiveBytes('x86.xz'));
        for (var i = 0; i < 64; i++) {
          compressed[400 + i] ^= 0xff;
        }

        expect(
            XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream()),
            isFalse);
        expect(
            () => XZDecoder().decodeStream(
                InputMemoryStream(compressed), OutputMemoryStream(),
                throwOnError: true),
            throwsA(isA<ArchiveException>()));
      });
    });

    group('uncompressedSize', () {
      test('agrees with the decoded length', () {
        for (final name in [
          'pb4.xz',
          'x86.xz',
          'concatenated.xz',
          'stream_padding.xz',
          'hello.xz',
          'empty.xz',
          'crc32.xz',
          'crc64.xz',
          'sha256.xz',
          'nocheck.xz',
          'hello-hello-hello.xz',
          'good-1-lzma2-1.xz',
          'cat.jpg.xz',
        ]) {
          final compressed = archiveBytes(name);
          expect(XZDecoder().uncompressedSize(compressed),
              equals(XZDecoder().decodeBytes(compressed).length),
              reason: name);
        }
      });

      test('gives up rather than guessing on data that is not an archive', () {
        expect(XZDecoder().uncompressedSize(Uint8List(0)), isNull);
        expect(XZDecoder().uncompressedSize(utf8.encode('not an archive')),
            isNull);
      });

      test('gives up on a truncated archive', () {
        // The index and footer are what it reads, so losing the tail of the
        // file has to be noticed rather than misread.
        final compressed = archiveBytes('concatenated.xz');
        final truncated =
            Uint8List.sublistView(compressed, 0, compressed.length - 8);
        expect(XZDecoder().uncompressedSize(truncated), isNull);
      });

      test('gives up when the index is corrupt', () {
        final compressed = Uint8List.fromList(archiveBytes('pb4.xz'));
        // Land in the index, which sits just before the twelve byte footer.
        compressed[compressed.length - 16] ^= 0xff;
        expect(XZDecoder().uncompressedSize(compressed), isNull);
      });
    });
  });
}

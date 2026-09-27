import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

import '_test_util.dart';

void main() {
  group('gzip', () {
    final buffer = Uint8List(10000);
    for (var i = 0; i < buffer.length; ++i) {
      buffer[i] = i % 256;
    }

    test('zlib encode_web/decode', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = ZLibEncoderWeb().encodeBytes(origData);
      final uncompressed = ZLibDecoder().decodeBytes(compressed);
      compareBytes(uncompressed, origData);
    });

    test('zlib encode/decode_web', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = ZLibEncoder().encodeBytes(origData);
      final uncompressed = ZLibDecoderWeb().decodeBytes(compressed);
      compareBytes(uncompressed, origData);
    });

    test('gzip encode_web/decode', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = GZipEncoderWeb().encodeBytes(origData);
      final uncompressed = GZipDecoder().decodeBytes(compressed);
      compareBytes(uncompressed, origData);
    });

    test('gzip encode/decode_web', () {
      final origData = [1, 2, 3, 4, 5, 6];
      final compressed = GZipEncoder().encodeBytes(origData);
      final uncompressed = GZipDecoderWeb().decodeBytes(compressed);
      compareBytes(uncompressed, origData);
    });

    test('multiblock', () async {
      final compressedData = [
        ...GZipEncoder().encodeBytes([1, 2, 3]),
        ...GZipEncoder().encodeBytes([4, 5, 6])
      ];
      final decodedData =
          GZipDecoderWeb().decodeBytes(compressedData, verify: true);
      compareBytes(decodedData, [1, 2, 3, 4, 5, 6]);
    });

    test('encode/decode', () {
      final compressed = GZipEncoder().encodeBytes(buffer);
      final decompressed = GZipDecoder().decodeBytes(compressed, verify: true);
      expect(decompressed.length, equals(buffer.length));
      for (var i = 0; i < buffer.length; ++i) {
        expect(decompressed[i], equals(buffer[i]));
      }
    });

    test('decode res/cat.jpg.gz', () {
      final b = File('test/_data/cat.jpg');
      final bBytes = b.readAsBytesSync();

      final file = File('test/_data/cat.jpg.gz');
      final bytes = file.readAsBytesSync();

      final zBytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compareBytes(zBytes, bBytes);
    });

    test('decode res/test2.tar.gz', () {
      final b = File('test/_data/test2.tar');
      final bBytes = b.readAsBytesSync();

      final file = File('test/_data/test2.tar.gz');
      final bytes = file.readAsBytesSync();

      final zBytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compareBytes(zBytes, bBytes);
    });

    test('decode res/a.txt.gz', () {
      final aBytes = aTxt.codeUnits;

      final file = File('test/_data/a.txt.gz');
      final bytes = file.readAsBytesSync();

      final zBytes = GZipDecoder().decodeBytes(bytes, verify: true);
      compareBytes(zBytes, aBytes);
    });

    test('encode res/cat.jpg', () {
      final b = File('test/_data/cat.jpg');
      final bBytes = b.readAsBytesSync();

      final compressed = GZipEncoder().encodeBytes(bBytes);
      final f = File('$testOutputPath/cat.jpg.gz');
      f.createSync(recursive: true);
      f.writeAsBytesSync(compressed);
    });

    group('a truncated stream is reported', () {
      // The decoder underneath checks every member whose trailer it reaches,
      // so what is at stake here is the one case it cannot see: a member that
      // ends before its trailer. Left unreported that decodes to a short
      // result and returns true, which for a .tar.gz means files quietly
      // going missing.
      final whole = Uint8List.fromList(GZipEncoder().encodeBytes(buffer));

      int decode(GZipDecoder decoder, Uint8List data, {required bool ok}) {
        final output = OutputMemoryStream();
        expect(decoder.decodeStream(InputMemoryStream(data), output), ok);
        return output.length;
      }

      int decodeWeb(Uint8List data, {required bool ok}) {
        final output = OutputMemoryStream();
        expect(
            GZipDecoderWeb().decodeStream(InputMemoryStream(data), output), ok);
        return output.length;
      }

      test('whole input decodes and reports success', () {
        expect(decode(GZipDecoder(), whole, ok: true), buffer.length);
        expect(decodeWeb(whole, ok: true), buffer.length);
      });

      // Eight bytes is exactly the trailer, so this covers losing the trailer
      // alone as well as losing compressed data with it.
      for (final cut in [1, 8, 9, 40]) {
        test('$cut bytes short', () {
          final short = Uint8List.sublistView(whole, 0, whole.length - cut);
          decode(GZipDecoder(), short, ok: false);
          decodeWeb(short, ok: false);
        });
      }

      test('a member cut off inside its header', () {
        // 10 header + 2 deflate + 8 trailer is the least a member can be;
        // below that the last eight bytes are header, not the trailer
        for (var n = 1; n < 20; ++n) {
          final short = Uint8List.sublistView(whole, 0, n);
          decode(GZipDecoder(), short, ok: false);
          decodeWeb(short, ok: false);
        }
        // The bound is not off by one: an empty file encodes to exactly 20
        final empty = Uint8List.fromList(GZipEncoder().encodeBytes(<int>[]));
        expect(empty.length, equals(20));
        expect(decode(GZipDecoder(), empty, ok: true), 0);
        expect(decodeWeb(empty, ok: true), 0);
      });

      test('concatenated members are not mistaken for one', () {
        // Every member but the last is checked by the decoder itself, so the
        // point here is that the check added for the last one does not go off
        // on a stream that is whole.
        final two = Uint8List.fromList([...whole, ...whole]);
        expect(decode(GZipDecoder(), two, ok: true), buffer.length * 2);
        expect(decodeWeb(two, ok: true), buffer.length * 2);

        final cut = Uint8List.sublistView(two, 0, two.length - 40);
        decode(GZipDecoder(), cut, ok: false);
        decodeWeb(cut, ok: false);
      });

      test('an empty input is not an empty archive', () {
        decode(GZipDecoder(), Uint8List(0), ok: false);
        decodeWeb(Uint8List(0), ok: false);
      });

      test('a zlib stream still goes through unremarked', () {
        // Both decoders accept a stream with no gzip header at all, to match
        // what dart:io does. Its trailer is four bytes of Adler-32, which the
        // check above would fail on sight, so it must not be reached.
        for (final data in [
          Uint8List.fromList(ZLibEncoder().encodeBytes(buffer)),
          Uint8List.fromList(ZLibEncoder().encodeBytes(Uint8List(0))),
          Uint8List.fromList(ZLibEncoderWeb().encodeBytes(buffer)),
        ]) {
          final output = OutputMemoryStream();
          expect(GZipDecoder().decodeStream(InputMemoryStream(data), output),
              isTrue);
          expect(
              GZipDecoderWeb()
                  .decodeStream(InputMemoryStream(data), OutputMemoryStream()),
              isTrue);
        }
      });
    });

    group('verify and throwOnError', () {
      final data = Uint8List(300000);
      for (var i = 0; i < data.length; i++) {
        data[i] = (i * 7 + (i >> 9)) % 251;
      }
      final gzip = Uint8List.fromList(GZipEncoder().encodeBytes(data));
      final zlib = Uint8List.fromList(ZLibEncoder().encodeBytes(data));
      final decoders = {
        'gzip': (Uint8List b, bool v, bool t) => const GZipDecoder()
            .decodeStream(InputMemoryStream(b), OutputMemoryStream(),
                verify: v, throwOnError: t),
        'gzip web': (Uint8List b, bool v, bool t) => const GZipDecoderWeb()
            .decodeStream(InputMemoryStream(b), OutputMemoryStream(),
                verify: v, throwOnError: t),
        'zlib': (Uint8List b, bool v, bool t) => const ZLibDecoder()
            .decodeStream(InputMemoryStream(b), OutputMemoryStream(),
                verify: v, throwOnError: t),
        'zlib web': (Uint8List b, bool v, bool t) => const ZLibDecoderWeb()
            .decodeStream(InputMemoryStream(b), OutputMemoryStream(),
                verify: v, throwOnError: t),
      };
      Uint8List of(String name) => name.startsWith('gzip') ? gzip : zlib;

      for (final web in [false, true]) {
        test('verified members write to a sink without readback, web $web', () {
          final joined = Uint8List.fromList([...gzip, ...gzip]);
          List<List<int>>? chunks;
          final output = SinkOutputStream(
              ChunkedConversionSink<List<int>>.withCallback(
                  (all) => chunks = all));
          output.writeBytes([1, 2, 3]);
          final input = InputMemoryStream([4, 5, ...joined, 6, 7])
              .subset(position: 1, length: joined.length + 1)
            ..skip(1);
          final ok = web
              ? const GZipDecoderWeb().decodeStream(input, output, verify: true)
              : const GZipDecoder().decodeStream(input, output, verify: true);
          expect(ok, isTrue);
          output.sink.close();
          expect(chunks!.expand((chunk) => chunk), [1, 2, 3, ...data, ...data]);
        });

        test('verified members report progress callback failures, web $web',
            () {
          final error = StateError('progress callback failed');
          final input = InputMemoryStream([4, 5, ...gzip, ...gzip])..skip(2);
          final output = ProgressOutputStream(
              OutputMemoryStream(), (_) => throw error,
              interval: 1);
          expect(
              () => web
                  ? const GZipDecoderWeb()
                      .decodeStream(input, output, verify: true)
                  : const GZipDecoder()
                      .decodeStream(input, output, verify: true),
              throwsA(same(error)));
        });
      }

      for (final stream in [false, true]) {
        test('native gzip checks optional header CRC, stream $stream', () {
          final header = gzip.sublist(0, 10)..[3] |= 2;
          final crc = getCrc32(header);
          final member = Uint8List.fromList([
            ...header,
            crc & 255,
            (crc >> 8) & 255,
            ...gzip.sublist(10),
          ]);
          Object decode(List<int> bytes,
                  {bool verify = false, bool throwOnError = false}) =>
              stream
                  ? const GZipDecoder().decodeStream(
                      InputMemoryStream(bytes), OutputMemoryStream(),
                      verify: verify, throwOnError: throwOnError)
                  : const GZipDecoder().decodeBytes(bytes,
                      verify: verify, throwOnError: throwOnError);
          expect(decode(member, verify: true), stream ? isTrue : equals(data));
          for (final byte in [3, 10, 11]) {
            final bad = Uint8List.fromList(member);
            bad[byte] ^= byte == 3 ? 0x80 : 1;
            expect(() => decode(bad, verify: true),
                throwsA(isA<ArchiveException>()));
            expect(() => decode(bad, throwOnError: true),
                throwsA(isA<ArchiveException>()));
          }
        });

        test('strict options reject damaged later gzip headers, stream $stream',
            () {
          for (final byte in [0, 1, 2]) {
            final bad = Uint8List.fromList([...gzip, ...gzip]);
            bad[gzip.length + byte] ^= 1;
            for (final (verify, throwOnError) in [
              (true, false),
              (false, true)
            ]) {
              expect(
                  () => stream
                      ? const GZipDecoder().decodeStream(
                          InputMemoryStream(bad), OutputMemoryStream(),
                          verify: verify, throwOnError: throwOnError)
                      : const GZipDecoder().decodeBytes(bad,
                          verify: verify, throwOnError: throwOnError),
                  throwsA(isA<ArchiveException>()),
                  reason: 'header byte $byte, verify $verify');
            }
          }
        });

        test('verify checks every concatenated gzip member, stream $stream',
            () {
          final joined = Uint8List.fromList([...gzip, ...gzip, ...gzip]);
          Object decode(List<int> bytes,
              {bool verify = false, bool throwOnError = false}) {
            if (stream) {
              return const GZipDecoder().decodeStream(
                  InputMemoryStream(bytes), OutputMemoryStream(),
                  verify: verify, throwOnError: throwOnError);
            }
            return const GZipDecoder()
                .decodeBytes(bytes, verify: verify, throwOnError: throwOnError);
          }

          final expected =
              stream ? isTrue : equals([...data, ...data, ...data]);
          expect(decode(joined, verify: true), expected);
          for (var member = 0; member < 3; member++) {
            for (var byte = 0; byte < 8; byte++) {
              final bad = Uint8List.fromList(joined);
              bad[(member + 1) * gzip.length - 8 + byte] ^= 1;
              expect(() => decode(bad, verify: true),
                  throwsA(isA<ArchiveException>()),
                  reason: 'member $member, trailer byte $byte');
              if (byte < 4 && member == 2) {
                expect(decode(bad, throwOnError: true), expected);
              }
            }
          }
        });
      }

      for (final MapEntry(key: name, value: decode) in decoders.entries) {
        test('$name: a whole stream passes verify', () {
          expect(decode(of(name), true, false), isTrue);
        });

        test('$name: an empty input throws with either flag', () {
          expect(decode(Uint8List(0), false, false), isFalse);
          for (final (v, t) in [(true, false), (false, true)]) {
            expect(() => decode(Uint8List(0), v, t),
                throwsA(isA<ArchiveException>()),
                reason: 'verify $v, throwOnError $t');
          }
        });

        test('$name: a wrong checksum throws only with verify', () {
          final bad = Uint8List.fromList(of(name));
          bad[bad.length - (name.startsWith('gzip') ? 8 : 1)] ^= 1;
          expect(decode(bad, false, false), isTrue);
          expect(decode(bad, false, true), isTrue);
          expect(() => decode(bad, true, false),
              throwsA(isA<ArchiveChecksumException>()));
        });

        test('$name: cut or foreign data throws with either flag', () {
          final whole = of(name);
          final cut = Uint8List.sublistView(whole, 0, whole.length ~/ 2);
          if (name == 'zlib') {
            expect(decode(cut, false, true), isTrue);
            expect(() => decode(cut, true, false),
                throwsA(isA<ArchiveChecksumException>()));
          }
          for (final bad in [
            if (name != 'zlib') cut,
            Uint8List.fromList(List.filled(40, 7)),
          ]) {
            expect(decode(bad, false, false), isFalse);
            for (final (v, t) in [(true, false), (false, true)]) {
              expect(
                  () => decode(bad, v, t),
                  throwsA(allOf(isA<ArchiveException>(),
                      isNot(isA<ArchiveChecksumException>()))),
                  reason: 'verify $v, throwOnError $t');
            }
          }
        });
      }

      test('gzip web verifies the zlib stream it falls back to', () {
        expect(const GZipDecoderWeb().decodeBytes(zlib, verify: true), data);
        expect(const GZipDecoder().decodeBytes(zlib, verify: true), data);
      });

      test('web decoders read a stream in either byte order', () {
        for (final order in ByteOrder.values) {
          for (final (decoder, bytes) in [
            (const GZipDecoderWeb(), gzip),
            (const ZLibDecoderWeb(), zlib),
          ]) {
            final input = InputMemoryStream(bytes, byteOrder: order);
            final output = OutputMemoryStream();
            expect(decoder.decodeStream(input, output, verify: true), isTrue,
                reason: '$decoder $order');
            expect(output.getBytes(), data);
            expect(input.byteOrder, order);
          }
        }
      });

      test('zlib verify accepts a whole stream that bytes follow', () {
        final padded = Uint8List.fromList([...zlib, 0, 0, 0, 0]);
        expect(const ZLibDecoder().decodeBytes(padded, verify: true), data);
        expect(
            const ZLibDecoder().decodeStream(
                InputMemoryStream(padded), OutputMemoryStream(),
                verify: true),
            isTrue);
        expect(const GZipDecoder().decodeBytes(padded, verify: true), data);
        expect(
            const GZipDecoder().decodeStream(
                InputMemoryStream(padded), OutputMemoryStream(),
                verify: true),
            isTrue);
      });

      test('zlib verify on dart:io refuses over 4 KB after the stream', () {
        final padded = Uint8List.fromList([...zlib, ...Uint8List(4097)]);
        expect(
            const ZLibDecoder().decodeBytes(padded, throwOnError: true), data);
        expect(() => const ZLibDecoder().decodeBytes(padded, verify: true),
            throwsA(isA<ArchiveChecksumException>()));
        expect(const ZLibDecoderWeb().decodeBytes(padded, verify: true), data);
      });

      test('zlib web keeps a whole stream that bytes follow', () {
        final padded = Uint8List.fromList([...zlib, 0, 0, 0, 0]);
        expect(const ZLibDecoderWeb().decodeBytes(padded), data);
        expect(const ZLibDecoder().decodeBytes(padded), data);
      });

      test('zlib web ignores bytes after a whole stream with either flag', () {
        for (final tail in [
          [0],
          [0, 0, 0, 0],
          [1, 2, 3, 4, 5, 6, 7, 8, 9]
        ]) {
          final padded = Uint8List.fromList([...zlib, ...tail]);
          for (final (v, t) in [(true, false), (false, true)]) {
            expect(
                const ZLibDecoderWeb()
                    .decodeBytes(padded, verify: v, throwOnError: t),
                data,
                reason: 'tail $tail, verify $v, throwOnError $t');
          }
        }
      });
    });

    test('the web decoder writes a file and a sink it cannot read back', () {
      final data = Uint8List(3 * 1024 * 1024 + 12345);
      for (var i = 0; i < data.length; i++) {
        data[i] = (i * 31 + (i >> 11)) & 0xff;
      }
      final one = Uint8List.fromList(GZipEncoder().encodeBytes(data));
      final gz = Uint8List.fromList([...one, ...one]);
      final want = [...data, ...data];

      final path = '$testOutputPath/web_decode.bin';
      final file = OutputFileStream(path);
      expect(
          GZipDecoderWeb()
              .decodeStream(InputMemoryStream(gz), file, verify: true),
          isTrue);
      file.closeSync();
      expect(File(path).readAsBytesSync(), want);

      List<List<int>>? chunks;
      final sink = SinkOutputStream(
          ChunkedConversionSink<List<int>>.withCallback((all) => chunks = all));
      expect(
          GZipDecoderWeb().decodeStream(InputMemoryStream(gz), sink), isTrue);
      sink.sink.close();
      expect(chunks!.expand((c) => c).toList(), want);
    });
  });
}

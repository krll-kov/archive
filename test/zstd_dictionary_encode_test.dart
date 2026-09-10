import 'dart:io';
import 'dart:typed_data';

import 'package:archive/src/codecs/zstd/zstd_dictionary.dart';
import 'package:archive/src/codecs/zstd_decoder.dart';
import 'package:archive/src/codecs/zstd_encoder.dart';
import 'package:archive/src/util/crc32.dart';
import 'package:test/test.dart';

// The decoder side of dictionaries is checked against libzstd's own frames in
// zstd_dictionary_test.dart, so a frame this encoder writes that reads back
// through it has been through the reference on the way
void main() {
  final directory = Directory('test/_data/zstd');
  final trainedBytes =
      File('${directory.path}/dict-trained.dict').readAsBytesSync();
  final rawBytes = File('${directory.path}/dict-raw.dict').readAsBytesSync();
  final trained = ZstdDictionary(trainedBytes);
  final raw = ZstdDictionary(rawBytes);

  final samples = <String, Uint8List>{
    'empty': Uint8List(0),
    'tiny': Uint8List.fromList('hello dictionary world'.codeUnits),
    'dictionary content': Uint8List.sublistView(raw.content),
    'unrelated text': Uint8List.fromList(
        List<int>.generate(60000, (i) => 32 + ((i * 7 + i ~/ 61) % 90))),
  };

  group('zstd encoding with a dictionary', () {
    for (final entry in {'trained': trained, 'raw': raw}.entries) {
      final dictionary = entry.value;
      for (final sample in samples.entries) {
        for (final level in const [1, 3, 5, 9, 12, 15, 19, 22]) {
          test('${entry.key} ${sample.key} at level $level round trips', () {
            final frame = ZstdEncoder(level: level, dictionary: dictionary)
                .encodeBytes(sample.value);
            final back = ZstdDecoder(dictionary: dictionary)
                .decodeBytes(frame, verify: true, throwOnError: true);
            expect(back.length, sample.value.length);
            expect(getCrc32(back), getCrc32(sample.value));
          });
        }
      }
    }

    test('a frame carries the dictionary id, and only that dictionary reads it',
        () {
      final frame =
          ZstdEncoder(level: 3, dictionary: trained).encodeBytes(raw.content);
      expect(trained.id, isNot(0));
      expect(() => ZstdDecoder().decodeBytes(frame, throwOnError: true),
          throwsA(anything));
      expect(
          () => ZstdDecoder(dictionary: raw)
              .decodeBytes(frame, throwOnError: true),
          throwsA(anything));
    });

    test('a raw dictionary names no id, so any decoder can read the frame', () {
      final frame = ZstdEncoder(level: 3, dictionary: raw)
          .encodeBytes(Uint8List.fromList(raw.content.sublist(0, 500)));
      final back = ZstdDecoder(dictionary: raw)
          .decodeBytes(frame, verify: true, throwOnError: true);
      expect(back.length, 500);
    });

    test('the dictionary is what makes the frame small', () {
      final content = Uint8List.sublistView(raw.content);
      final withDictionary =
          ZstdEncoder(level: 9, dictionary: raw).encodeBytes(content);
      final without = ZstdEncoder(level: 9).encodeBytes(content);
      expect(withDictionary.length, lessThan(without.length ~/ 4));
    });
  });
}

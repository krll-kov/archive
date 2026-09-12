import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

Future<Uint8List> _encode(Uint8List src,
    {int level = 6, int workers = 4, int jobSize = 0, int overlapLog = 0}) {
  final done = Completer<Uint8List>();
  final returned = ZstdEncoder(checksum: false, level: level).encodeBytes(src,
      multithread: ZstdMultithreadOptions(
        onDone: done.complete,
        onError: done.completeError,
        workers: workers,
        jobSize: jobSize,
        overlapLog: overlapLog,
      ));
  expect(returned, isEmpty);
  return done.future;
}

void main() {
  // Long runs and a scatter of noise, so the parse has both matches and
  // literals to choose between across a job boundary
  final input = Uint8List(1500000);
  var state = 1;
  for (var i = 0; i < input.length; i++) {
    state = state * 48271 % 2147483647;
    input[i] = i % 3000 < 2400 ? (i >> 4) & 0xff : state & 0xff;
  }

  test('the frame decodes back to the input', () async {
    final frame = await _encode(input, jobSize: 524288);
    expect(ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
        input);
  });

  test('the worker count does not change the bytes', () async {
    final one = await _encode(input, workers: 1, jobSize: 524288);
    for (final workers in [2, 3, 8]) {
      expect(await _encode(input, workers: workers, jobSize: 524288), one,
          reason: 'workers $workers');
    }
  });

  test('job size and overlap do change them', () async {
    final held = await _encode(input, jobSize: 524288);
    expect(await _encode(input, jobSize: 1048576), isNot(held));
    expect(await _encode(input, jobSize: 524288, overlapLog: 9), isNot(held));
  });

  test('an input below the job minimum is the single threaded frame',
      () async {
    final small = Uint8List.sublistView(input, 0, 300000);
    expect(await _encode(small),
        ZstdEncoder(checksum: false, level: 6).encodeBytes(small));
  });

  test('a checksum still covers the whole input', () async {
    final done = Completer<Uint8List>();
    ZstdEncoder(level: 1).encodeBytes(input,
        multithread: ZstdMultithreadOptions(
            onDone: done.complete, jobSize: 524288, workers: 2));
    final frame = await done.future;
    expect(ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
        input);
  });

  // Sizes and CRC32s of the frame this writes with 512 KB jobs, each one
  // checked against `zstd -T4` when it was taken
  const golden = {
    1: [347511, 2857033639], 2: [338931, 821975185], 3: [330656, 2728980344],
    4: [331597, 3025348148], 5: [330535, 824438816], 6: [307385, 553688082],
    7: [303744, 1404570688], 8: [303756, 1183189126], 9: [303756, 1183189126],
    10: [303739, 2920552062], 11: [303639, 711546979], 12: [303639, 711546979],
    13: [303620, 3284221855], 14: [303759, 3336732534],
    15: [303840, 4031621013], 16: [303038, 338922815], 17: [303040, 1808676593],
    18: [302871, 1862306182], 19: [302812, 3661292887],
    20: [302812, 3661292887], 21: [302834, 645373895], 22: [302845, 4012362388],
  };
  for (var level = 1; level <= 22; level++) {
    test('level $level writes the frame the reference writes', () async {
      final frame = await _encode(input, level: level, jobSize: 524288);
      expect([frame.length, getCrc32(frame)], golden[level]);
    });
  }

  Future<Uint8List> transform(int workers, {int jobSize = 524288}) async {
    final pieces = <List<int>>[];
    for (var at = 0; at < input.length; at += 100000) {
      final end = at + 100000 < input.length ? at + 100000 : input.length;
      pieces.add(Uint8List.sublistView(input, at, end));
    }
    final out = <int>[];
    await for (final piece in Stream.fromIterable(pieces).transform(ZstdCodec(
      level: 6,
      frameChecksum: false,
      multithread: ZstdMultithreadOptions(workers: workers, jobSize: jobSize),
    ).encoder)) {
      out.addAll(piece);
    }
    return Uint8List.fromList(out);
  }

  test('the transform path writes a frame that decodes back', () async {
    final frame = await transform(4);
    expect(ZstdDecoder().decodeBytes(frame, verify: true, throwOnError: true),
        input);
  });

  test('the transform path does not depend on the worker count', () async {
    final one = await transform(1);
    expect(await transform(4), one);
    expect(await transform(8), one);
  });

  test('a sink refuses the options, since it cannot wait for a worker', () {
    expect(
        () => ZstdCodec(
                multithread: ZstdMultithreadOptions(workers: 2))
            .encoder
            .startChunkedConversion(_Held()),
        throwsArgumentError);
  });

  test('settings that cannot be honoured are refused', () {
    void call({int workers = 1, int jobSize = 0, int overlapLog = 0}) =>
        ZstdEncoder().encodeBytes(input,
            multithread: ZstdMultithreadOptions(
                onDone: (_) {},
                workers: workers,
                jobSize: jobSize,
                overlapLog: overlapLog));
    expect(() => call(workers: 0), throwsArgumentError);
    expect(() => call(overlapLog: 10), throwsArgumentError);
    expect(() => call(overlapLog: -1), throwsArgumentError);
    expect(() => call(jobSize: -1), throwsArgumentError);
  });

  test('a dictionary goes to the first job and the frame names it', () async {
    final dictionary = ZstdDictionary(Uint8List.sublistView(input, 0, 4096));
    final done = Completer<Uint8List>();
    ZstdEncoder(checksum: false, level: 6, dictionary: dictionary)
        .encodeBytes(input,
            multithread: ZstdMultithreadOptions(
                onDone: done.complete,
                onError: done.completeError,
                jobSize: 524288,
                workers: 4));
    final frame = await done.future;
    expect(
        ZstdDecoder(dictionary: dictionary)
            .decodeBytes(frame, verify: true, throwOnError: true),
        input);
  });
}

class _Held implements Sink<List<int>> {
  @override
  void add(List<int> data) {}
  @override
  void close() {}
}

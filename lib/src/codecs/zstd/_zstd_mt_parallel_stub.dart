import 'dart:typed_data';

import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import 'zstd_dictionary.dart';
import 'zstd_mt_frame_encoder.dart';

const bool zstdIsolatesSupported = false;

/// Compresses the jobs in the calling isolate, which is what a target without
/// [Isolate] can do. The bytes are the ones the workers would have produced
Future<List<Uint8List>> zstdMtCompressJobs(
    Uint8List src, List<int> starts, int prefixSize, int level,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    int cap = 0,
    bool firstIsFirstJob = true,
    int size = 0}) {
  final parts = <Uint8List>[];
  for (var i = 0; i < starts.length; i++) {
    final start = starts[i];
    final end = i + 1 < starts.length ? starts[i + 1] : src.length;
    final prefix = start < prefixSize ? start : prefixSize;
    final out = OutputMemoryStream();
    ZstdMtFrameEncoder.encodeJob(
        Uint8List.sublistView(src, start - prefix, end), prefix, out, level,
        src.length,
        firstJob: i == 0 && firstIsFirstJob,
        lastJob: i == starts.length - 1,
        jobSize: jobSize,
        overlapLog: overlapLog);
    parts.add(out.getBytes());
  }
  return Future.value(parts);
}

/// The same jobs, cut out of the arriving bytes and compressed in the calling
/// isolate, which is what a target without [Isolate] can do
Stream<Uint8List> zstdMtCompressStream(Stream<List<int>> input, int level,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    int cap = 0,
    ZstdDictionary? dictionary}) async* {
  final geometry = ZstdMtFrameEncoder.geometry(level, zstdMtSizeUnknown,
      jobSize: jobSize, overlapLog: overlapLog);
  final ring = ZstdMtRing(geometry[0], geometry[1]);
  var index = 0;
  Uint8List run(Uint8List job, bool first, bool last) {
    final out = OutputMemoryStream();
    var buffer = job;
    var prefix = first ? 0 : geometry[1];
    final dict = dictionary;
    if (first && dict != null) {
      final content = dict.content;
      buffer = Uint8List(content.length + job.length)
        ..setRange(0, content.length, content)
        ..setRange(content.length, content.length + job.length, job);
      prefix = content.length;
    }
    ZstdMtFrameEncoder.encodeJob(
        buffer, prefix, out, level, zstdMtSizeUnknown,
        firstJob: first,
        lastJob: last,
        jobSize: jobSize,
        overlapLog: overlapLog,
        dictionary: first ? dict : null);
    return out.getBytes();
  }

  await for (final chunk in input) {
    for (final job in ring.add(chunk)) {
      yield run(job, index == 0, false);
      index++;
    }
  }
  yield run(ring.close(), index == 0, true);
}

/// There are no files to read from where this file is chosen
Future<List<Uint8List>> zstdMtCompressFileJobs(String path, int offset,
    int size, List<int> starts, int prefixSize, int level,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    int cap = 0,
    void Function(Uint8List part)? onPart}) =>
    throw UnsupportedError('zstd: no file access on this target');

int zstdMtFileDigest(String path, int offset, int size) =>
    throw UnsupportedError('zstd: no file access on this target');

List<Object>? zstdMtFileRegion(InputStream input) => null;

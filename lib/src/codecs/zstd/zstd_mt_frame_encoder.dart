import 'dart:typed_data';

import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '../../util/xxh64.dart';
import 'zstd_block_encoder.dart';
import 'zstd_block_splitter.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_level_params.dart';
import 'zstd_mt_parallel.dart';

/// `4*ZSTD_BLOCKSIZE_MAX`, the piece a job's input reaches the compressor in.
/// Every piece ends a block, which is what makes a threaded frame differ from
/// a single threaded one
const zstdMtChunkSize = 4 * zstdBlockMaximumSize;

/// `ZSTDMT_JOBSIZE_MIN`: at or below this the reference drops its workers, so
/// the frame is the one the single threaded encoder writes
const zstdMtJobSizeMin = 512 * 1024;

/// `ZSTDMT_JOBLOG_MAX`
const _jobLogMax = 29;

/// What the reference reads for a size it has not been told, which is the row
/// it picks and the window it leaves unclamped
const zstdMtSizeUnknown = 1099511627776;

/// Writes the frame `ZSTD_compress2` writes with `nbWorkers` above zero: the
/// input cut into jobs, each parsed from its own tables over a prefix of the
/// one before, and every job fed to the block loop a chunk at a time.
///
/// This is the single threaded form of that. It exists to be compared against
/// the reference before any isolate does the work, and it shares no state with
/// [ZstdFrameEncoder], whose bytes must not move
class ZstdMtFrameEncoder {
  final Xxh64 _hash = Xxh64();
  final Uint32List _rep = Uint32List(3);
  final ZstdBlockSplitter _splitter = ZstdBlockSplitter();

  /// [jobSize] and [overlapLog] are `ZSTD_c_jobSize` and `ZSTD_c_overlapLog`,
  /// zero for the level's own
  void encode(Uint8List src, int start, int end, OutputStream out,
      {bool checksum = true,
      int level = zstdDefaultLevel,
      int jobSize = 0,
      int overlapLog = 0}) {
    final size = end - start;
    final params = zstdParamsForLevel(level, size);
    final matchWindow = 1 << params.windowLog;
    final singleSegment = size <= matchWindow;
    final windowSize = singleSegment ? size : matchWindow;

    _writeHeader(out, size, singleSegment, checksum, params.windowLog);
    if (checksum) {
      _hash.reset();
      _hash.update(src, start, size);
    }

    final blockSizeMax =
        windowSize < zstdBlockMaximumSize ? windowSize : zstdBlockMaximumSize;
    final prefixSize = _prefixSize(params, overlapLog);
    var job = jobSize > 0 ? jobSize : 1 << _targetJobLog(params);
    if (job < prefixSize) {
      job = prefixSize;
    }

    var at = start;
    var first = true;
    while (first || at < end) {
      first = false;
      final jobEnd = end - at < job ? end : at + job;
      final lastJob = jobEnd >= end;
      final before = at - start;
      final prefix = before < prefixSize ? before : prefixSize;
      _encodeJob(src, at - prefix, at, jobEnd, out, matchWindow, blockSizeMax,
          params, at == start, lastJob && jobEnd == end, null);
      at = jobEnd;
      if (lastJob) {
        break;
      }
    }

    if (checksum) {
      final digest = _hash.digestLow;
      out.writeByte(digest & 0xff);
      out.writeByte((digest >>> 8) & 0xff);
      out.writeByte((digest >>> 16) & 0xff);
      out.writeByte((digest >>> 24) & 0xff);
    }
  }

  /// One job, its input handed to the block loop in [zstdMtChunkSize] pieces.
  /// The splitter sees a piece as the whole of what is left, which is what
  /// cuts a block short at every piece boundary
  void _encodeJob(
      Uint8List src,
      int base,
      int start,
      int end,
      OutputStream out,
      int matchWindow,
      int blockSizeMax,
      ZstdLevelParams params,
      bool firstJob,
      bool lastJob,
      ZstdDictionary? dictionary) {
    final blocks = ZstdBlockEncoder(blockSizeMax, params);
    if (dictionary != null) {
      // Only the first job is given one, as `ZSTDMT_compressionJob` asserts,
      // and it takes its repeat offsets from it rather than from the frame's
      blocks.prime(src, base, start, dictionary);
      _rep.setAll(0, dictionary.repeatOffsets);
    } else {
      if (start > base) {
        // `forceMaxWindow` leaves `loadedDictEnd` at zero, so the prefix is
        // bounded by the window like any other input
        blocks.primeRawPrefix(src, base, start);
      }
      // `ZSTD_invalidateRepCodes`: a job after the first starts with no usable
      // repeat offsets at all, not with the frame's initial three
      _rep.setAll(0, firstJob ? zstdInitialRepeatOffsets : const [0, 0, 0]);
    }
    var savings = 0;
    var at = start;
    if (start == end) {
      blocks.encode(src, at, at, at, out, lastJob, _rep);
      return;
    }
    while (at < end) {
      final done = at - start;
      var chunkEnd = start + (done - done % zstdMtChunkSize) + zstdMtChunkSize;
      if (chunkEnd > end) {
        chunkEnd = end;
      }
      final take = _splitter.sizeFor(
          src, at, chunkEnd - at, blockSizeMax, params, savings);
      // `ZSTD_checkDictValidity` measures from the end of the block, and what
      // it drops stays dropped
      if (blocks.dictionaryEnd != 0 &&
          at + take - blocks.dictionaryEnd > matchWindow) {
        blocks.dropDictionary();
      }
      final reach =
          blocks.dictionaryEnd != 0 ? base : at - matchWindow;
      final before = out.length;
      blocks.encode(src, at, at + take, reach > base ? reach : base, out,
          lastJob && at + take == end, _rep);
      savings += take - (out.length - before);
      at += take;
      // What the first block cost says what the rest will, near enough to take
      // the room once instead of doubling into it. A job never exceeds its own
      // bound, so neither does the estimate
      if (at - start == take && at < end) {
        final span = end - start;
        final bound = span + (span >> 7) + 64;
        var want = out.length + (out.length * (end - at)) ~/ take;
        want += want >> 3;
        out.reserve(want < bound ? want : bound);
      }
    }
  }

  /// `ZSTDMT_computeTargetJobLog` without the long distance matcher, which
  /// this path does not take yet
  static int _targetJobLog(ZstdLevelParams params) {
    final log = params.windowLog + 2 > 20 ? params.windowLog + 2 : 20;
    return log > _jobLogMax ? _jobLogMax : log;
  }

  /// `ZSTDMT_computeOverlapSize`
  static int _prefixSize(ZstdLevelParams params, int overlapLog) {
    final log = overlapLog > 0 ? overlapLog : _overlapLogDefault(params);
    final reverse = 9 - log;
    if (reverse >= 8) {
      return 0;
    }
    return 1 << (params.windowLog - reverse);
  }

  /// `ZSTDMT_overlapLog_default`, by the reference's own strategy numbering,
  /// which [ZstdLevelParams.refStrategy] carries
  static int _overlapLogDefault(ZstdLevelParams params) {
    switch (params.refStrategy) {
      case 9:
        return 9;
      case 8:
      case 7:
        return 8;
      case 6:
      case 5:
        return 7;
      default:
        return 6;
    }
  }

  static void _writeHeader(OutputStream out, int size, bool singleSegment,
      bool checksum, int windowLog, [int dictionaryId = 0]) {
    final int contentSizeFlag;
    if (singleSegment && size < 256) {
      contentSizeFlag = 0;
    } else if (size >= 256 && size < 65536 + 256) {
      contentSizeFlag = 1;
    } else if (size < 4294967296) {
      contentSizeFlag = 2;
    } else {
      contentSizeFlag = 3;
    }

    out.writeByte(zstdMagic & 0xff);
    out.writeByte((zstdMagic >>> 8) & 0xff);
    out.writeByte((zstdMagic >>> 16) & 0xff);
    out.writeByte((zstdMagic >>> 24) & 0xff);
    // `ZSTD_writeFrameHeader`: as many bytes as the id needs, and the flag
    // names which of the four widths that is
    final idFlag = dictionaryId == 0
        ? 0
        : (dictionaryId < 256 ? 1 : (dictionaryId < 65536 ? 2 : 3));
    out.writeByte((contentSizeFlag << 6) |
        (singleSegment ? 0x20 : 0) |
        (checksum ? 4 : 0) |
        idFlag);
    if (!singleSegment) {
      out.writeByte((windowLog - 10) << 3);
    }
    final idBytes = const [0, 1, 2, 4][idFlag];
    for (var i = 0; i < idBytes; i++) {
      out.writeByte((dictionaryId >>> (i << 3)) & 0xff);
    }

    if (contentSizeFlag == 0) {
      out.writeByte(size);
    } else if (contentSizeFlag == 1) {
      final value = size - 256;
      out.writeByte(value & 0xff);
      out.writeByte((value >>> 8) & 0xff);
    } else if (contentSizeFlag == 2) {
      for (var i = 0; i < 4; i++) {
        out.writeByte((size >>> (i << 3)) & 0xff);
      }
    } else {
      for (var i = 0; i < 8; i++) {
        out.writeByte((size >>> (i << 3)) & 0xff);
      }
    }
  }

  /// The span of one job and the prefix before it, which is what a caller
  /// needs to cut the input up before handing the pieces out
  static List<int> geometry(int level, int size,
      {int jobSize = 0, int overlapLog = 0}) {
    final params = zstdParamsForLevel(level, size);
    final prefix = _prefixSize(params, overlapLog);
    var job = jobSize > 0 ? jobSize : 1 << _targetJobLog(params);
    if (job < prefix) {
      job = prefix;
    }
    return [job, prefix];
  }

  /// One job on its own, holding nothing between calls: [buffer] is its prefix
  /// followed by its own span, and [size] the whole frame's
  static void encodeJob(Uint8List buffer, int prefix, OutputStream out,
      int level, int size,
      {required bool firstJob,
      required bool lastJob,
      int jobSize = 0,
      int overlapLog = 0,
      ZstdDictionary? dictionary}) {
    final params = zstdParamsForLevel(level, size);
    final matchWindow = 1 << params.windowLog;
    final windowSize = size <= matchWindow ? size : matchWindow;
    final blockSizeMax =
        windowSize < zstdBlockMaximumSize ? windowSize : zstdBlockMaximumSize;
    ZstdMtFrameEncoder()._encodeJob(buffer, 0, prefix, buffer.length, out,
        matchWindow, blockSizeMax, params, firstJob, lastJob, dictionary);
  }
}

/// Cuts a stream of arriving bytes into jobs. Each job carries the prefix the
/// reference gives it, the tail of the job before, so a worker needs nothing
/// else; the ring holds one job and one prefix at a time
class ZstdMtRing {
  final int jobSize;
  final int prefixSize;
  final _held = BytesBuilder(copy: false);
  Uint8List _prefix = Uint8List(0);
  var _jobs = 0;

  ZstdMtRing(this.jobSize, this.prefixSize);

  int get jobCount => _jobs;

  /// Takes what arrived and returns the jobs it completes, prefix included
  List<Uint8List> add(List<int> data) {
    _held.add(data);
    final out = <Uint8List>[];
    while (_held.length >= jobSize) {
      final taken = _held.takeBytes();
      out.add(_cut(Uint8List.sublistView(taken, 0, jobSize)));
      _held.add(Uint8List.sublistView(taken, jobSize));
    }
    return out;
  }

  /// The last job, which is whatever is left and may be empty
  Uint8List close() => _cut(_held.takeBytes());

  Uint8List _cut(Uint8List body) {
    final job = Uint8List(_prefix.length + body.length)
      ..setRange(0, _prefix.length, _prefix)
      ..setRange(_prefix.length, _prefix.length + body.length, body);
    final keep = body.length < prefixSize ? body.length : prefixSize;
    // A view would keep the whole job alive behind it, so the tail is copied
    _prefix = Uint8List.fromList(Uint8List.sublistView(job, job.length - keep));
    _jobs++;
    return job;
  }
}

/// What one worker holds: the copy of its job and prefix that crossed the
/// port, the output it builds, and the level's tables
int zstdMtWorkerCost(int level, int size, List<int> geometry) {
  final params = zstdParamsForLevel(level, size);
  final span = geometry[0] < size ? geometry[0] : size;
  final tables = (1 << params.hashLog) * 4 +
      (1 << params.chainLog) * 4 +
      (1 << params.windowLog);
  return span + geometry[1] + span + (span >> 7) + 64 + tables;
}

/// The threaded frame of a file, written into [out] without the input ever
/// sitting in this isolate: a worker reads its own job from disk
Future<void> zstdMtCompressFile(
    String path, int offset, int size, int level, OutputStream out,
    {bool checksum = true,
    int jobSize = 0,
    int overlapLog = 0,
    int workers = 1,
    int memoryBudget = 0}) async {
  final geometry = ZstdMtFrameEncoder.geometry(level, size,
      jobSize: jobSize, overlapLog: overlapLog);
  final starts = _jobStarts(size, geometry[0]);
  final params = zstdParamsForLevel(level, size);
  ZstdMtFrameEncoder._writeHeader(
      out, size, size <= 1 << params.windowLog, checksum, params.windowLog);
  await zstdMtCompressFileJobs(path, offset, size, starts, geometry[1], level,
      jobSize: jobSize,
      overlapLog: overlapLog,
      workers: workers,
      cap: _cap(memoryBudget, level, size, geometry),
      onPart: out.writeBytes);
  if (checksum) {
    _writeChecksum(out, zstdMtFileDigest(path, offset, size));
  }
}

List<int> _jobStarts(int size, int job) {
  final starts = <int>[0];
  for (var at = job; at < size; at += job) {
    starts.add(at);
  }
  return starts;
}

int _cap(int memoryBudget, int level, int size, List<int> geometry) {
  if (memoryBudget <= 0) {
    return 0;
  }
  final cap = memoryBudget ~/ zstdMtWorkerCost(level, size, geometry);
  return cap < 1 ? 1 : cap;
}

/// The header a streamed frame opens with: no content size, because it is not
/// known when the header is written, and the level's window unclamped
void writeZstdMtStreamHeader(OutputStream out, bool checksum, int level,
    [int dictionaryId = 0]) {
  final params = zstdParamsForLevel(level, zstdMtSizeUnknown);
  final idFlag = dictionaryId == 0
      ? 0
      : (dictionaryId < 256 ? 1 : (dictionaryId < 65536 ? 2 : 3));
  out.writeByte(zstdMagic & 0xff);
  out.writeByte((zstdMagic >>> 8) & 0xff);
  out.writeByte((zstdMagic >>> 16) & 0xff);
  out.writeByte((zstdMagic >>> 24) & 0xff);
  out.writeByte((checksum ? 4 : 0) | idFlag);
  out.writeByte((params.windowLog - 10) << 3);
  for (var i = 0; i < const [0, 1, 2, 4][idFlag]; i++) {
    out.writeByte((dictionaryId >>> (i << 3)) & 0xff);
  }
}

/// The four checksum bytes a frame ends with, taken over the whole input
void writeZstdMtChecksum(OutputStream out, int digest) =>
    _writeChecksum(out, digest);

void _writeChecksum(OutputStream out, int digest) {
  out.writeByte(digest & 0xff);
  out.writeByte((digest >>> 8) & 0xff);
  out.writeByte((digest >>> 16) & 0xff);
  out.writeByte((digest >>> 24) & 0xff);
}

/// The threaded frame, its jobs compressed wherever [zstdMtCompressJobs] puts
/// them and pasted together in job order. The header and the checksum are the
/// caller's, since a job writes neither
Future<Uint8List> zstdMtCompress(Uint8List src, int level,
    {bool checksum = true,
    int jobSize = 0,
    int overlapLog = 0,
    int workers = 1,
    int memoryBudget = 0,
    ZstdDictionary? dictionary}) async {
  final geometry = ZstdMtFrameEncoder.geometry(level, src.length,
      jobSize: jobSize, overlapLog: overlapLog);
  final starts = <int>[0];
  for (var at = geometry[0]; at < src.length; at += geometry[0]) {
    starts.add(at);
  }
  var cap = 0;
  if (memoryBudget > 0) {
    cap = memoryBudget ~/ zstdMtWorkerCost(level, src.length, geometry);
    if (cap < 1) {
      cap = 1;
    }
  }
  // The reference gives the dictionary to job zero only, so that one is done
  // here rather than plumbed through the port, and the rest go to the pool
  Uint8List? firstPart;
  var rest = starts;
  if (dictionary != null) {
    final firstEnd = starts.length > 1 ? starts[1] : src.length;
    final content = dictionary.content;
    final held = Uint8List(content.length + firstEnd)
      ..setRange(0, content.length, content)
      ..setRange(content.length, content.length + firstEnd, src);
    final out0 = OutputMemoryStream();
    ZstdMtFrameEncoder.encodeJob(held, content.length, out0, level, src.length,
        firstJob: true,
        lastJob: starts.length == 1,
        jobSize: jobSize,
        overlapLog: overlapLog,
        dictionary: dictionary);
    firstPart = out0.getBytes();
    rest = starts.sublist(1);
  }
  final parts = rest.isEmpty
      ? const <Uint8List>[]
      : await zstdMtCompressJobs(src, rest, geometry[1], level,
          jobSize: jobSize,
          overlapLog: overlapLog,
          workers: workers,
          cap: cap,
          firstIsFirstJob: dictionary == null,
          size: src.length);

  final out = OutputMemoryStream();
  final params = zstdParamsForLevel(level, src.length);
  ZstdMtFrameEncoder._writeHeader(out, src.length,
      src.length <= 1 << params.windowLog, checksum, params.windowLog,
      dictionary?.id ?? 0);
  if (firstPart != null) {
    out.writeBytes(firstPart);
  }
  for (final part in parts) {
    out.writeBytes(part);
  }
  if (checksum) {
    final hash = Xxh64()..reset();
    hash.update(src, 0, src.length);
    final digest = hash.digestLow;
    out.writeByte(digest & 0xff);
    out.writeByte((digest >>> 8) & 0xff);
    out.writeByte((digest >>> 16) & 0xff);
    out.writeByte((digest >>> 24) & 0xff);
  }
  return out.getBytes();
}

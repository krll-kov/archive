import 'dart:async';
import 'dart:typed_data';

import '../util/archive_exception.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'zstd/zstd_dictionary.dart';
import 'zstd/zstd_frame_encoder.dart';
import 'zstd/zstd_level_params.dart';
import 'zstd/zstd_mt_frame_encoder.dart';
import 'zstd/zstd_mt_parallel.dart';
import 'zstd/zstd_multithread_options.dart';

export 'zstd/zstd_multithread_options.dart';

/// Compress data with the zstd format encoder
class ZstdEncoder {
  /// Whether the frame carries an XXH64 of its content
  final bool checksum;

  final int level;

  /// Placed before the content so matches can reach into it, and named in the
  /// frame header, so only the same dictionary reads the frame back
  final ZstdDictionary? dictionary;

  const ZstdEncoder(
      {this.checksum = true, this.level = zstdDefaultLevel, this.dictionary});

  /// With [multithread] the frame is the one `zstd -T` writes, not the one the
  /// single threaded encoder writes, and it arrives through `onDone` rather
  /// than as the return value, which is then empty.
  ///
  /// A setting that cannot be honoured throws [ArgumentError] here, while the
  /// caller is still on the stack; only a failure of the work itself reaches
  /// `onError`, and without one it reaches `onDone` as empty output
  Uint8List encodeBytes(List<int> data,
      {int? level, ZstdMultithreadOptions<Uint8List>? multithread}) {
    if (multithread == null) {
      final output = OutputMemoryStream();
      encodeStream(InputMemoryStream(data), output, level: level);
      return output.getBytes();
    }
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    _checkMultithread(multithread);
    final chosen = level ?? this.level;
    _reportAsync(multithread,
        () => _multithreadBytes(bytes, chosen, multithread), Uint8List(0));
    return Uint8List(0);
  }

  /// `ZSTDMT_JOBSIZE_MIN`: the reference turns its workers off below this, so
  /// the frame is the single threaded one
  Future<Uint8List> _multithreadBytes(
      Uint8List bytes, int level, ZstdMultithreadOptions<Object?> options) {
    if (bytes.length <= zstdMtJobSizeMin) {
      return Future.value(encodeBytes(bytes, level: level));
    }
    return zstdMtCompress(bytes, level,
        checksum: checksum,
        jobSize: options.jobSize,
        overlapLog: options.overlapLog,
        workers: options.workers ?? 0,
        memoryBudget: options.memoryBudget ?? zstdDefaultMemoryBudget,
        dictionary: _dictionary);
  }

  static void _reportAsync<T>(ZstdMultithreadOptions<T> options,
      Future<T> Function() work, T onFailure) {
    final onDone = options.onDone!;
    unawaited(work().then(onDone, onError: (Object error, StackTrace stack) {
      final onError = options.onError;
      if (onError != null) {
        onError(_wrap(error), stack);
      } else {
        onDone(onFailure);
      }
    }));
  }

  void _checkMultithread<T>(ZstdMultithreadOptions<T> options) {
    if (options.onDone == null) {
      throw ArgumentError.value(
          null,
          'onDone',
          'Must be given here, since this call has nowhere else to put the '
              'result; only a stream carries its own end');
    }
    checkZstdMultithreadOptions(options);
  }

  ZstdDictionary? get _dictionary {
    final dict = dictionary;
    return dict != null && dict.usableForEncode ? dict : null;
  }

  List<int> encode(List<int> data, {int? level}) =>
      encodeBytes(data, level: level);

  /// Compress [input] into [output] as one frame, holding only its window.
  ///
  /// With [multithread] over a file, each worker reads its own job from disk,
  /// so the input never sits in this isolate; over any other stream the bytes
  /// are read in first. `onDone` is called with true when the frame is written
  void encodeStream(InputStream input, OutputStream output,
      {int? level, ZstdMultithreadOptions<bool>? multithread}) {
    if (multithread != null) {
      _checkMultithread(multithread);
      final chosen = level ?? this.level;
      // Reading the input is part of the work and reports through onError. The
      // body up to the first await still runs here, so the input is consumed
      // before the call returns, as it was when the reads stood outside
      _reportAsync(multithread, () async {
        final region = zstdMtFileRegion(input);
        // A dictionary belongs to the first job, and a worker reading its own
        // slice of a file has no way to be given one, so that path reads the
        // bytes in instead
        if (input.length <= zstdMtJobSizeMin ||
            region == null ||
            _dictionary != null) {
          final bytes = input.toUint8List();
          input.skip(input.length);
          output
              .writeBytes(await _multithreadBytes(bytes, chosen, multithread));
          return true;
        }
        input.skip(input.length);
        await zstdMtCompressFile(region[0] as String, region[1] as int,
            region[2] as int, chosen, output,
            checksum: checksum,
            jobSize: multithread.jobSize,
            overlapLog: multithread.overlapLog,
            workers: multithread.workers ?? 0,
            memoryBudget: multithread.memoryBudget ?? zstdDefaultMemoryBudget);
        return true;
      }, false);
      return;
    }
    try {
      ZstdFrameEncoder().encodeStream(input, input.length, output,
          checksum: checksum,
          level: level ?? this.level,
          dictionary: dictionary);
    } catch (error, stack) {
      Error.throwWithStackTrace(_wrap(error), stack);
    }
  }

  /// The codec's own exceptions live inside `src` and a caller cannot name
  /// them, so the one type the package exports is what leaves here
  static Object _wrap(Object error) => error is ArchiveException ||
          error is ArgumentError ||
          error is OutOfMemoryError
      ? error
      : ArchiveException('zstd: $error');
}

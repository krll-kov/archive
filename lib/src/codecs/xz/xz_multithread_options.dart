import '_xz_no_result.dart';

/// How much memory the isolates may hold at once by default, in bytes
const xzDefaultMemoryBudget = 1024 * 1024 * 1024;

/// Pass one of these to an [XZDecoder] call to spread it over isolates. An
/// isolate cannot be waited on synchronously. The call returns an empty result
/// at once and the real result goes to [onDone]
class XZMultithreadOptions<T> {
  /// Called exactly once. It runs even when the archive was not worth
  /// splitting, and on platforms with no isolates. Neither case needs any
  /// handling of its own
  final void Function(T result) onDone;

  /// A corrupt or truncated archive reaches this only with `throwOnError`.
  /// Without it the partial output goes to [onDone]. Null together with
  /// `throwOnError` is refused. A bad setting throws [ArgumentError] at the
  /// call instead
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// At least 1. It is clamped to the block count and to the processor count.
  /// More workers than cores costs memory and context switches and decodes no
  /// faster. [memoryBudget] can still lower it
  final int? workers;

  /// Decides how many blocks run at once, on top of [workers]. One worker
  /// always runs, however small this is.
  ///
  /// A worker is charged for its dictionary and staging buffer, plus the
  /// compressed block for an archive in memory or [fileReadBufferSize] for one
  /// in a file, plus one decoded block when the output only appends. Dart
  /// cannot ask the system how much memory is free
  final int? memoryBudget;

  /// Only `decodeStream` over an `InputFileStream` uses this. A stream cannot
  /// cross an isolate boundary and a worker never reaches the input's own
  /// `bufferSize`.
  ///
  /// Workers read different parts of the file at once, and where a seek costs
  /// something this decides how often it is paid. A 189 MB block takes 1312
  /// reads through 256 KB, 368 through 1 MB and 52 through the 8 MB default.
  /// It counts against [memoryBudget] like everything else
  final int fileReadBufferSize;

  const XZMultithreadOptions({
    required this.onDone,
    this.onError,
    this.workers,
    this.memoryBudget,
    this.fileReadBufferSize = 8 * 1024 * 1024,
  });

  /// The options a `Converter` takes, the `xzCodec` transform. A stream carries
  /// its own end and [onDone] is never called. decodeBytes and decodeStream
  /// refuse these options
  const XZMultithreadOptions.converter({
    this.onError,
    this.workers,
    this.memoryBudget,
    this.fileReadBufferSize = 8 * 1024 * 1024,
  }) : onDone = xzNoResult;
}

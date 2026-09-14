import '_xz_no_result.dart';

/// Default ceiling on the memory the isolates may hold at once, in bytes
const xzDefaultMemoryBudget = 1024 * 1024 * 1024;

/// Pass one of these to an [XZDecoder] call to spread it over isolates. You
/// cannot wait on an isolate synchronously, so the call returns an empty
/// result at once and the real result goes to [onDone]
class XZMultithreadOptions<T> {
  /// Called exactly once. We call it even when the archive was not worth
  /// splitting, and on platforms with no isolates, so you never special case
  /// either
  final void Function(T result) onDone;

  /// A corrupt or truncated archive reaches this only with `throwOnError`.
  /// Without it that is not an error, and the partial output goes to [onDone].
  /// We refuse null together with `throwOnError`. The exception it asks for
  /// would have nowhere to go. A bad setting never lands here. It throws
  /// [ArgumentError] at the call
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// At least 1. We clamp it to the block count and to the processor count.
  /// More workers than cores costs memory and context switches and decodes no
  /// faster. [memoryBudget] can still lower it
  final int? workers;

  /// Decides how many blocks run at once. It applies on top of [workers], even
  /// when you set those. One worker always runs, however small this is.
  ///
  /// We charge a worker for its dictionary and staging buffer. We add the
  /// compressed block if the archive came as bytes, or [fileReadBufferSize] if
  /// it came as a file. We add one decoded block if the output only appends.
  ///
  /// Dart cannot ask the system how much memory is free, so a phone and a
  /// workstation need different values here
  final int? memoryBudget;

  /// Only `decodeStream` over an `InputFileStream` uses this. A stream cannot
  /// cross an isolate boundary, so a worker cannot reach the `bufferSize` you
  /// chose.
  ///
  /// Workers read different parts of the file at once. Where a seek costs
  /// something, this decides how often we pay it. A 189 MB block takes 1312
  /// reads through 256 KB, 368 through 1 MB and 52 through the 8 MB default.
  ///
  /// It counts against [memoryBudget] like everything else, so raising it
  /// lowers the worker count
  final int fileReadBufferSize;

  const XZMultithreadOptions({
    this.onDone = xzNoResult,
    this.onError,
    this.workers,
    this.memoryBudget,
    this.fileReadBufferSize = 8 * 1024 * 1024,
  });
}

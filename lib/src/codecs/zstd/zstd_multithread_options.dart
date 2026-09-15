/// Default ceiling on what the workers may hold at once, in bytes
const zstdDefaultMemoryBudget = 1024 * 1024 * 1024;

/// Compresses one job to a worker and writes the frame `zstd -T` writes. The
/// result arrives through [onDone], since an isolate cannot be waited on.
/// [workers] does not change those bytes, [jobSize] and [overlapLog] do
class ZstdMultithreadOptions<T> {
  /// Where the result goes when the call has nowhere else to put it. A stream
  /// converter carries its own end, so `transform` leaves this null
  final void Function(T result)? onDone;

  /// Where a failure of the work goes. A field below that cannot be honoured
  /// does not come here, it throws at the call
  final void Function(Object error, StackTrace stackTrace)? onError;
  final int? workers;
  final int? memoryBudget;

  /// `ZSTD_c_jobSize`, zero for `1 << max(20, windowLog + 2)`
  final int jobSize;

  /// `ZSTD_c_overlapLog`, zero for the level's own, 9 for the whole window
  final int overlapLog;

  const ZstdMultithreadOptions({
    required this.onDone,
    this.onError,
    this.workers,
    this.memoryBudget,
    this.jobSize = 0,
    this.overlapLog = 0,
  });

  /// The options a `Converter` takes, the `zstdCodec` transform. A stream
  /// carries its own end, so there is no result to hand anywhere and [onDone]
  /// stays null. encodeBytes and encodeStream refuse these options
  const ZstdMultithreadOptions.converter({
    this.onError,
    this.workers,
    this.memoryBudget,
    this.jobSize = 0,
    this.overlapLog = 0,
  }) : onDone = null;
}

/// The four fields that describe the work, checked the same way wherever the
/// options arrive: a value no path can honour is a mistake at the call, not a
/// failure of the encode
void checkZstdMultithreadOptions(ZstdMultithreadOptions<Object?> options) {
  final workers = options.workers;
  if (workers != null && workers < 1) {
    throw ArgumentError.value(workers, 'workers', 'Must be at least 1');
  }
  final budget = options.memoryBudget;
  if (budget != null && budget < 1) {
    throw ArgumentError.value(budget, 'memoryBudget', 'Must be at least 1');
  }
  if (options.overlapLog < 0 || options.overlapLog > 9) {
    throw ArgumentError.value(
        options.overlapLog, 'overlapLog', 'Must be 0 to 9');
  }
  if (options.jobSize < 0) {
    throw ArgumentError.value(
        options.jobSize, 'jobSize', 'Must not be negative');
  }
}

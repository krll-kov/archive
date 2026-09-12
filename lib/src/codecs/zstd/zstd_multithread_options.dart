/// Default ceiling on what the workers may hold at once, in bytes
const zstdDefaultMemoryBudget = 1024 * 1024 * 1024;

/// Compresses one job to a worker and writes the frame `zstd -T` writes. The
/// result arrives through [onDone], since an isolate cannot be waited on.
/// [workers] does not change those bytes, [jobSize] and [overlapLog] do
class ZstdMultithreadOptions<T> {
  /// Where the result goes when the call has nowhere else to put it. A stream
  /// carries its own end, so `transform` leaves this null
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
    this.onDone,
    this.onError,
    this.workers,
    this.memoryBudget,
    this.jobSize = 0,
    this.overlapLog = 0,
  });
}

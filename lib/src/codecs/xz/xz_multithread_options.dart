/// Default ceiling on the memory the isolates may hold at once, in bytes.
///
/// Only the blocks that are being decoded are counted against it: the archive
/// and the decoded output live in the calling isolate and are not affected by
/// how many workers are running.
const xzDefaultMemoryBudget = 1024 * 1024 * 1024;

/// Turns an [XZDecoder] call into a decode that runs on isolates.
///
/// Passing one of these switches that single call into multithreaded mode. The
/// method returns immediately and the result arrives through [onDone] instead
/// of the return value, because an isolate cannot be waited on synchronously.
///
/// ```dart
/// final completer = Completer<Uint8List>();
/// XZDecoder().decodeBytes(compressed,
///     multithread: XZMultithreadOptions(
///       onDone: completer.complete,
///       onError: (error, _) => completer.completeError(error),
///     ));
/// final data = await completer.future;
/// ```
///
/// The type argument follows the method being called: [Uint8List] for
/// [XZDecoder.decodeBytes] and [bool] for [XZDecoder.decodeStream]. It is
/// inferred from the method, so writing `XZMultithreadOptions(onDone: (result)
/// { ... })` is enough.
class XZMultithreadOptions<T> {
  /// Called exactly once with the result of the decode.
  ///
  /// This is the only place the result appears. It is called even when the
  /// archive turns out not to be worth splitting up, and on platforms without
  /// isolates, so a caller never has to special case either.
  final void Function(T result) onDone;

  /// Called instead of [onDone] if the decode fails outright.
  ///
  /// An archive that is merely truncated or corrupt is not an error: that is
  /// reported through [onDone], the same way the synchronous methods report it
  /// through their return value. This is for failures that would otherwise
  /// have been thrown, such as an isolate that could not be started.
  ///
  /// `XZDecoder.throwOnError` has no effect in multithreaded mode, because by
  /// the time a failure is known the caller's stack is long gone.
  ///
  /// Leaving this null routes such a failure to [onDone] instead, reported the
  /// same way an invalid archive is. Nothing is ever thrown into the void: an
  /// error that had nowhere to go would otherwise go unnoticed entirely.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Maximum number of isolates to decode on.
  ///
  /// Defaults to one less than [Platform.numberOfProcessors], leaving a core
  /// for the calling isolate, and never exceeds the number of blocks in the
  /// archive. A value above [Platform.numberOfProcessors] is clamped down to
  /// it: more workers than cores costs memory and context switches without
  /// decoding any faster. Must be at least 1.
  ///
  /// [memoryBudget] can still lower the number this produces.
  final int? workers;

  /// Ceiling on the memory the isolates may hold at once, in bytes.
  ///
  /// Defaults to [xzDefaultMemoryBudget]. It is what decides how many blocks
  /// can be in flight, and it applies on top of [workers], including when
  /// [workers] was given explicitly, so that it can act as a safety valve. At
  /// least one worker always runs, however small the budget.
  ///
  /// What each worker is charged for depends on the call:
  ///
  /// - an LZMA2 dictionary, sized by the block header, and a small staging
  ///   buffer, always;
  /// - the compressed block, when the archive was handed over as bytes. Given
  ///   a file to read instead, a worker streams its block through a small
  ///   window and is charged for that window;
  /// - one decoded block, when the output can only be appended to, because
  ///   blocks that finish ahead of their turn have to be held back.
  ///
  /// So the same budget buys markedly more workers for
  /// `decodeStream(InputFileStream, ...)` than for [decodeBytes], which is
  /// another reason to prefer it.
  ///
  /// There is no portable way to ask the system how much memory is available —
  /// Dart exposes [Platform.numberOfProcessors] and nothing equivalent for
  /// memory — so a phone and a workstation need different values here and the
  /// package cannot tell them apart on its own.
  final int? memoryBudget;

  /// Buffer a worker reads a block through when it comes from a file. The default
  /// FileBuffer size is a kilobyte, which would turn reading a large block into
  /// hundreds of thousands of reads.
  ///
  /// Workers read different parts of the file at the same time, so the drive sees
  /// their requests interleaved rather than as one sweep. On anything with a seek
  /// penalty that is the expensive part, and the buffer is what decides how often
  /// it is paid: reading a 189 MB block takes 368 reads through a 1 MB buffer and
  /// 28 through an 8 MB one. Eight megabytes per worker is nothing next to the
  /// block it replaces, and it is charged to the memory budget like everything
  /// else. Larger buffers keep helping on a slow disk but stop mattering on a
  /// fast one, where the page cache answers most of the reads anyway.
  final int fileReadBufferSize;

  const XZMultithreadOptions({
    required this.onDone,
    this.onError,
    this.workers,
    this.memoryBudget,
    this.fileReadBufferSize = 8 * 1024 * 1024,
  });
}

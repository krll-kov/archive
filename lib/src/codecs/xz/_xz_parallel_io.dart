import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

// The io file handle is imported directly rather than through
// file_handle.dart. With no platform in mind the analyser resolves that
// conditional export to the web class. The web class has no path
import '../../util/_file_handle_io.dart';
import '../../util/archive_exception.dart';
import '../../util/byte_order.dart';
import '../../util/cancellable_stream.dart';
import '../../util/crc32.dart';
import '../../util/crc64.dart';
import '../../util/input_file_stream.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import 'xz_block_dispatch.dart';
import 'xz_chunked.dart';
import 'xz_index.dart';
import 'xz_multithread_options.dart';
import 'xz_stream_decoder.dart';

/// Whether this platform can decode on isolates.
const bool xzIsolatesSupported = true;

/// A stretch of a file on disk holding an xz archive.
class XZFileRegion {
  final String path;
  final int offset;
  final int length;

  const XZFileRegion(this.path, this.offset, this.length);
}

/// The file region [input] reads from, or null if there is no file behind it.
///
/// We need this so every worker can read its own block straight from disk. The
/// compressed data then never passes through the calling isolate. A stream
/// over a file held in memory has no region and takes the ordinary path
XZFileRegion? xzFileRegionOf(InputStream input) {
  if (input is! InputFileStream) {
    return null;
  }
  final handle = input.fileBuffer.file;
  if (handle is! FileHandle) {
    return null;
  }
  return XZFileRegion(
      handle.path, input.fileOffset + input.position, input.length);
}

/// Reads the block layout of the archive in [region] without loading it.
XZLayout? xzLayoutOfFile(XZFileRegion region, {int? maxUncompressedSize}) {
  final file = File(region.path).openSync();
  try {
    return parseXZLayout(_XZFileSource(file, region.offset, region.length),
        maxUncompressedSize: maxUncompressedSize);
  } catch (_) {
    return null;
  } finally {
    file.closeSync();
  }
}

/// An [XZByteSource] that reads the ranges it is asked for from a file.
///
/// Parsing an index touches the footer, the index and the stream header. Only
/// a few kilobytes are read whatever the size of the archive
class _XZFileSource extends XZByteSource {
  final RandomAccessFile _file;
  final int _offset;

  @override
  final int length;

  _XZFileSource(this._file, this._offset, this.length);

  @override
  Uint8List range(int start, int end) {
    _file.setPositionSync(_offset + start);
    return _file.readSync(end - start);
  }
}

// Bytes a worker accumulates before shipping them back. Output in pieces keeps
// a worker from holding a whole decoded block. For a 192 MB block that is 4 MB
// of live memory instead of 192 MB, plus one memcpy (~18 ms per 200 MB)
const _stagingSize = 4 * 1024 * 1024;

// The largest block header the format allows, (255 + 1) * 4.
const _maxBlockHeaderSize = 1024;

// Blocks sampled when sizing the LZMA2 dictionary. Dictionary size is a
// per-block property. In practice it is uniform. Reading every header of a
// huge archive would cost more than it saves.
const _dictionarySampleLimit = 16;

const _kindStream = 0;
const _kindBlock = 1;

const _msgReady = 0;
const _msgChunk = 1;
const _msgDone = 2;

/// Decodes an xz archive across isolates and reports the bytes through
/// [onChunk].
///
/// The archive comes from [bytes], or from the file at [path]. With a file,
/// [fileOffset] and [fileLength] mark where it sits. The file is the cheaper
/// of the two. Every worker reads only its own block, so the compressed data
/// never passes through the calling isolate.
///
/// [onChunk] gets an absolute offset into the decoded output and the bytes
/// that go there. Chunks arrive out of order, because blocks decode at the
/// same time.
///
/// [onBlockDone] gives the verdict on each block as it finishes, keyed by the
/// same output offset. A block can deliver all of its bytes and still fail.
/// That is what a bad check looks like, so the bytes alone do not tell you
/// whether to trust them.
///
/// [onFailureReason] gets the first reason a block was rejected. It says why
/// the decode gave up. The false return value does not.
///
/// Returns false if the archive is broken or truncated, like the synchronous
/// decoder. Throws only if the work could not run at all, for example when an
/// isolate fails to start
Future<bool> xzDecodeMultithreaded({
  Uint8List? bytes,
  String? path,
  int fileOffset = 0,
  int fileLength = 0,
  required XZLayout? layout,
  required bool verify,
  required int maxPreallocateSize,
  int? workers,
  int? memoryBudget,
  required void Function(int outputOffset, Uint8List chunk) onChunk,
  void Function(int outputOffset, bool ok)? onBlockDone,
  void Function(String reason)? onFailureReason,
  bool orderedOutput = false,
  required int fileReadBufferSize,
}) {
  // Offsets in the layout are relative to the start of the archive. The
  // archive starts at [fileOffset] in a file and at zero in a buffer
  final base = bytes != null ? 0 : fileOffset;
  final blocks = layout?.blocks;

  if (blocks != null && blocks.length > 1) {
    final dictionaryCap = _largestDictionaryCap(blocks, bytes, path, base);
    final count = _pickWorkerCount(
      blocks: blocks,
      requested: workers,
      memoryBudget: memoryBudget,
      dictionaryCap: dictionaryCap,
      holdsCompressedBlock: bytes != null,
      orderedOutput: orderedOutput,
      fileReadBufferSize: fileReadBufferSize,
    );
    if (count > 1) {
      return _runJobs([
        for (final block in blocks)
          _Job(
            kind: _kindBlock,
            bytes: bytes,
            path: path,
            offset: base + block.compressedOffset,
            length: block.compressedLength,
            streamFlags: block.streamFlags,
            outputOffset: block.outputOffset,
            verify: verify,
            maxPreallocateSize: maxPreallocateSize,
            fileReadBufferSize: fileReadBufferSize,
          )
      ], count, onChunk, onBlockDone, onFailureReason);
    }
  }

  // There is nothing worth splitting, or the budget allows only one worker.
  // One isolate still gives the caller what they asked for. Their own isolate
  // stays free.
  //
  // We report no per block verdict here. The single job covers every block, so
  // its verdict does not say where the failure fell. The caller works that out
  // from the bytes that arrived
  return _runJobs([
    _Job(
      kind: _kindStream,
      bytes: bytes,
      path: path,
      offset: base,
      length: bytes?.length ?? fileLength,
      streamFlags: 0,
      outputOffset: 0,
      verify: verify,
      maxPreallocateSize: maxPreallocateSize,
      fileReadBufferSize: fileReadBufferSize,
    )
  ], 1, onChunk, null, onFailureReason);
}

/// The memory an LZMA2 dictionary will take for the largest sampled block.
///
/// This mirrors the cap [XZStreamDecoder.readBlock] sets. The budget then
/// counts what a worker really allocates rather than a guess
int _largestDictionaryCap(
    List<XZBlockLayout> blocks, Uint8List? bytes, String? path, int base) {
  var largest = 0;
  RandomAccessFile? file;
  try {
    if (bytes == null) {
      file = File(path!).openSync();
    }
    final count = blocks.length < _dictionarySampleLimit
        ? blocks.length
        : _dictionarySampleLimit;
    for (var i = 0; i < count; i++) {
      final block = blocks[i];
      var length = block.compressedLength;
      if (length > _maxBlockHeaderSize) {
        length = _maxBlockHeaderSize;
      }
      Uint8List header;
      if (bytes != null) {
        final start = base + block.compressedOffset;
        if (start + length > bytes.length) {
          continue;
        }
        header = Uint8List.sublistView(bytes, start, start + length);
      } else {
        file!.setPositionSync(base + block.compressedOffset);
        header = file.readSync(length);
      }
      final size = xzBlockDictionarySize(header);
      if (size > largest) {
        largest = size;
      }
    }
  } catch (_) {
    // This only sizes the worker count. A header that cannot be read falls
    // back to whatever the other blocks reported.
  } finally {
    file?.closeSync();
  }

  if (largest <= 0 || largest >= 0x40000000) {
    return 0;
  }
  return largest + (largest >> 2) + (2 << 20) + 16;
}

int _pickWorkerCount({
  required List<XZBlockLayout> blocks,
  required int? requested,
  required int? memoryBudget,
  required int dictionaryCap,
  required bool holdsCompressedBlock,
  required bool orderedOutput,
  required int fileReadBufferSize,
}) {
  final cores = Platform.numberOfProcessors;
  // One core stays free for the calling isolate. In Flutter that is the UI
  // isolate
  var count = requested ?? cores - 1;
  if (count > cores) {
    count = cores;
  }
  if (count < 1) {
    count = 1;
  }
  if (count > blocks.length) {
    count = blocks.length;
  }

  // A worker holds its dictionary and its staging buffer, plus the compressed
  // block for an archive in memory. From a file it reads through a small
  // window. The budget caps an explicit worker count too
  var compressed = fileReadBufferSize;
  if (holdsCompressedBlock) {
    compressed = 0;
    for (final block in blocks) {
      if (block.compressedLength > compressed) {
        compressed = block.compressedLength;
      }
    }
  }

  // An append-only output holds back a block that finished ahead of its turn.
  // Every worker beyond the first can leave a whole decoded block waiting in
  // the calling isolate. That block is charged to the worker that caused it
  var reorder = 0;
  if (orderedOutput) {
    for (final block in blocks) {
      if (block.uncompressedLength > reorder) {
        reorder = block.uncompressedLength;
      }
    }
  }

  final perWorker = compressed + dictionaryCap + _stagingSize + reorder;
  if (perWorker > 0) {
    var affordable = (memoryBudget ?? xzDefaultMemoryBudget) ~/ perWorker;
    if (affordable < 1) {
      affordable = 1;
    }
    if (count > affordable) {
      count = affordable;
    }
  }

  return count;
}

/// One unit of work handed to a worker.
class _Job {
  final int kind;

  /// The whole archive, when it is in memory. Only [offset]..[offset]+[length]
  /// is sent to the worker.
  final Uint8List? bytes;

  final String? path;
  final int offset;
  final int length;
  final int streamFlags;
  final int outputOffset;
  final bool verify;
  final int maxPreallocateSize;
  final int fileReadBufferSize;

  const _Job({
    required this.kind,
    required this.bytes,
    required this.path,
    required this.offset,
    required this.length,
    required this.streamFlags,
    required this.outputOffset,
    required this.verify,
    required this.maxPreallocateSize,
    required this.fileReadBufferSize,
  });

  /// Builds the message for this job.
  ///
  /// The copy into external memory happens here rather than up front. Only the
  /// blocks in flight are held. A queued job costs nothing beyond a view onto
  /// the archive already in memory
  List<Object?> toMessage() {
    TransferableTypedData? data;
    final source = bytes;
    if (source != null) {
      data = TransferableTypedData.fromList(
          [Uint8List.sublistView(source, offset, offset + length)]);
    }
    return [
      _kindMarker,
      kind,
      data,
      path,
      offset,
      length,
      streamFlags,
      outputOffset,
      verify,
      fileReadBufferSize,
      maxPreallocateSize,
    ];
  }

  // Slot 0 of a job message is unused. A worker only ever receives jobs and
  // needs no tag. The slot stays so both directions index alike
  static const _kindMarker = 0;
}

Future<bool> _runJobs(
    List<_Job> jobs,
    int workerCount,
    void Function(int outputOffset, Uint8List chunk) onChunk,
    void Function(int outputOffset, bool ok)? onBlockDone,
    void Function(String reason)? onFailureReason) async {
  final receive = ReceivePort();
  final isolates = <Isolate>[];
  final completer = Completer<bool>();
  final pending = Queue<int>()..addAll(Iterable<int>.generate(jobs.length));

  var remaining = jobs.length;
  var ok = true;
  String? failureReason;
  Object? failure;
  StackTrace? failureStack;
  var finished = false;

  void finish() {
    if (finished) {
      return;
    }
    finished = true;
    receive.close();
    // A worker holds no operating system resources between jobs. It opens and
    // closes the archive inside a single job. Killing it outright is safe
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    if (failureReason != null) {
      onFailureReason?.call(failureReason!);
    }
    if (failure != null) {
      completer.completeError(failure!, failureStack ?? StackTrace.current);
    } else {
      completer.complete(ok);
    }
  }

  void fail(Object error, [StackTrace? stack]) {
    failure ??= error;
    failureStack ??= stack;
    ok = false;
    finish();
  }

  receive.listen((message) {
    if (finished) {
      return;
    }
    try {
      // A dead isolate reports through the same port. Its message is a list
      // with no message tag in the first entry. Without this check the run
      // never completes
      if (message is! List || message.isEmpty || message[0] is! int) {
        fail(StateError('XZ decode isolate failed: $message'));
        return;
      }

      switch (message[0] as int) {
        case _msgChunk:
          onChunk(message[1] as int, message[2] as Uint8List);
          break;
        case _msgReady:
        case _msgDone:
          if (message[0] == _msgDone) {
            final blockOk = message[2] as bool;
            if (!blockOk) {
              ok = false;
            }
            onBlockDone?.call(message[4] as int, blockOk);
            if (!blockOk) {
              // The first rejected block is the one worth reporting. A later
              // one can be failing only because this one did
              final reason = message[5];
              if (reason != null) {
                failureReason ??= reason as String;
              }
            }
            final error = message[3];
            if (error != null) {
              failure ??= StateError('XZ decode failed: $error');
            }
            // The output ends at the first failed block. Every pending block
            // comes after it. Dropping them leaves only the blocks already
            // running
            if (!blockOk || error != null) {
              remaining -= pending.length;
              pending.clear();
            }
            remaining--;
            if (remaining == 0) {
              finish();
              return;
            }
          }
          if (pending.isNotEmpty) {
            final index = pending.removeFirst();
            (message[1] as SendPort).send(jobs[index].toMessage());
          }
          break;
      }
    } catch (error, stack) {
      fail(error, stack);
    }
  });

  try {
    for (var i = 0; i < workerCount; i++) {
      // A fast worker can get through every job before the rest of the pool
      // starts. The run can already be over at this point
      if (finished) {
        break;
      }
      isolates.add(await Isolate.spawn(_xzWorker, receive.sendPort,
          onError: receive.sendPort, errorsAreFatal: true));
    }
    if (finished) {
      // finish() only killed the isolates that existed when it ran.
      for (final isolate in isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
    }
  } catch (error, stack) {
    fail(error, stack);
  }

  return completer.future;
}

/// The largest piece the stream decoder hands on, as the converter does
const _streamPieceSize = 1 << 16;

/// Worker offsets carry the block's place in the stream above these bits
const _idShift = 40;

/// Decodes the blocks of an xz stream on isolates as the bytes arrive, and
/// hands them back in order.
///
/// [XzChunkedDecoder] does the parse. It sends out every block whose header
/// declares both lengths. It decodes any other block itself, once the blocks
/// in front of it are out. We size the pool from the first block we send out
/// and add a worker for each block that waits for one. A block decoded on a
/// worker comes back whole and checked. A block decoded here streams out the
/// way the single threaded converter writes it
Stream<Uint8List> xzDecodeStreamMultithreaded(Stream<List<int>> input,
        {required bool verify, int? workers, int? memoryBudget}) =>
    cancellableStream<List<int>, Uint8List>(
        input,
        (input, signal) => _xzDecodeStream(input, signal,
            verify: verify, workers: workers, memoryBudget: memoryBudget));

Stream<Uint8List> _xzDecodeStream(
    StreamIterator<List<int>> input, CancelSignal signal,
    {required bool verify, int? workers, int? memoryBudget}) async* {
  final budget = memoryBudget ?? xzDefaultMemoryBudget;
  final ready = ListQueue<Uint8List>();
  final dispatch = _StreamDispatch(budget);
  final parser =
      XzChunkedDecoder(_QueueSink(ready), verify: verify, dispatch: dispatch);
  final receive = ReceivePort();
  final isolates = <Isolate>[];
  final idleWorkers = <SendPort>[];
  var pool = 0;

  /// Spawned and not yet reported ready
  var starting = 0;
  Completer<void>? waiting;
  Object? failure;
  StackTrace? failureStack;
  Object? parseFailure;
  StackTrace? parseStack;

  void wake() {
    final waiter = waiting;
    if (waiter != null && !waiter.isCompleted) {
      waiting = null;
      waiter.complete();
    }
  }

  signal.onCancel = wake;

  // A block comes out whole and only once it passed its check, so what a
  // failure leaves is every block before it
  void release() {
    while (dispatch.records.isNotEmpty) {
      final head = dispatch.records.first;
      if (!head.done) {
        return;
      }
      if (!head.ok) {
        failure ??= ArchiveException('xz: ${head.reason ?? 'a block failed'}');
        return;
      }
      for (final piece in head.pieces) {
        for (var at = 0; at < piece.length; at += _streamPieceSize) {
          final end = at + _streamPieceSize < piece.length
              ? at + _streamPieceSize
              : piece.length;
          ready.add(Uint8List.sublistView(piece, at, end));
        }
      }
      head.pieces.clear();
      dispatch.records.removeFirst();
      dispatch.byId.remove(head.id);
    }
  }

  void pump() {
    while (idleWorkers.isNotEmpty && dispatch.unsent.isNotEmpty) {
      final record = dispatch.unsent.removeFirst();
      final bytes = record.bytes!;
      record.bytes = null;
      idleWorkers.removeLast().send(_Job(
            kind: _kindBlock,
            bytes: bytes,
            path: null,
            offset: 0,
            length: bytes.length,
            streamFlags: record.streamFlags,
            outputOffset: record.id << _idShift,
            verify: verify,
            maxPreallocateSize: budget,
            fileReadBufferSize: 0,
          ).toMessage());
    }
  }

  receive.listen((message) {
    try {
      if (message is! List || message.isEmpty || message[0] is! int) {
        failure ??= StateError('XZ decode isolate failed: $message');
      } else if (message[0] == _msgChunk) {
        final id = (message[1] as int) >> _idShift;
        dispatch.byId[id]?.pieces.add(message[2] as Uint8List);
        release();
      } else {
        if (message[0] == _msgReady) {
          starting--;
        } else if (message[0] == _msgDone) {
          final id = (message[4] as int) >> _idShift;
          final record = dispatch.byId[id];
          if (record != null) {
            record
              ..done = true
              ..ok = message[2] as bool && message[3] == null
              ..reason = message[5] as String? ?? message[3] as String?;
          }
        }
        idleWorkers.add(message[1] as SendPort);
        pump();
        release();
      }
    } catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
    }
    wake();
  });

  // One worker for each block waiting for one, up to the pool, so a single
  // block starts one isolate and comes out without waiting for the close. A
  // spawn that fails is a failure of the decode, which every wait here ends on
  Future<void> grow() async {
    if (dispatch.unsent.isEmpty) {
      return;
    }
    if (pool == 0) {
      final cores = Platform.numberOfProcessors;
      var count = workers ?? cores - 1;
      if (count > cores) {
        count = cores;
      }
      if (count < 1) {
        count = 1;
      }
      // The charge _pickWorkerCount makes, taken from the first block: its
      // compressed bytes, its dictionary, the staging and one held decoded block
      final affordable = budget ~/ dispatch.perWorker;
      if (count > affordable) {
        count = affordable < 1 ? 1 : affordable;
      }
      pool = count;
    }
    while (failure == null &&
        dispatch.unsent.length > idleWorkers.length + starting &&
        isolates.length < pool) {
      starting++;
      try {
        isolates.add(await Isolate.spawn(_xzWorker, receive.sendPort,
            onError: receive.sendPort, errorsAreFatal: true));
      } catch (error, stack) {
        starting--;
        failure ??= error;
        failureStack ??= stack;
      }
    }
  }

  // The pool is fed after every step, a failed one too: one step can hand
  // over the last blocks and then fail on the index behind them
  bool parse(void Function() run) {
    try {
      run();
      return true;
    } catch (error, stack) {
      parseFailure ??= error;
      parseStack ??= stack;
      return false;
    } finally {
      pump();
    }
  }

  // Everything handed over, written out
  Stream<Uint8List> drain() async* {
    while (
        failure == null && !signal.cancelled && dispatch.records.isNotEmpty) {
      await grow();
      pump();
      while (ready.isNotEmpty) {
        yield ready.removeFirst();
      }
      if (failure == null && dispatch.records.isNotEmpty) {
        waiting = Completer<void>();
        await waiting!.future;
      }
    }
    while (ready.isNotEmpty) {
      yield ready.removeFirst();
    }
  }

  // No more blocks held than the pool decodes, and a block the parse has to
  // read itself only once those before it are out
  Stream<Uint8List> settle() async* {
    while (failure == null && parseFailure == null && !signal.cancelled) {
      await grow();
      pump();
      if (failure != null) {
        return;
      }
      if (parser.waitingForIdle) {
        yield* drain();
        if (failure != null || !parse(parser.resume)) {
          return;
        }
        continue;
      }
      while (ready.isNotEmpty) {
        yield ready.removeFirst();
      }
      if (pool == 0 || dispatch.records.length < pool) {
        return;
      }
      waiting = Completer<void>();
      await waiting!.future;
    }
  }

  final ahead = InputAhead<List<int>>(input, wake);
  try {
    try {
      while (true) {
        ahead.ask();
        while (!ahead.arrived && failure == null && !signal.cancelled) {
          while (ready.isNotEmpty) {
            yield ready.removeFirst();
          }
          if (ahead.arrived || failure != null || signal.cancelled) {
            break;
          }
          waiting = Completer<void>();
          await waiting!.future;
        }
        if (failure != null || signal.cancelled) {
          break;
        }
        final chunk = ahead.take();
        if (chunk == null) {
          break;
        }
        if (!parse(() => parser.add(chunk))) {
          break;
        }
        yield* settle();
        if (failure != null || parseFailure != null || signal.cancelled) {
          break;
        }
      }
    } catch (error, stack) {
      parseFailure ??= error;
      parseStack ??= stack;
    }
    if (signal.cancelled) {
      return;
    }
    if (failure == null && parseFailure == null) {
      yield* drain();
      while (failure == null && parser.waitingForIdle && parse(parser.resume)) {
        yield* drain();
      }
      if (failure == null && parseFailure == null) {
        parse(parser.close);
      }
    }
    // What was handed over before a failure in the parse is still written out
    yield* drain();
    final thrown = failure ?? parseFailure;
    if (thrown != null) {
      Error.throwWithStackTrace(
          thrown,
          (identical(thrown, failure) ? failureStack : parseStack) ??
              StackTrace.current);
    }
  } finally {
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    receive.close();
    // Leaving early, on a failure or a cancel, still lets go of the input
    await input.cancel();
  }
}

class _StreamBlock {
  final int id;
  final int streamFlags;

  /// Dropped once the block is on its way to a worker
  Uint8List? bytes;
  final pieces = <Uint8List>[];
  var done = false;
  var ok = false;
  String? reason;

  _StreamBlock(this.id, this.bytes, this.streamFlags);
}

class _StreamDispatch implements XzBlockDispatch {
  @override
  final int maxBlockBytes;

  /// Handed over and not yet written out, in stream order
  final records = ListQueue<_StreamBlock>();
  final unsent = ListQueue<_StreamBlock>();
  final byId = <int, _StreamBlock>{};
  var _next = 0;
  var perWorker = 1;

  _StreamDispatch(this.maxBlockBytes);

  @override
  bool get idle => records.isEmpty;

  @override
  void block(Uint8List bytes, int streamFlags, int uncompressedLength,
      int dictionarySize) {
    final record = _StreamBlock(_next++, bytes, streamFlags);
    records.add(record);
    unsent.add(record);
    byId[record.id] = record;
    if (record.id == 0) {
      final dictionary = dictionarySize > 0 && dictionarySize < 0x40000000
          ? dictionarySize + (dictionarySize >> 2) + (2 << 20) + 16
          : 0;
      perWorker = bytes.length + dictionary + _stagingSize + uncompressedLength;
    }
  }
}

/// Where the parse writes a block it decodes itself
class _QueueSink implements Sink<List<int>> {
  final ListQueue<Uint8List> _ready;

  _QueueSink(this._ready);

  @override
  void add(List<int> data) =>
      _ready.add(data is Uint8List ? data : Uint8List.fromList(data));

  @override
  void close() {}
}

/// Reads the check field, the tail of a block.
///
/// The block padding sits in front of it. Every check size is a multiple of
/// four. That leaves the check as the last [checkSize] bytes
Uint8List _readCheckField(
    InputStream input, Uint8List? data, int length, int checkSize) {
  if (checkSize == 0 || length < checkSize) {
    return Uint8List(0);
  }
  if (data != null) {
    return Uint8List.sublistView(data, length - checkSize, length);
  }
  input.setPosition(length - checkSize);
  return input.readBytes(checkSize).toUint8List();
}

/// Entry point of a decode worker.
///
/// A worker outlives one block. The pool hands it job after job, which keeps
/// the hot LZMA loop warm. That matters under the JIT. A fresh isolate has to
/// optimise the loop all over again
void _xzWorker(SendPort toMain) {
  final receive = ReceivePort();

  receive.listen((message) {
    if (message == null) {
      receive.close();
      return;
    }

    final job = message as List;
    final kind = job[1] as int;
    final transferable = job[2] as TransferableTypedData?;
    final path = job[3] as String?;
    final offset = job[4] as int;
    final length = job[5] as int;
    final streamFlags = job[6] as int;
    final outputOffset = job[7] as int;
    final verify = job[8] as bool;
    final fileReadBufferSize = job[9] as int;
    final maxPreallocateSize = job[10] as int;

    // A failure to get hold of the compressed data says nothing about the
    // archive. It is a failure of the decode itself and reports as an error.
    // Anything that goes wrong afterwards is the archive's fault
    Uint8List? data;
    InputFileStream? file;
    InputStream input;
    try {
      if (transferable != null) {
        // The bytes already sit in external memory. Materialising hands over
        // ownership of them and costs nothing
        data = Uint8List.view(transferable.materialize());
        input = InputMemoryStream(data);
      } else {
        // Read the block as it is decoded rather than up front. LZMA2 reads a
        // block strictly in order. Holding all of it gains nothing. A
        // compressed block is the largest thing a worker would keep
        file = InputFileStream(path!, bufferSize: fileReadBufferSize);
        input = InputFileStream.fromFileStream(file,
            position: offset, length: length);
      }
    } catch (error) {
      toMain.send([
        _msgDone,
        receive.sendPort,
        false,
        error.toString(),
        outputOffset,
        null
      ]);
      return;
    }

    final result = _decodeJob(
        kind: kind,
        input: input,
        data: data,
        length: length,
        streamFlags: streamFlags,
        verify: verify,
        maxPreallocateSize: maxPreallocateSize,
        outputOffset: outputOffset,
        onPiece: (at, piece) => toMain.send([_msgChunk, at, piece]));
    file?.closeSync();
    toMain.send([
      _msgDone,
      receive.sendPort,
      result.ok,
      null,
      outputOffset,
      result.reason
    ]);
  });

  toMain.send([_msgReady, receive.sendPort, null, null, -1, null]);
}

/// Decodes one job into pieces handed to [onPiece] and checks a block against
/// the field it ends with. A corrupt archive is a verdict here, not a throw
({bool ok, String? reason}) _decodeJob({
  required int kind,
  required InputStream input,
  required Uint8List? data,
  required int length,
  required int streamFlags,
  required bool verify,
  required int maxPreallocateSize,
  required int outputOffset,
  required void Function(int offset, Uint8List piece) onPiece,
}) {
  var ok = false;
  String? reason;
  final checkType = streamFlags & 0xf;
  // The check is folded in as the pieces go past, so verifying never holds
  // the whole block
  final verifyHere = verify && kind == _kindBlock;
  final sink = _BlockSink(onPiece, outputOffset, verifyHere ? checkType : 0);
  try {
    if (kind == _kindBlock) {
      final result = decodeXZBlock(input, streamFlags, sink,
          maxPreallocateSize: maxPreallocateSize);
      ok = result.ok;
      reason = result.reason;
    } else {
      final decoder = XZStreamDecoder(
          verify: verify, maxPreallocateSize: maxPreallocateSize);
      ok = decoder.decode(input, sink);
      reason = decoder.failureReason;
    }
  } catch (error) {
    ok = false;
    reason = '$error';
  } finally {
    // What decoded before a failure is kept, as the single threaded path does
    try {
      sink.flush();
    } catch (error) {
      ok = false;
      reason ??= '$error';
    }
  }
  if (ok && verifyHere) {
    try {
      ok = sink.checkMatches(
          _readCheckField(input, data, length, xzCheckSize(checkType)));
      if (!ok) {
        reason = 'Block check failed';
      }
    } catch (error) {
      ok = false;
      reason = '$error';
    }
  }
  return (ok: ok, reason: reason);
}

/// An [OutputStream] that hands what it is given to [_onPiece] in pieces.
///
/// We buffer writes into a fixed staging area and hand it over whenever it
/// fills, so a decode never holds more than [_stagingSize] of its output. We
/// reuse the staging buffer, so a receiver has to copy a piece to keep it.
/// [SendPort.send] copies on its own
class _BlockSink extends OutputStream {
  final void Function(int offset, Uint8List piece) _onPiece;
  final int _outputOffset;

  /// Check type to accumulate, or 0 to accumulate nothing.
  final int _checkType;

  final Uint8List _staging = Uint8List(_stagingSize);
  int _staged = 0;
  int _emitted = 0;
  int _crc = 0;

  _BlockSink(this._onPiece, this._outputOffset, this._checkType)
      : super(byteOrder: ByteOrder.littleEndian);

  @override
  int get length => _emitted + _staged;

  @override
  void writeByte(int value) {
    if (_staged == _stagingSize) {
      flush();
    }
    _staging[_staged++] = value;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    length ??= bytes.length;
    if (length <= 0) {
      return;
    }

    // A write larger than the staging area goes straight out. A BCJ filtered
    // block takes this path. The block decoder hands it over in one call and
    // staging it again would gain nothing
    if (length >= _stagingSize) {
      flush();
      _emit(bytes is Uint8List
          ? Uint8List.sublistView(bytes, 0, length)
          : Uint8List.fromList(bytes.sublist(0, length)));
      return;
    }

    if (_staged + length > _stagingSize) {
      flush();
    }
    _staging.setRange(_staged, _staged + length, bytes);
    _staged += length;
  }

  @override
  void writeStream(InputStream stream) => writeBytes(stream.toUint8List());

  @override
  void flush() {
    if (_staged == 0) {
      return;
    }
    _emit(Uint8List.sublistView(_staging, 0, _staged));
    _staged = 0;
  }

  void _emit(Uint8List view) {
    if (view.isEmpty) {
      return;
    }
    if (_checkType == 0x1) {
      _crc = getCrc32(view, _crc);
    } else if (_checkType == 0x4 && isCrc64Supported()) {
      _crc = getCrc64(view, _crc);
    }
    _onPiece(_outputOffset + _emitted, view);
    _emitted += view.length;
  }

  /// Compares the accumulated checksum with the [checkField] stored in the
  /// block. Check types that cannot be verified pass.
  bool checkMatches(Uint8List checkField) {
    if (_checkType != 0x1 && _checkType != 0x4) {
      return true;
    }
    if (_checkType == 0x4 && !isCrc64Supported()) {
      return true;
    }
    if (checkField.isEmpty) {
      return false;
    }

    var expected = 0;
    for (var i = checkField.length - 1; i >= 0; i--) {
      expected = (expected << 8) | checkField[i];
    }
    return expected == _crc;
  }

  @override
  void clear() =>
      throw UnsupportedError('An xz worker sink cannot be rewritten');

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('An xz worker sink cannot be read back');

  @override
  void writeBackReference(int distance, int count) =>
      throw UnsupportedError('An xz worker sink cannot be read back');
}

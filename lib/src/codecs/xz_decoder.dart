import 'dart:async';
import 'dart:typed_data';

import '../util/archive_exception.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'xz/xz_index.dart';
import 'xz/xz_multithread_options.dart';
import 'xz/xz_parallel.dart';
import 'xz/xz_stream_decoder.dart';

// [XZMultithreadOptions] appears in the signature of both decode methods, so
// it travels with them rather than having to be imported separately.
export 'xz/xz_multithread_options.dart';

// The XZ specification can be found at
// https://tukaani.org/xz/xz-file-format.txt.

/// Decompress data with the xz format decoder.
///
/// Both methods decode on the calling isolate by default. Passing an
/// [XZMultithreadOptions] instead spreads the work over isolates, one xz block
/// at a time; see the notes on each method for what that costs in memory.
class XZDecoder {
  /// Decompress the given [bytes] with the xz format.
  ///
  /// A malformed or truncated archive yields whatever was decoded before the
  /// failure rather than an error. Use [decodeStream] and check its result
  /// when that matters.
  ///
  /// Pass [multithread] to decode on isolates. The call then returns
  /// immediately, **the return value is an empty list**, and the result
  /// arrives through [XZMultithreadOptions.onDone]:
  ///
  /// ```dart
  /// final completer = Completer<Uint8List>();
  /// XZDecoder().decodeBytes(compressed,
  ///     multithread: XZMultithreadOptions(onDone: completer.complete));
  /// final data = await completer.future;
  /// ```
  ///
  /// Multithreading only pays off for an archive written in several blocks,
  /// which is what `xz --block-size=...` produces; a single block archive
  /// cannot be split and is simply decoded on one isolate. Measured on a 1.1
  /// GB archive of six 192 MB blocks:
  ///
  /// | call | peak memory | time |
  /// |---|---|---|
  /// | no `multithread` | 3.0 GB | 16.7 s |
  /// | with `multithread` | 3.9 GB | 8.0 s |
  /// | with `multithread`, six workers | 4.4 GB | 5.1 s |
  ///
  /// This is the more expensive of the two methods, and by some distance: the
  /// archive and the decoded output both stay in memory, and every worker holds
  /// a copy of the block it is decoding, because bytes handed over cannot be
  /// read from anywhere else. [decodeStream] over an `InputFileStream` and an
  /// `OutputFileStream` decodes the same archive in the same time using well
  /// under a third of the memory, and is worth preferring whenever the data is
  /// on disk anyway.
  ///
  /// The default [XZMultithreadOptions.memoryBudget] allowed three workers
  /// here; raising it buys the six worker row.
  Uint8List decodeBytes(List<int> data,
      {bool verify = false, XZMultithreadOptions<Uint8List>? multithread}) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);

    if (multithread == null) {
      return _decodeBytes(bytes, verify);
    }
    _checkWorkers(multithread.workers);

    if (!xzIsolatesSupported) {
      // No isolates here, so this blocks the caller, but the result is still
      // delivered the way the caller asked for it.
      _report(multithread, () => _decodeBytes(bytes, verify), Uint8List(0));
      return Uint8List(0);
    }

    _reportAsync(multithread,
        () => _decodeBytesOnIsolates(bytes, verify, multithread), Uint8List(0));
    return Uint8List(0);
  }

  /// Decompress the given [input] with the xz format, writing the
  /// decompressed data to the [output] stream.
  ///
  /// Returns false if the archive is malformed or truncated, in which case
  /// [output] holds however much was decoded before the failure and should be
  /// discarded. Set [throwOnError] to get an [ArchiveException] instead.
  ///
  /// Pass [multithread] to decode on isolates. The call then returns
  /// immediately, **the return value is always false**, and the outcome
  /// arrives through [XZMultithreadOptions.onDone]. [throwOnError] has no
  /// effect in that mode, because by the time the outcome is known the
  /// caller's stack is gone; failures are reported through
  /// [XZMultithreadOptions.onError] instead.
  ///
  /// This is the cheaper of the two methods, and the combination of streams
  /// decides how cheap. When [input] is an `InputFileStream`, each worker
  /// reads its own block from the file as it decodes it, so neither the
  /// archive nor any block of it is ever held whole. Measured on a 1.1 GB
  /// archive of six 192 MB blocks, at the default memory budget:
  ///
  /// | input, output | peak memory | time |
  /// |---|---|---|
  /// | single threaded, for reference | 3.0 GB | 16.7 s |
  /// | `InputMemoryStream`, `OutputFileStream` | 2.6 GB | 10.1 s |
  /// | `InputFileStream`, `OutputFileStream` | 0.9 GB | 8.1 s |
  /// | `InputFileStream`, `OutputFileStream`, six workers | 1.3 GB | 5.1 s |
  ///
  /// The third row uses under a third of the memory that decoding the same
  /// archive on the calling isolate does, while being twice as fast. Raising
  /// [XZMultithreadOptions.memoryBudget] to reach the fourth trades some of
  /// that back for another third off the time.
  ///
  /// An [input] that is neither of those has no random access to hand the
  /// workers, so it is decoded on the calling isolate and reported through
  /// [XZMultithreadOptions.onDone] like everything else.
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false,
      bool throwOnError = false,
      XZMultithreadOptions<bool>? multithread}) {
    if (multithread == null) {
      return _decodeStream(input, output, verify, throwOnError);
    }
    _checkWorkers(multithread.workers);

    if (!xzIsolatesSupported) {
      _report(multithread, () => _decodeStream(input, output, verify, false),
          false);
      return false;
    }

    _reportAsync(
        multithread,
        () => _decodeStreamOnIsolates(input, output, verify, multithread),
        false);
    return false;
  }

  /// Gets uncompressed size of XZ archive, if it's valid. When archive
  /// is not valid, return value is null. May be used with [decodeStream]
  /// for memory efficiency.
  ///
  /// ```dart
  /// final Uint8List from = Uint8List(0); // your archive
  /// final OutputMemoryStream output = OutputMemoryStream(size: XZDecoder().uncompressedSize(from));
  /// final bool ok = XZDecoder().decodeStream(InputMemoryStream(from), output);
  /// if (!ok) throw 'XZ decode failed';
  /// return output.getBytes();
  /// ```
  int? uncompressedSize(List<int> data) =>
      _uSize(data is Uint8List ? data : Uint8List.fromList(data));

  // The single threaded decode, which is also what the multithreaded path
  // falls back to when there are no isolates.
  Uint8List _decodeBytes(Uint8List bytes, bool verify) {
    // The stream indexes give the output size up front, which avoids growing
    // the output buffer while decoding. A zero size is left to the default
    // because the buffer cannot grow out of an empty allocation.
    final int? size = _uSize(bytes);
    final OutputMemoryStream output =
        OutputMemoryStream(size: size != null && size > 0 ? size : null);

    _decodeStream(InputMemoryStream(bytes), output, verify, false);
    return output.getBytes();
  }

  bool _decodeStream(
      InputStream input, OutputStream output, bool verify, bool throwOnError) {
    try {
      final decoder = XZStreamDecoder(verify: verify);
      if (decoder.decode(input, output)) return true;
    } catch (error) {
      if (throwOnError) throw ArchiveException('Invalid XZ archive: $error');
    }
    if (throwOnError) throw ArchiveException('Invalid XZ archive');
    return false;
  }

  Future<Uint8List> _decodeBytesOnIsolates(Uint8List bytes, bool verify,
      XZMultithreadOptions<Uint8List> options) async {
    final layout = parseXZLayout(XZMemorySource(bytes),
        maxUncompressedSize: _maxPreallocateSize);

    if (layout == null) {
      // Without an index the archive cannot be split, so it is decoded whole
      // on one isolate and the chunks arrive in order.
      final output = OutputMemoryStream();
      // The result is not inspected: whether or not it succeeded, this yields
      // what was decoded, which is what the single threaded path does too.
      await xzDecodeMultithreaded(
        bytes: bytes,
        layout: null,
        verify: verify,
        workers: options.workers,
        memoryBudget: options.memoryBudget,
        onChunk: (offset, chunk) => output.writeBytes(chunk),
        fileReadBufferSize: options.fileReadBufferSize,
      );
      return output.getBytes();
    }

    final blocks = layout.blocks;
    final output = Uint8List(layout.uncompressedSize);
    // How much of each block arrived, and whether it can be trusted, so that a
    // failure can still report the part of the output that is good. Blocks are
    // taken as trustworthy unless a verdict says otherwise, because verdicts
    // only arrive when the archive was split up block by block.
    final received = List<int>.filled(blocks.length, 0);
    final accepted = List<bool>.filled(blocks.length, true);

    final ok = await xzDecodeMultithreaded(
      bytes: bytes,
      layout: layout,
      verify: verify,
      workers: options.workers,
      memoryBudget: options.memoryBudget,
      onChunk: (offset, chunk) {
        output.setRange(offset, offset + chunk.length, chunk);
        if (blocks.isNotEmpty) {
          received[_blockIndexAt(blocks, offset)] += chunk.length;
        }
      },
      onBlockDone: (offset, blockOk) {
        if (blocks.isNotEmpty) {
          accepted[_blockIndexAt(blocks, offset)] = blockOk;
        }
      },
      fileReadBufferSize: options.fileReadBufferSize,
    );

    if (ok) {
      return output;
    }

    // Blocks are decoded out of order, so the output stops at the first one
    // that is not whole and trustworthy, the way the single threaded decode
    // stops where it gave up. A block that failed part way through still
    // contributes what it managed, since chunks within one block arrive in
    // order; a block that produced everything and still failed did so because
    // its check did not match, so none of it can be trusted.
    var end = 0;
    for (var i = 0; i < blocks.length; i++) {
      final whole = received[i] == blocks[i].uncompressedLength;
      if (!whole) {
        end = blocks[i].outputOffset + received[i];
        break;
      }
      if (!accepted[i]) {
        break;
      }
      end = blocks[i].outputOffset + blocks[i].uncompressedLength;
    }
    return Uint8List.sublistView(output, 0, end);
  }

  Future<bool> _decodeStreamOnIsolates(InputStream input, OutputStream output,
      bool verify, XZMultithreadOptions<bool> options) async {
    final region = xzFileRegionOf(input);

    XZLayout? layout;
    Uint8List? bytes;
    if (region != null) {
      layout = xzLayoutOfFile(region);
    } else if (input is InputMemoryStream) {
      bytes = input.toUint8List();
      layout = parseXZLayout(XZMemorySource(bytes));
    } else {
      // Any other stream has no random access to give the workers, so it is
      // decoded on the calling isolate.
      return _decodeStream(input, output, verify, false);
    }

    // An OutputStream can only be appended to, so blocks that finish early are
    // held back until the blocks in front of them have been written.
    final writer = _OrderedWriter(output);

    return xzDecodeMultithreaded(
      bytes: bytes,
      path: region?.path,
      fileOffset: region?.offset ?? 0,
      fileLength: region?.length ?? 0,
      layout: layout,
      verify: verify,
      workers: options.workers,
      memoryBudget: options.memoryBudget,
      onChunk: writer.add,
      orderedOutput: true,
      fileReadBufferSize: options.fileReadBufferSize,
    );
  }

  // Runs [work] now and hands the result to [options.onDone], routing a
  // failure to [options.onError].
  static void _report<T>(
      XZMultithreadOptions<T> options, T Function() work, T onFailure) {
    T result;
    try {
      result = work();
    } catch (error, stack) {
      final onError = options.onError;
      if (onError != null) {
        onError(error, stack);
      } else {
        options.onDone(onFailure);
      }
      return;
    }
    options.onDone(result);
  }

  // As [_report], for work that finishes later.
  static void _reportAsync<T>(
      XZMultithreadOptions<T> options, Future<T> Function() work, T onFailure) {
    unawaited(
        work().then(options.onDone, onError: (Object error, StackTrace stack) {
      final onError = options.onError;
      if (onError != null) {
        onError(error, stack);
      } else {
        // Nothing would observe an unhandled asynchronous error, so the
        // failure is reported the same way an invalid archive is.
        options.onDone(onFailure);
      }
    }));
  }

  static void _checkWorkers(int? workers) {
    if (workers != null && workers < 1) {
      throw ArgumentError.value(workers, 'workers', 'Must be at least 1');
    }
  }
}

/// Writes chunks to an append-only [OutputStream] in offset order.
class _OrderedWriter {
  final OutputStream _output;
  final _waiting = <int, Uint8List>{};
  int _written = 0;

  _OrderedWriter(this._output);

  void add(int offset, Uint8List chunk) {
    if (offset != _written) {
      _waiting[offset] = chunk;
      return;
    }

    _output.writeBytes(chunk);
    _written += chunk.length;

    // Writing this chunk may have joined up chunks that arrived before it.
    while (true) {
      final next = _waiting.remove(_written);
      if (next == null) {
        return;
      }
      _output.writeBytes(next);
      _written += next.length;
    }
  }
}

/// The index of the block that [offset] falls in.
int _blockIndexAt(List<XZBlockLayout> blocks, int offset) {
  var low = 0;
  var high = blocks.length - 1;
  while (low < high) {
    final middle = (low + high + 1) >> 1;
    if (blocks[middle].outputOffset <= offset) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return low;
}

// Largest size that is worth pre-allocating from a stream index. A valid index
// can describe an output that is much larger than the available memory, so
// anything above this is treated as unknown.
const _maxPreallocateSize = 1 << 31;

// Returns the total uncompressed size of every stream in [d], taken from the
// stream indexes, or null if it cannot be determined.
int? _uSize(Uint8List d) =>
    parseXZLayout(XZMemorySource(d), maxUncompressedSize: _maxPreallocateSize)
        ?.uncompressedSize;

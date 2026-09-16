import 'dart:async';
import 'dart:typed_data';

import '../util/archive_exception.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'xz/_xz_no_result.dart';
import 'xz/xz_index.dart';
import 'xz/xz_multithread_options.dart';
import 'xz/xz_parallel.dart';
import 'xz/xz_stream_decoder.dart';

// Both decode methods take an [XZMultithreadOptions]. It comes with them and
// needs no import of its own
export 'xz/xz_multithread_options.dart';

/// Decodes on the calling isolate. Pass an [XZMultithreadOptions] to spread
/// the work over isolates, one xz block at a time
class XZDecoder {
  /// The biggest output allocated up front from the size in the stream index.
  /// The index comes from the archive and can name a size that is not there,
  /// or hundreds of gigabytes for repetitive data at 6000:1. Over this limit
  /// the buffer grows as the bytes arrive and [uncompressedSize] returns null.
  /// Decoding itself is not capped. The default is much lower on the web,
  /// where a failed allocation kills the page
  final int maxPreallocateSize;

  XZDecoder({int? maxPreallocateSize})
      : maxPreallocateSize = maxPreallocateSize ?? xzDefaultMaxPreallocateSize {
    if (this.maxPreallocateSize < 0) {
      throw ArgumentError.value(
          maxPreallocateSize, 'maxPreallocateSize', 'Must not be negative');
    }
  }

  /// Decodes [bytes].
  ///
  /// A broken or truncated archive gives back whatever decoded before the
  /// failure, with nothing to mark it partial. [throwOnError] turns that into
  /// an [ArchiveException]. [verify] checks the checksum stored with each
  /// block. A bad argument throws [ArgumentError] either way.
  ///
  /// With [multithread] the call returns an empty list at once. The result
  /// goes to [XZMultithreadOptions.onDone], a failure to its `onError`.
  /// Splitting helps only on several blocks, what `xz --block-size=...`
  /// writes. Measured on 1.1 GB in six 192 MB blocks:
  ///
  /// | call | peak memory | time |
  /// |---|---|---|
  /// | no `multithread` | 3.0 GB | 16.7 s |
  /// | with `multithread` | 3.9 GB | 8.0 s |
  /// | with `multithread`, six workers | 4.4 GB | 5.1 s |
  ///
  /// The budget allowed three workers here. This method keeps the archive and
  /// the output in memory and every worker holds a copy of its block.
  /// [decodeStream] over files does the same archive in the same time on under
  /// a third of the memory
  Uint8List decodeBytes(List<int> data,
      {bool verify = false,
      bool throwOnError = false,
      XZMultithreadOptions<Uint8List>? multithread}) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);

    if (multithread == null) {
      return _decodeBytes(bytes, verify, throwOnError);
    }
    _checkOptions(multithread, throwOnError);

    if (!xzIsolatesSupported) {
      // No isolates here. The call blocks until the decode is done. The result
      // still arrives through the options
      _report(multithread, () => _decodeBytes(bytes, verify, throwOnError),
          Uint8List(0));
      return Uint8List(0);
    }

    _reportAsync(
        multithread,
        () => _decodeBytesOnIsolates(bytes, verify, throwOnError, multithread),
        Uint8List(0));
    return Uint8List(0);
  }

  /// Decodes [input] into [output].
  ///
  /// Returns false on a broken or truncated archive. [output] then holds
  /// whatever decoded before the failure, and written bytes cannot be taken
  /// back. [throwOnError] turns that into an [ArchiveException]. [verify]
  /// checks the checksum stored with each block. A bad argument throws
  /// [ArgumentError] either way.
  ///
  /// With [multithread] the call returns false at once. The outcome goes to
  /// [XZMultithreadOptions.onDone], a failure to its `onError`.
  ///
  /// This method is the cheap one. With an `InputFileStream` every worker
  /// reads its own block from the file as it decodes. Neither the archive nor
  /// a block is ever held whole. Measured on 1.1 GB in six 192 MB blocks, at
  /// the default memory budget:
  ///
  /// | input, output | peak memory | time |
  /// |---|---|---|
  /// | `InputFileStream`, `OutputFileStream`, no `multithread` | 0.4 GB | 17.6 s |
  /// | `InputFileStream`, `OutputFileStream` | 0.9 GB | 8.1 s |
  /// | `InputFileStream`, `OutputFileStream`, six workers | 1.3 GB | 5.1 s |
  /// | `InputMemoryStream`, `OutputFileStream` | 2.6 GB | 10.1 s |
  ///
  /// The first row holds only the LZMA dictionary and the two stream buffers.
  /// No split run matches it, since every worker needs its own dictionary.
  /// Every row below buys time with memory, and on a drive that pays for seeks
  /// it may buy nothing. See [XZMultithreadOptions.fileReadBufferSize].
  ///
  /// Any other [input] gives the workers no random access. It decodes on the
  /// calling isolate and reports through [XZMultithreadOptions.onDone]
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false,
      bool throwOnError = false,
      XZMultithreadOptions<bool>? multithread}) {
    if (multithread == null) {
      return _decodeStream(input, output, verify, throwOnError);
    }
    _checkOptions(multithread, throwOnError);

    if (!xzIsolatesSupported) {
      _report(multithread,
          () => _decodeStream(input, output, verify, throwOnError), false);
      return false;
    }

    _reportAsync(
        multithread,
        () => _decodeStreamOnIsolates(
            input, output, verify, throwOnError, multithread),
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
  int? uncompressedSize(List<int> data) => _uSize(
      data is Uint8List ? data : Uint8List.fromList(data), maxPreallocateSize);

  // The single threaded decode. The multithreaded path falls back to this
  // when there are no isolates
  Uint8List _decodeBytes(Uint8List bytes, bool verify, bool throwOnError) {
    // The stream indexes give the output size up front. The buffer then never
    // grows while decoding. A zero size falls back to the default. An empty
    // allocation cannot grow
    final int? size = _uSize(bytes, maxPreallocateSize);
    final OutputMemoryStream output =
        OutputMemoryStream(size: size != null && size > 0 ? size : null);

    _decodeStream(InputMemoryStream(bytes), output, verify, throwOnError);
    return output.getBytes();
  }

  bool _decodeStream(
      InputStream input, OutputStream output, bool verify, bool throwOnError) {
    final decoder =
        XZStreamDecoder(verify: verify, maxPreallocateSize: maxPreallocateSize);
    try {
      if (decoder.decode(input, output)) return true;
    } catch (error) {
      if (throwOnError) throw ArchiveException('Invalid XZ archive: $error');
      return false;
    }
    // The decoder records why it gave up. The exception repeats that reason
    // instead of "something was wrong"
    if (throwOnError) throw _invalid(decoder.failureReason);
    return false;
  }

  // Names the reason when the decoder found one
  static ArchiveException _invalid(String? reason) => ArchiveException(
      reason == null ? 'Invalid XZ archive' : 'Invalid XZ archive: $reason');

  Future<Uint8List> _decodeBytesOnIsolates(Uint8List bytes, bool verify,
      bool throwOnError, XZMultithreadOptions<Uint8List> options) async {
    // No ceiling here. The layout only says where the blocks are. It decides
    // whether the work can be split, and reading it allocates nothing. The
    // ceiling belongs to the buffer choice below
    final layout = parseXZLayout(XZMemorySource(bytes));

    if (layout == null || layout.uncompressedSize > maxPreallocateSize) {
      // No readable index here, or it claims more output than is safe to
      // trust. The buffer grows as the bytes arrive instead. Blocks still
      // decode in parallel and the ordered writer holds one that ran ahead
      final output = OutputMemoryStream();
      final writer = layout == null ? null : _OrderedWriter(output);
      String? reason;
      final ok = await xzDecodeMultithreaded(
        bytes: bytes,
        layout: layout,
        verify: verify,
        maxPreallocateSize: maxPreallocateSize,
        workers: options.workers,
        memoryBudget: options.memoryBudget,
        onChunk: writer == null
            ? (offset, chunk) => output.writeBytes(chunk)
            : writer.add,
        onFailureReason: (r) => reason = r,
        orderedOutput: writer != null,
        fileReadBufferSize: options.fileReadBufferSize,
      );
      if (!ok && throwOnError) {
        throw _invalid(reason);
      }
      // Return what decoded either way. The single threaded path does the same
      return output.getBytes();
    }

    final blocks = layout.blocks;
    final output = Uint8List(layout.uncompressedSize);
    // How much of each block arrived and whether it is good. A failure can
    // then still report the usable part of the output. A block counts as good
    // until told otherwise. Those verdicts only arrive on a split archive
    final received = List<int>.filled(blocks.length, 0);
    final accepted = List<bool>.filled(blocks.length, true);
    String? reason;
    // Set when a block produced more than the index said. The archive then
    // contradicts itself
    var overran = false;

    final ok = await xzDecodeMultithreaded(
      bytes: bytes,
      layout: layout,
      verify: verify,
      maxPreallocateSize: maxPreallocateSize,
      workers: options.workers,
      memoryBudget: options.memoryBudget,
      onChunk: (offset, chunk) {
        // A block header can claim more output than the index gives that
        // block. A damaged one often does. The buffer came from the index and
        // the extra has nowhere to go. Keep what fits and mark the decode
        // failed. Letting setRange throw is worse. This runs in a callback and
        // a bare RangeError would come back even after asking for failures by
        // return value.
        //
        // No good output is thrown away here. The two sizes disagree and the
        // archive is broken whichever one is believed. The buffer came from
        // the index. A corrupt block header could otherwise ask for any
        // allocation it likes. That is what maxPreallocateSize prevents
        var length = chunk.length;
        if (offset + length > output.length) {
          length = output.length - offset;
          overran = true;
          reason ??= "Uncompressed data doesn't match the length in the index";
        }
        if (length <= 0) {
          return;
        }
        output.setRange(
            offset, offset + length, Uint8List.sublistView(chunk, 0, length));
        if (blocks.isNotEmpty) {
          final index = _blockIndexAt(blocks, offset);
          received[index] += length;
          if (overran) {
            // Stops the cut below at this block. It filled its share of the
            // output and would otherwise pass for whole and good
            accepted[index] = false;
          }
        }
      },
      onBlockDone: (offset, blockOk) {
        if (blocks.isNotEmpty) {
          final index = _blockIndexAt(blocks, offset);
          accepted[index] = accepted[index] && blockOk;
        }
      },
      onFailureReason: (r) => reason = r,
      fileReadBufferSize: options.fileReadBufferSize,
    );

    if (ok && !overran) {
      return output;
    }
    if (throwOnError) {
      throw _invalid(reason);
    }

    // Blocks decode out of order. The output is cut at the first block that
    // is not whole and good, that block included, where one thread would have
    // given up. A block that failed part way keeps what it managed, since
    // chunks inside one block arrive in order. A block that failed only its
    // check keeps all of it. These bytes are not vouched for either way
    var end = 0;
    for (var i = 0; i < blocks.length; i++) {
      final whole = received[i] == blocks[i].uncompressedLength;
      if (!whole) {
        end = blocks[i].outputOffset + received[i];
        break;
      }
      end = blocks[i].outputOffset + blocks[i].uncompressedLength;
      if (!accepted[i]) {
        break;
      }
    }
    return Uint8List.sublistView(output, 0, end);
  }

  Future<bool> _decodeStreamOnIsolates(
      InputStream input,
      OutputStream output,
      bool verify,
      bool throwOnError,
      XZMultithreadOptions<bool> options) async {
    final region = xzFileRegionOf(input);

    XZLayout? layout;
    Uint8List? bytes;
    if (region != null) {
      layout = xzLayoutOfFile(region);
    } else if (input is InputMemoryStream) {
      bytes = input.toUint8List();
      layout = parseXZLayout(XZMemorySource(bytes));
    } else {
      // Any other stream gives the workers no random access. It decodes on
      // the calling isolate
      return _decodeStream(input, output, verify, throwOnError);
    }

    // An OutputStream only appends. A block that finishes early waits for the
    // blocks in front of it
    final writer = _OrderedWriter(output);
    String? reason;

    final ok = await xzDecodeMultithreaded(
      bytes: bytes,
      path: region?.path,
      fileOffset: region?.offset ?? 0,
      fileLength: region?.length ?? 0,
      layout: layout,
      verify: verify,
      maxPreallocateSize: maxPreallocateSize,
      workers: options.workers,
      memoryBudget: options.memoryBudget,
      onChunk: writer.add,
      onFailureReason: (r) => reason = r,
      orderedOutput: true,
      fileReadBufferSize: options.fileReadBufferSize,
    );
    if (!ok && throwOnError) {
      throw _invalid(reason);
    }
    return ok;
  }

  // Runs [work] now. The result goes to [options.onDone] and a failure goes
  // to [options.onError]
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
        // Nothing would observe an unhandled asynchronous error. This failure
        // is reported the way an invalid archive is
        options.onDone(onFailure);
      }
    }));
  }

  // Reject bad settings instead of quietly doing something else. These feed
  // the arithmetic that sizes the pool and a nonsense value there fails
  // quietly. A negative read buffer makes the per worker cost negative. The
  // pool then skips the memory budget and hands out more workers than it
  // allows. Generic so that onDone reads back at its own type. A function
  // taking Uint8List is not a function taking Object?
  static void _checkOptions<T>(
      XZMultithreadOptions<T> options, bool throwOnError) {
    if (identical(options.onDone, xzNoResult)) {
      throw ArgumentError.value(
          null,
          'onDone',
          'Must be given here, since this call has nowhere else to put the '
              'result; only the converter carries its own end');
    }
    // Asking to hear about failures with nowhere to tell would send the
    // failure back where it started. It is refused before the call returns
    if (throwOnError && options.onError == null) {
      throw ArgumentError.value(
          null,
          'onError',
          'Must be given when throwOnError is set, since that is where the '
              'exception is delivered');
    }
    final workers = options.workers;
    if (workers != null && workers < 1) {
      throw ArgumentError.value(workers, 'workers', 'Must be at least 1');
    }
    final budget = options.memoryBudget;
    if (budget != null && budget < 1) {
      throw ArgumentError.value(budget, 'memoryBudget', 'Must be at least 1');
    }
    if (options.fileReadBufferSize < 1) {
      throw ArgumentError.value(options.fileReadBufferSize,
          'fileReadBufferSize', 'Must be at least 1');
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

/// Default for [XZDecoder.maxPreallocateSize].
///
/// 2 GB where a failed allocation is survivable. 256 MB on the web. dart2js
/// and dart2wasm kill the page instead of throwing something catchable.
/// dart2wasm cannot reach 1 GB at all. 256 MB stays under that
final int xzDefaultMaxPreallocateSize =
    xzIsolatesSupported ? 1 << 31 : 256 * 1024 * 1024;

// Adds up the uncompressed size of every stream in [d]. The sizes come from
// the stream indexes. Returns null when they cannot be read or the total
// passes [maxSize]
int? _uSize(Uint8List d, int maxSize) =>
    parseXZLayout(XZMemorySource(d), maxUncompressedSize: maxSize)
        ?.uncompressedSize;

import 'dart:convert';
import 'dart:typed_data';

import 'archive_exception.dart';
import 'byte_order.dart';
import 'input_stream.dart';
import 'output_memory_stream.dart';
import 'output_stream.dart';

/// A codec that is handed bytes rather than asking for them.
///
/// The decoders in this package pull: they ask their input for the next field
/// and the input blocks until it has it. A `Stream` cannot be read that way, so
/// this turns the loop around. A subclass keeps its position in fields rather
/// than on the stack, reads whatever has arrived in [step], and returns as soon
/// as a field is short; the next arrival carries on where it stopped.
///
/// What the base owns is everything that is not the format: holding what has
/// arrived and not been read, handing the parse the caller's own buffer where
/// nothing is held, and what a failure means afterwards.
abstract class ChunkedSink extends ByteConversionSink {
  /// Where the result goes, one piece at a time
  final Sink<List<int>> output;

  ChunkedSink(this.output);

  /// Bytes that have arrived and not been read. It holds one field, or one
  /// unit of the format, never everything that has come past
  Uint8List _carry = Uint8List(0);

  /// The buffer this sink owns. [_carry] is the caller's piece while a call is
  /// running and this one between calls
  Uint8List _owned = Uint8List(0);
  int _at = 0;
  int _end = 0;

  var _closed = false;
  Object? _failure;

  /// Bytes read so far, which is what a format measures its padding and its
  /// own lengths against
  var consumed = 0;

  /// Reads what has arrived and returns at the first field that is not all
  /// here yet. Called again with more bytes behind it
  void step();

  /// What the format needs before the input may end. Called once, after the
  /// last [step], and only when nothing has failed
  void finish();

  /// How many bytes have arrived and not been read
  int get available => _end - _at;

  /// The next [count] bytes without copying them. Only valid until the call
  /// that reads them returns, since the buffer under it may be the caller's
  Uint8List view(int count) => Uint8List.sublistView(_carry, _at, _at + count);

  /// Marks [count] bytes as read
  void skip(int count) {
    _at += count;
    consumed += count;
  }

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  /// Takes part of a buffer without the caller having to cut a view of it,
  /// which is what a `ByteConversionSink` is for
  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    RangeError.checkValidRange(start, end, chunk.length);
    _add(chunk is Uint8List
        ? Uint8List.sublistView(chunk, start, end)
        : Uint8List.fromList(chunk.sublist(start, end)));
    if (isLast) {
      close();
    }
  }

  void _add(Uint8List bytes) {
    if (_closed) {
      throw StateError('Cannot add to a closed sink');
    }
    final failure = _failure;
    if (failure != null) {
      throw failure;
    }
    if (bytes.isEmpty) {
      return;
    }
    if (_at == _end) {
      // Nothing is held, so the parse reads out of what arrived rather than
      // out of a copy of it. The caller owns its buffer again the moment this
      // returns, which is why whatever the parse did not reach is kept
      _carry = bytes;
      _at = 0;
      _end = bytes.length;
      try {
        _guarded(step);
      } finally {
        _keepRest();
      }
      return;
    }
    _append(bytes);
    _guarded(step);
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    final failure = _failure;
    if (failure != null) {
      throw failure;
    }
    _guarded(step);
    _guarded(finish);
    output.close();
  }

  /// Runs a piece of the parse and remembers a failure, so that the next call
  /// reports the same one rather than reading what follows it as if nothing
  /// had happened. What a codec's core throws at corrupt data is whatever it
  /// ran into, and this is where that becomes one kind of failure
  void _guarded(void Function() body) {
    try {
      body();
    } catch (error) {
      _failure ??=
          error is ArchiveException ? error : ArchiveException('$error');
      throw _failure!;
    }
  }

  void _append(Uint8List chunk) {
    final held = _end - _at;
    final need = held + chunk.length;
    if (need > _owned.length) {
      var size = _owned.isEmpty ? 1 << 16 : _owned.length;
      while (size < need) {
        size <<= 1;
      }
      final next = Uint8List(size);
      next.setRange(0, held, _carry, _at);
      _owned = next;
    } else {
      _owned.setRange(0, held, _carry, _at);
    }
    _carry = _owned;
    _at = 0;
    _end = held;
    _carry.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  /// Moves what the parse did not reach into this sink's own buffer, so that
  /// no view of the caller's piece outlives the call
  void _keepRest() {
    final rest = _end - _at;
    if (rest > _owned.length) {
      var size = _owned.isEmpty ? 1 << 16 : _owned.length;
      while (size < rest) {
        size <<= 1;
      }
      _owned = Uint8List(size);
    }
    if (rest > 0) {
      _owned.setRange(0, rest, _carry, _at);
    }
    _carry = _owned;
    _at = 0;
    _end = rest;
  }
}

/// A `Converter` over a [ChunkedSink]. Whole input conversion goes through the
/// chunked path, which is what `ZLibDecoder` does too, so there is one
/// behaviour rather than two
abstract class ChunkedConverter extends Converter<List<int>, List<int>> {
  const ChunkedConverter();

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink);

  @override
  List<int> convert(List<int> input) {
    final held = _Collected();
    startChunkedConversion(held)
      ..add(input)
      ..close();
    return held.bytes;
  }
}

class _Collected implements Sink<List<int>> {
  final _pieces = <List<int>>[];
  var _length = 0;

  @override
  void add(List<int> data) {
    _pieces.add(data);
    _length += data.length;
  }

  @override
  void close() {}

  Uint8List get bytes {
    final out = Uint8List(_length);
    var at = 0;
    for (final piece in _pieces) {
      out.setRange(at, at + piece.length, piece);
      at += piece.length;
    }
    return out;
  }
}

/// Under the block every codec here gathers into
const _streamPiece = 1 << 16;

/// The output side of a chunked codec: what a codec's core writes into an
/// `OutputStream`, handed to a `Sink` piece by piece.
///
/// Every range is copied on the way out. The core writes ranges of a buffer it
/// keeps using, so a sink that held a view of one would see it change
class SinkOutputStream extends OutputStream {
  final Sink<List<int>> sink;

  SinkOutputStream(this.sink) : super(byteOrder: ByteOrder.littleEndian);

  /// Written since the last [reset], which is what a format compares against
  /// the length it declared
  var written = 0;

  /// Where the bytes go instead of the sink, for the stretch a filter has to
  /// read back before anything may be handed over
  OutputMemoryStream? get divert => _divert;
  OutputMemoryStream? _divert;

  set divert(OutputMemoryStream? held) {
    // What is queued belongs in front of what is about to be diverted
    _drain();
    _divert = held;
  }

  /// Small writes are gathered here rather than handed over one at a time: a
  /// bit writer hands over single bytes, and a sink that is a file or a socket
  /// pays for every one of them
  final Uint8List _buffer = Uint8List(_streamPiece);
  int _queued = 0;

  /// Folded in as the bytes go past, which is how a check is computed without
  /// holding what it covers
  void Function(Uint8List piece)? watch;

  void reset() {
    written = 0;
  }

  @override
  int get length => written;

  @override
  void writeRange(Uint8List bytes, int start, int end) =>
      _emit(Uint8List.sublistView(bytes, start, end));

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _emit(bytes is Uint8List
        ? Uint8List.sublistView(bytes, 0, count)
        : Uint8List.fromList(bytes.sublist(0, count)));
  }

  @override
  void writeByte(int value) => _emit(Uint8List.fromList([value]));

  /// A piece at a time rather than one buffer, since `toUint8List` on a file
  /// reads the whole remainder. The read position ends where it started
  @override
  void writeStream(InputStream stream) {
    final held = stream.position;
    final buffer = Uint8List(_streamPiece);
    while (!stream.isEOS) {
      final got = stream.readInto(buffer, 0, buffer.length);
      if (got <= 0) {
        break;
      }
      _emit(Uint8List.sublistView(buffer, 0, got));
    }
    stream.setPosition(held);
  }

  void _emit(Uint8List piece) {
    if (piece.isEmpty) {
      return;
    }
    written += piece.length;
    watch?.call(piece);
    final held = _divert;
    if (held != null) {
      held.writeBytes(piece);
      return;
    }
    // A range the core wrote can be megabytes, and a sink handed it in one go
    // has no way to hold the codec back while it deals with it
    if (piece.length >= _streamPiece) {
      _drain();
      for (var at = 0; at < piece.length; at += _streamPiece) {
        final end =
            at + _streamPiece < piece.length ? at + _streamPiece : piece.length;
        sink.add(Uint8List.fromList(Uint8List.sublistView(piece, at, end)));
      }
      return;
    }
    var at = 0;
    while (at < piece.length) {
      var take = _streamPiece - _queued;
      if (take > piece.length - at) {
        take = piece.length - at;
      }
      _buffer.setRange(_queued, _queued + take, piece, at);
      _queued += take;
      at += take;
      if (_queued == _streamPiece) {
        _drain();
      }
    }
  }

  void _drain() {
    if (_queued == 0) {
      return;
    }
    sink.add(Uint8List.fromList(Uint8List.sublistView(_buffer, 0, _queued)));
    _queued = 0;
  }

  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('a streamed result cannot be read back');

  @override
  void clear() => written = 0;

  /// Hands over whatever is queued. Every codec calls this when it is done,
  /// which is what makes the gathering safe
  @override
  void flush() => _drain();
}

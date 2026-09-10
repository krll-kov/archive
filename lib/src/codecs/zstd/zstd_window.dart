import 'dart:typed_data';

import '../../util/output_stream.dart';

/// The buffer decoded bytes are written into and matches copy from. With no
/// [output] the whole result is kept. With one it stays at [windowSize] plus a
/// block, and what no match can reach is written out and the rest slid down
class ZstdWindow {
  final int windowSize;
  final OutputStream? output;

  Uint8List buffer = Uint8List(0);
  int capacity = 0;
  int position = 0;
  int flushed = 0;

  /// The span a match's source wraps around once the buffer has been written
  /// through once, which is what lets a streamed frame keep its history without
  /// ever moving it. Zero while the buffer is still on its first pass
  int lap = 0;

  /// Dictionary content held at the start of [buffer], which is never written
  /// out and is dropped only once no match can reach it
  int origin = 0;

  /// What one block asks for above the position it starts at. Only a request
  /// this size stands at a block boundary, which is the one place the buffer
  /// may start over
  int blockReserve = 0;

  ZstdWindow(this.windowSize, {this.output});

  int get length => flushed + position - origin;

  /// Puts dictionary [content] before the output for matches to reach
  void prime(Uint8List content) {
    reserve(content.length);
    buffer.setRange(0, content.length, content);
    position = content.length;
    origin = content.length;
  }

  /// Makes room for [need] more bytes, moving both [buffer] and [position], so
  /// hoist those into locals only after calling this
  void reserve(int need) {
    if (position + need <= capacity) {
      return;
    }
    final sink = output;
    if (sink != null) {
      // A whole window of output stands in front of the dictionary, so nothing
      // can reach it any more
      if (origin > 0 && position - origin >= windowSize) {
        buffer.setRange(0, position - origin, buffer, origin);
        position -= origin;
        origin = 0;
      }
      // `ZSTD_decompressStream` restarts at the head of its buffer rather than
      // sliding: the pass just written stays put and becomes the history a
      // match reaches back into, so nothing is ever moved. What is overwritten
      // from here on is only what has fallen out of the window
      // The pass has to end far enough in that a match at the widest offset
      // still lands above what this pass will overwrite, which is why the
      // buffer carries two blocks' room rather than one
      if (origin == 0 && need == blockReserve && position >= windowSize + need) {
        _flush(sink, 0, position);
        flushed += position;
        // The span is where the pass ended, not where the buffer does: the
        // bytes past it were never written and no match may name them
        lap = position;
        position = 0;
        return;
      }
    }
    _grow(need, sink != null);
  }

  void _flush(OutputStream sink, int from, int to) {
    var at = from;
    while (at < to) {
      final take = to - at < _flushChunk ? to - at : _flushChunk;
      sink.writeRange(buffer, at, at + take);
      at += take;
    }
  }


  void finish() {
    final sink = output;
    if (sink != null && position > origin) {
      // A whole window handed over at once is a whole window the sink may copy,
      // so the tail goes out in pieces the size of a block
      _flush(sink, origin, position);
      flushed += position - origin;
      position = 0;
      origin = 0;
      lap = 0;
    }
  }

  static const _flushChunk = 1 << 20;

  /// Where growth stops doubling and goes on in steps of this size
  static const _doubleTo = 1 << 25;

  void _grow(int need, bool bounded) {
    final wanted = position + need;
    // Exact first, so a caller that knows the frame's size gets that and no more
    var size = capacity == 0 ? wanted : capacity;
    // Slack above the window, so sliding the history down happens once per
    // slack bytes rather than once per block. Without it a wide window is moved
    // whole for every block, which is what the output costs, not the decode
    final ceiling = bounded ? origin + windowSize + 2 * need : 0;
    while (size < wanted) {
      size <<= 1;
      // Every buffer left behind is garbage the collector has yet to take, so
      // once the doubling is into real memory the last step goes to the bound
      // the window sets rather than through it
      if (bounded && size >= _doubleTo) {
        size = ceiling;
        break;
      }
    }
    if (bounded && size > ceiling) {
      size = ceiling;
    }
    if (size < wanted) {
      size = wanted;
    }
    final next = Uint8List(size + 32);
    next.setRange(0, position, buffer);
    buffer = next;
    capacity = size;
  }
}

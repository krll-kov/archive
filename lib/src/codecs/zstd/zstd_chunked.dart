import 'dart:convert';
import 'dart:typed_data';

import '../../util/archive_exception.dart';
import '../../util/chunked_sink.dart';
import '../../util/xxh64.dart';
import 'zstd_block_decoder.dart';
import 'zstd_block_encoder.dart';
import 'zstd_block_splitter.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_frame_decoder.dart';
import 'zstd_level_params.dart';
import 'zstd_window.dart';

/// zstd for data that arrives in pieces, which is what a `Stream` gives.
///
/// A frame written this way names no content size, since a stream does not know
/// it, and takes its parameters from the row the reference picks when the size
/// is unknown. That is a different archive from the one [ZstdEncoder] writes for
/// the same bytes, and the same one `ZSTD_compressStream2` writes
class ZstdCodec extends Codec<List<int>, List<int>> {
  /// Checks the XXH64 of every frame that carries one
  final bool verify;

  /// What a frame may name to reach back into
  final ZstdDictionary? dictionary;

  /// Refuses a frame whose window is wider than this, which is what stops an
  /// archive from naming an allocation
  final int windowSizeLimit;

  const ZstdCodec(
      {this.verify = true,
      this.dictionary,
      this.windowSizeLimit = zstdDefaultWindowSizeLimit,
      this.level = zstdDefaultLevel,
      this.frameChecksum = true});

  @override
  ZstdDecoderConverter get decoder => ZstdDecoderConverter(
      verify: verify,
      dictionary: dictionary,
      windowSizeLimit: windowSizeLimit);

  /// What [ZstdEncoderConverter.level] uses
  final int level;

  /// Whether a frame this writes carries an XXH64 of its content
  final bool frameChecksum;

  @override
  ZstdEncoderConverter get encoder =>
      ZstdEncoderConverter(level: level, checksum: frameChecksum);
}

/// The codec with its defaults, for `stream.transform(zstdCodec.decoder)`
const zstdCodec = ZstdCodec();

/// Decodes zstd from a `Stream` of pieces into a `Stream` of pieces
class ZstdDecoderConverter extends ChunkedConverter {
  /// Checks the XXH64 of every frame that carries one. On by default: a caller
  /// reading a stream has handed the compressed bytes back by the time the
  /// check would be made, so there is no second chance at it
  final bool verify;

  final ZstdDictionary? dictionary;
  final int windowSizeLimit;

  const ZstdDecoderConverter(
      {this.verify = true,
      this.dictionary,
      this.windowSizeLimit = zstdDefaultWindowSizeLimit});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      ZstdChunkedDecoder(
          sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
          verify: verify,
          dictionary: dictionary,
          windowSizeLimit: windowSizeLimit);
}

/// Writes zstd from a `Stream` of pieces into a `Stream` of pieces
class ZstdEncoderConverter extends ChunkedConverter {
  final int level;

  /// Whether the frame carries an XXH64 of its content
  final bool checksum;

  const ZstdEncoderConverter(
      {this.level = zstdDefaultLevel, this.checksum = true});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      ZstdChunkedEncoder(
          sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
          level: level,
          checksum: checksum);
}

/// Writes one zstd frame over data that arrives in pieces.
///
/// `ZSTD_compressStream2` hands its own buffer one block of input at a time and
/// lets the block splitter cut inside that one block, which is what makes a
/// streamed archive differ from the one the whole input would give. This does
/// the same: it gathers a block, then encodes what has gathered
class ZstdChunkedEncoder extends ChunkedSink {
  final int level;
  final bool checksum;

  ZstdChunkedEncoder(super.output,
      {this.level = zstdDefaultLevel, this.checksum = true});

  late final _out = SinkOutputStream(output);
  late final ZstdLevelParams _params = zstdParamsForLevel(level, _sizeUnknown);
  late final int _matchWindow = 1 << _params.windowLog;
  late final int _blockSizeMax = _matchWindow < zstdBlockMaximumSize
      ? _matchWindow
      : zstdBlockMaximumSize;
  late final ZstdBlockEncoder _blocks = ZstdBlockEncoder(_blockSizeMax, _params);
  final _splitter = ZstdBlockSplitter();
  // The header is written on the first block, which is after the first bytes
  // have gone through the checksum, so neither may be set up there
  final _rep = Uint32List(3)..setAll(0, zstdInitialRepeatOffsets);
  final _hash = Xxh64();

  /// The window and what a block needs beside it, which is all this holds of
  /// the content
  late final Uint8List _buffer = _makeBuffer();
  var _at = 0;
  var _filled = 0;
  var _base = 0;
  var _savings = 0;
  var _started = false;

  /// How much of the content has been taken in, which is what says where the
  /// reference's input ring is
  var _content = 0;

  /// `inBuffSize`, the ring the reference gathers into. It hands one
  /// `blockSizeMax` to the compressor at a time and starts over once the next
  /// one would not fit, so it wraps on every multiple of this
  late final int _ring = _matchWindow + _blockSizeMax;

  /// What the reference reads for a size it does not know, which is the row it
  /// picks and the window it leaves unclamped
  static const _sizeUnknown = 1099511627776;

  Uint8List _makeBuffer() {
    var slack = _blocks.slideCost;
    if (slack < _matchWindow) {
      slack = _matchWindow;
    }
    return Uint8List(_matchWindow + slack + _blockSizeMax + _blocks.slideStep);
  }

  @override
  void step() {
    while (available >= _blockSizeMax) {
      _gather(_blockSizeMax);
      _encodeGathered(last: false);
    }
  }

  @override
  void finish() {
    _writeHeader();
    if (available > 0) {
      _gather(available);
    }
    _encodeGathered(last: true);
    if (checksum) {
      final digest = _hash.digestLow;
      _out
        ..writeByte(digest & 0xff)
        ..writeByte((digest >>> 8) & 0xff)
        ..writeByte((digest >>> 16) & 0xff)
        ..writeByte((digest >>> 24) & 0xff);
    }
    _out.flush();
  }

  /// Takes [count] bytes of what arrived into the window, sliding it first if
  /// what is held no longer leaves room
  void _gather(int count) {
    if (_filled + count > _buffer.length) {
      var delta = _at > _matchWindow ? _at - _matchWindow : 0;
      delta -= delta % _blocks.slideStep;
      if (delta > 0) {
        _buffer.setRange(0, _filled - delta, _buffer, delta);
        _at -= delta;
        _filled -= delta;
        _base = _base > delta ? _base - delta : 0;
        _blocks.slide(delta);
      }
    }
    // On a wrap the reference writes over the oldest bytes of the ring, so what
    // it still holds stops being contiguous with what comes now. The window it
    // reaches over is unchanged, only its low part is now a segment of its own
    if (_content > 0 && _content % _ring == 0) {
      _blocks.cut(_filled);
    }
    final piece = view(count);
    _buffer.setRange(_filled, _filled + count, piece);
    if (checksum) {
      _hash.update(_buffer, _filled, count);
    }
    _filled += count;
    _content += count;
    skip(count);
  }

  /// Encodes everything gathered and not yet written. The splitter runs inside
  /// this one gathering, never across two, which is the whole difference
  void _encodeGathered({required bool last}) {
    _writeHeader();
    var left = _filled - _at;
    if (left == 0) {
      if (last) {
        _blocks.encode(_buffer, _at, _at, _base, _out, true, _rep);
      }
      return;
    }
    while (left > 0) {
      final take =
          _splitter.sizeFor(_buffer, _at, left, _blockSizeMax, _params, _savings);
      final reach = _at - _matchWindow;
      final before = _out.written;
      _blocks.encode(_buffer, _at, _at + take, reach > _base ? reach : _base,
          _out, last && take == left, _rep);
      _savings += take - (_out.written - before);
      _at += take;
      left -= take;
    }
  }

  /// `ZSTD_writeFrameHeader` for a frame that names no content size: the
  /// descriptor says so, and the window byte says how far back it may reach
  void _writeHeader() {
    if (_started) {
      return;
    }
    _started = true;
    _out
      ..writeByte(zstdMagic & 0xff)
      ..writeByte((zstdMagic >>> 8) & 0xff)
      ..writeByte((zstdMagic >>> 16) & 0xff)
      ..writeByte((zstdMagic >>> 24) & 0xff)
      ..writeByte(checksum ? 4 : 0)
      ..writeByte((_params.windowLog - 10) << 3);
  }
}

/// Decodes a zstd archive that arrives in pieces.
///
/// The unit of progress is one block, at most 128 KiB, so what is held is the
/// frame's window and one block, whatever the archive weighs
class ZstdChunkedDecoder extends ChunkedSink {
  final bool verify;
  final ZstdDictionary? dictionary;
  final int windowSizeLimit;

  ZstdChunkedDecoder(super.output,
      {this.verify = true,
      this.dictionary,
      this.windowSizeLimit = zstdDefaultWindowSizeLimit});

  late final _sink = SinkOutputStream(output);
  final _blocks = ZstdBlockDecoder();
  final _rep = Uint32List(3);
  final _hash = Xxh64();
  final _blockHeader = Uint8List(3);

  _Stage _stage = _Stage.magic;
  ZstdFrameHeader? _header;
  ZstdWindow? _window;
  var _frames = 0;
  var _checked = false;
  var _produced = 0;
  var _skipLeft = 0;
  var _bodyLength = 0;
  var _blockSizeMax = 0;

  @override
  void step() {
    while (true) {
      switch (_stage) {
        case _Stage.magic:
          if (available < 4) {
            return;
          }
          _readMagic();
        case _Stage.skippableSize:
          if (available < 4) {
            return;
          }
          _skipLeft = _uint32(view(4));
          skip(4);
          _stage = _Stage.skippableBody;
        case _Stage.skippableBody:
          if (available == 0) {
            return;
          }
          final take = available < _skipLeft ? available : _skipLeft;
          skip(take);
          _skipLeft -= take;
          if (_skipLeft > 0) {
            return;
          }
          _stage = _Stage.magic;
        case _Stage.frameHeader:
          if (available < 1) {
            return;
          }
          final size = _headerSize(view(1)[0]);
          if (available < size) {
            return;
          }
          _readFrameHeader(size);
        case _Stage.blockHeader:
          if (available < 3) {
            return;
          }
          _readBlockHeader();
        case _Stage.blockBody:
          if (available < _bodyLength) {
            return;
          }
          _readBlockBody();
        case _Stage.checksum:
          if (available < 4) {
            return;
          }
          _readChecksum();
      }
    }
  }

  @override
  void finish() {
    if (_stage != _Stage.magic || available != 0) {
      throw ArchiveException('zstd: the archive ended part way through');
    }
    if (_frames == 0) {
      throw ArchiveException('zstd: no frame, the input is empty');
    }
    _sink.flush();
  }

  static int _uint32(Uint8List bytes) =>
      bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);

  void _readMagic() {
    final magic = _uint32(view(4));
    skip(4);
    if (magic >= zstdSkippableMagicMin && magic <= zstdSkippableMagicMax) {
      _stage = _Stage.skippableSize;
      return;
    }
    if (magic != zstdMagic) {
      throw ArchiveException('zstd: not a zstd frame');
    }
    _stage = _Stage.frameHeader;
  }

  /// What the descriptor says the rest of the header weighs: the window byte
  /// unless the frame is one segment, the dictionary id, and the content size
  static int _headerSize(int descriptor) {
    const fcsSizes = [0, 2, 4, 8];
    const dictSizes = [0, 1, 2, 4];
    final fcsFlag = descriptor >> 6;
    final singleSegment = (descriptor >> 5) & 1 != 0;
    final fcs = fcsFlag == 0 ? (singleSegment ? 1 : 0) : fcsSizes[fcsFlag];
    return 1 + (singleSegment ? 0 : 1) + dictSizes[descriptor & 3] + fcs;
  }

  void _readFrameHeader(int size) {
    final header = readFrameHeader(view(size), 0, size, windowSizeLimit);
    final dictionary = this.dictionary;
    if (header.dictionaryId != 0 &&
        (dictionary == null || dictionary.id != header.dictionaryId)) {
      throw ArchiveException(
          'zstd: frame needs dictionary ${header.dictionaryId}');
    }
    skip(size);

    final window = ZstdWindow(header.windowSize, output: _sink)
      ..blockReserve = header.blockReserve;
    if (dictionary != null && dictionary.content.isNotEmpty) {
      window.prime(dictionary.content);
    }
    _window = window;
    _header = header;
    _blockSizeMax = header.blockSizeMax;
    _blocks.reset(dictionary);
    _rep.setAll(0, dictionary?.repeatOffsets ?? zstdInitialRepeatOffsets);
    _checked = header.hasChecksum && verify;
    if (_checked) {
      _hash.reset();
    }
    _produced = 0;
    _stage = _Stage.blockHeader;
  }

  void _readBlockHeader() {
    final field = view(3);
    _blockHeader
      ..[0] = field[0]
      ..[1] = field[1]
      ..[2] = field[2];
    final header = field[0] | (field[1] << 8) | (field[2] << 16);
    final type = (header >> 1) & 3;
    final size = header >> 3;
    if (type == zstdBlockReserved) {
      throw ArchiveException('zstd: a block names the reserved type');
    }
    if (size > _blockSizeMax) {
      throw ArchiveException(
          'zstd: block of $size bytes is above the $_blockSizeMax its frame '
          'allows');
    }
    _bodyLength = type == zstdBlockRle ? 1 : size;
    skip(3);
    _stage = _Stage.blockBody;
  }

  void _readBlockBody() {
    final window = _window!;
    window.reserve(_header!.blockReserve);
    final from = window.position;
    _blocks.decode(_blockHeader, 0, 3, window, _rep, _blockSizeMax,
        body: view(_bodyLength), bodyAt: 0);
    if (_checked) {
      _hash.update(window.buffer, from, window.position - from);
    }
    _produced += window.position - from;
    skip(_bodyLength);
    if (!_blocks.isLast) {
      _stage = _Stage.blockHeader;
      return;
    }
    final expected = _header!.contentSize;
    if (expected != null && _produced != expected) {
      throw ArchiveException('zstd: frame produced $_produced bytes against '
          'the $expected it declared');
    }
    if (_header!.hasChecksum) {
      _stage = _Stage.checksum;
      return;
    }
    _endFrame();
  }

  void _readChecksum() {
    final stored = _uint32(view(4));
    skip(4);
    if (_checked && _hash.digestLow != stored) {
      throw ArchiveException('zstd: content checksum does not match');
    }
    _endFrame();
  }

  void _endFrame() {
    _window!.finish();
    _window = null;
    _header = null;
    _frames++;
    _stage = _Stage.magic;
  }
}

enum _Stage {
  magic,
  skippableSize,
  skippableBody,
  frameHeader,
  blockHeader,
  blockBody,
  checksum,
}

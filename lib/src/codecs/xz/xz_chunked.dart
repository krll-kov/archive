import 'dart:convert';
import 'dart:typed_data';

import '../../util/archive_exception.dart';
import '../../util/chunked_sink.dart';
import '../../util/crc32.dart';
import '../../util/crc64.dart';
import '../../util/input_memory_stream.dart';
import '../../util/output_memory_stream.dart';
import '../bcj_x86.dart';
import '../lzma/lzma_decoder.dart';
import '../xz_encoder.dart';
import 'xz_block_dispatch.dart';
import 'xz_multithread_options.dart';
import 'xz_parallel.dart';

/// Decodes xz from a `Stream` of pieces into a `Stream` of pieces:
///
/// ```dart
/// await for (final piece in file.openRead().transform(xzCodec.decoder)) {
///   ...
/// }
/// ```
///
/// Where the input is cut means nothing to the format, so any pieces will do
class XzDecoderConverter extends ChunkedConverter {
  /// Checks the CRC of every block that carries one it can compute. On by
  /// default: a caller reading a stream has handed the compressed bytes back
  /// by the time the check would be made, so there is no second chance at it
  final bool verify;

  /// Decodes blocks on isolates when this converter is bound to a stream. Only
  /// a block whose header declares both lengths can be sent ahead, which is
  /// what `xz` writes in threaded mode; any other is decoded here, after the
  /// blocks before it are out. `startChunkedConversion` cannot take it: its
  /// sink owes its output before it returns, and a worker answers later
  final XZMultithreadOptions<Object?>? multithread;

  const XzDecoderConverter({this.verify = true, this.multithread});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) {
    if (multithread != null) {
      throw ArgumentError.value(multithread, 'multithread',
          'Works through a stream only, since a sink owes its output before '
              'it returns');
    }
    return XzChunkedDecoder(
        sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
        verify: verify);
  }

  @override
  Stream<List<int>> bind(Stream<List<int>> stream) {
    final options = multithread;
    if (options == null) {
      return super.bind(stream);
    }
    return _bindMultithread(stream, options);
  }

  Stream<List<int>> _bindMultithread(
      Stream<List<int>> stream, XZMultithreadOptions<Object?> options) async* {
    final workers = options.workers;
    if (workers != null && workers < 1) {
      throw ArgumentError.value(workers, 'workers', 'Must be at least 1');
    }
    final budget = options.memoryBudget;
    if (budget != null && budget < 1) {
      throw ArgumentError.value(budget, 'memoryBudget', 'Must be at least 1');
    }
    if (!xzIsolatesSupported) {
      // Not super.bind: that goes through startChunkedConversion, which
      // refuses the options this converter still carries
      yield* XzDecoderConverter(verify: verify).bind(stream);
      return;
    }
    yield* xzDecodeStreamMultithreaded(stream,
        verify: verify, workers: workers, memoryBudget: budget);
  }
}

/// xz for data that arrives in pieces, which is what a `Stream` gives.
///
/// The shape is the one `dart:io` uses for gzip: one converter per direction,
/// so a pipeline reads `stream.transform(xzCodec.decoder)` and a whole buffer
/// reads `xzCodec.decode(bytes)`
class XzCodec extends Codec<List<int>, List<int>> {
  /// Checks the CRC of every block that carries one it can compute
  final bool verify;

  /// Which check the blocks this writes carry
  final XZCheck check;

  /// Decodes on isolates when [decoder] is bound to a stream, as
  /// [XzDecoderConverter.multithread] describes
  final XZMultithreadOptions<Object?>? multithread;

  const XzCodec(
      {this.verify = true, this.check = XZCheck.crc64, this.multithread});

  @override
  XzDecoderConverter get decoder =>
      XzDecoderConverter(verify: verify, multithread: multithread);

  @override
  XzEncoderConverter get encoder => XzEncoderConverter(check: check);
}

/// The codec with its defaults, for `stream.transform(xzCodec.decoder)`
const xzCodec = XzCodec();

/// Decodes an xz archive that arrives in pieces, which is what a `Stream` of
/// bytes gives. The pull decoder asks its input for the next field and blocks
/// until it has it; this one is handed whatever has arrived and stops on the
/// first field that is not there yet, so nothing has to wait inside the parse.
///
/// The unit of progress is one LZMA2 chunk, at most 64 KiB compressed by the
/// format, so what is held is the LZMA dictionary the archive asks for plus one
/// chunk, whatever the archive weighs.
class XzChunkedDecoder extends ChunkedSink {
  /// Checks the CRC of every block that carries one it can compute, on by
  /// default for the reason [XzDecoderConverter.verify] gives
  final bool verify;

  /// Takes the blocks that can be decoded elsewhere, which is how the threaded
  /// stream decoder shares this parse rather than repeating it
  final XzBlockDispatch? dispatch;

  /// Set while the parse waits for [dispatch] to go idle before a block it has
  /// to decode itself
  bool get waitingForIdle => _waitingForIdle;
  var _waitingForIdle = false;

  XzChunkedDecoder(super.output, {this.verify = true, this.dispatch}) {
    _sink = SinkOutputStream(output);
  }

  final _decoder = LzmaDecoder();
  late final SinkOutputStream _sink;

  /// Where the parse is, and what the state it is in still needs
  _Stage _stage = _Stage.streamHeader;

  /// Position within the current stream, which is what block and index padding
  /// is aligned to
  var _streamStart = 0;
  var _streamFlags = 0;
  final _blocks = <_BlockSize>[];

  /// The block being decoded
  var _blockStart = 0;
  var _blockDataStart = 0;

  /// Whether the block is still waiting for the chunk that starts its
  /// dictionary, which the format puts first
  var _needDictionaryReset = true;
  var _blockPadding = 0;
  var _paddingCount = 0;
  int? _declaredCompressedLength;
  int? _declaredUncompressedLength;
  var _dictionarySize = 0;
  var _x86Filter = false;
  var _x86StartOffset = 0;
  OutputMemoryStream? _blockBuffer;

  /// The LZMA2 chunk being read
  var _chunkControl = 0;
  var _chunkCompressedLength = 0;
  var _chunkUncompressedLength = 0;

  /// The block's check, folded in as the bytes go past rather than held
  var _blockCrc32 = 0;
  final _blockCrc64 = Crc64();
  var _blockLength = 0;

  void _foldCheck(Uint8List piece) {
    final checkType = _streamFlags & 0xf;
    if (checkType == 0x1) {
      _blockCrc32 = getCrc32(piece, _blockCrc32);
    } else if (checkType == 0x4) {
      _blockCrc64.update(piece);
    }
  }

  /// The index, checked against what the blocks actually were
  var _indexRecords = 0;
  var _indexRead = 0;
  var _indexStart = 0;
  var _indexSize = 0;
  var _indexCrc = 0;

  /// Where the current stream began, since padding is aligned to that and not
  /// to the start of everything that has come past
  int get _streamPosition => consumed - _streamStart;

  @override
  void finish() {
    if (_stage != _Stage.streamPadding || available != 0) {
      throw ArchiveException('xz: the archive ended part way through');
    }
    if ((_paddingCount & 3) != 0) {
      throw ArchiveException(
          'xz: stream padding is not a multiple of four bytes');
    }
    _sink.flush();
  }

  /// Reads what has arrived, one field at a time, and returns as soon as a
  /// field is short. Every step commits only once it has all of its bytes, so
  /// the next call starts where this one stopped
  @override
  void step() {
    while (true) {
      switch (_stage) {
        case _Stage.streamHeader:
          if (available < 12) {
            // Refused on the first byte that is not the magic rather than
            // waited on, since the input may stop sending without closing
            final seen = available < 6 ? available : 6;
            final head = view(seen);
            for (var i = 0; i < seen; i++) {
              if (head[i] != const [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0][i]) {
                throw ArchiveException('xz: invalid stream header signature');
              }
            }
            return;
          }
          _readStreamHeader();
        case _Stage.blockOrIndex:
          if (available < 1) {
            return;
          }
          if (view(1)[0] == 0) {
            _indexStart = _streamPosition;
            _stage = _Stage.indexHeader;
          } else {
            _stage = _Stage.blockHeader;
          }
        case _Stage.blockHeader:
          final size = (view(1)[0] + 1) * 4;
          if (available < size) {
            return;
          }
          if (!_readBlockHeader(size)) {
            return;
          }
        case _Stage.chunkControl:
          if (available < 1) {
            return;
          }
          _readChunkControl();
        case _Stage.chunkHeader:
          if (!_readChunkHeader()) {
            return;
          }
        case _Stage.chunkBody:
          if (available < _chunkCompressedLength) {
            return;
          }
          _readChunkBody();
        case _Stage.blockPadding:
          final pad = (4 - (_streamPosition & 3)) & 3;
          if (available < pad) {
            return;
          }
          for (var i = 0; i < pad; i++) {
            if (view(pad)[i] != 0) {
              throw ArchiveException('xz: invalid block padding');
            }
          }
          _blockPadding = pad;
          skip(pad);
          _stage = _Stage.blockCheck;
        case _Stage.blockCheck:
          final size = _checkSize(_streamFlags & 0xf);
          if (available < size) {
            return;
          }
          _readBlockCheck(size);
        case _Stage.indexHeader:
          if (!_readIndexHeader()) {
            return;
          }
        case _Stage.indexRecords:
          if (!_readIndexRecords()) {
            return;
          }
        case _Stage.indexPadding:
          final pad = (4 - ((_streamPosition - _indexStart) & 3)) & 3;
          if (available < pad) {
            return;
          }
          for (var i = 0; i < pad; i++) {
            if (view(pad)[i] != 0) {
              throw ArchiveException('xz: invalid stream index padding');
            }
          }
          _indexCrc = getCrc32(view(pad), _indexCrc);
          skip(pad);
          _stage = _Stage.indexCrc;
        case _Stage.indexCrc:
          if (available < 4) {
            return;
          }
          if (_readUint32() != _indexCrc) {
            throw ArchiveException('xz: invalid stream index CRC checksum');
          }
          _indexSize = _streamPosition - _indexStart;
          _stage = _Stage.streamFooter;
        case _Stage.streamFooter:
          if (available < 12) {
            return;
          }
          _readStreamFooter();
        case _Stage.streamPadding:
          // Padding is zeros in multiples of four, and what follows it is
          // another stream. Only the end of the input says which
          while (available > 0 && view(1)[0] == 0) {
            skip(1);
            _paddingCount++;
          }
          if (available == 0) {
            return;
          }
          if ((_paddingCount & 3) != 0) {
            throw ArchiveException(
                'xz: stream padding is not a multiple of four bytes');
          }
          _startStream();
      }
    }
  }

  int _readUint32() {
    final field = view(4);
    final value = field[0] |
        (field[1] << 8) |
        (field[2] << 16) |
        (field[3] << 24);
    skip(4);
    return value;
  }

  void _startStream() {
    _streamStart = consumed;
    _paddingCount = 0;
    _streamFlags = 0;
    _blocks.clear();
    _decoder.dictionaryCap = 0;
    _decoder.dictionaryLimit = 0;
    _decoder.reset(resetDictionary: true);
    _stage = _Stage.streamHeader;
  }

  void _readStreamHeader() {
    final magic = view(6);
    if (magic[0] != 253 ||
        magic[1] != 55 ||
        magic[2] != 122 ||
        magic[3] != 88 ||
        magic[4] != 90 ||
        magic[5] != 0) {
      throw ArchiveException('xz: invalid stream header signature');
    }
    skip(6);
    final flags = view(2);
    // The check id is the low nibble of the second byte and the rest is
    // reserved, so a stream that sets any of it asks for something else
    if (flags[0] != 0 || flags[1] & 0xf0 != 0) {
      throw ArchiveException('xz: invalid stream flags');
    }
    _streamFlags = flags[1];
    final crc = getCrc32(flags);
    skip(2);
    if (_readUint32() != crc) {
      throw ArchiveException('xz: invalid stream header CRC checksum');
    }
    _stage = _Stage.blockOrIndex;
  }

  /// False while it waits: for the rest of a block it hands over, or for the
  /// dispatch to go idle before a block it decodes itself
  bool _readBlockHeader(int size) {
    _blockStart = _streamPosition;
    final header = view(size - 4);
    final crc = getCrc32(header);
    final reader = _ByteReader(header, 1);
    final flags = reader.byte();
    if (flags & 0x3c != 0) {
      throw ArchiveException('xz: reserved bit is set in the block flags');
    }
    final filterCount = (flags & 0x3) + 1;
    _declaredCompressedLength =
        flags & 0x40 != 0 ? reader.multibyte() : null;
    _declaredUncompressedLength =
        flags & 0x80 != 0 ? reader.multibyte() : null;

    var lzma2 = false;
    _x86Filter = false;
    _x86StartOffset = 0;
    _dictionarySize = 0;
    for (var i = 0; i < filterCount; i++) {
      final id = reader.multibyte();
      final length = reader.multibyte();
      final properties = reader.bytes(length);
      if (id == 0x21) {
        if (length != 1) {
          throw ArchiveException('xz: invalid LZMA dictionary size');
        }
        final v = properties[0];
        if (v > 40) {
          throw ArchiveException('xz: invalid LZMA dictionary size');
        } else if (v == 40) {
          _dictionarySize = 0xffffffff;
        } else {
          _dictionarySize = (2 | (v & 0x1)) << ((v >> 1) + 11);
        }
        lzma2 = i == filterCount - 1;
      } else if (id == 0x04 && i == 0 && filterCount == 2) {
        if (length != 0 && length != 4) {
          throw ArchiveException('xz: invalid x86 filter start offset');
        }
        _x86Filter = true;
        if (properties.length == 4) {
          _x86StartOffset = properties[0] |
              properties[1] << 8 |
              properties[2] << 16 |
              properties[3] << 24;
        }
      } else {
        throw ArchiveException('xz: unsupported filter chain; only LZMA2, '
            'optionally behind the x86 BCJ filter, is supported');
      }
    }
    if (!lzma2) {
      throw ArchiveException('xz: unsupported filter chain; only LZMA2, '
          'optionally behind the x86 BCJ filter, is supported');
    }
    while (reader.at < header.length) {
      if (reader.byte() != 0) {
        throw ArchiveException('xz: invalid block header padding');
      }
    }

    final stored = view(size);
    final storedCrc = stored[size - 4] |
        (stored[size - 3] << 8) |
        (stored[size - 2] << 16) |
        (stored[size - 1] << 24);
    if (storedCrc != crc) {
      throw ArchiveException('xz: invalid block header CRC checksum');
    }

    final dispatch = this.dispatch;
    if (dispatch != null) {
      _waitingForIdle = false;
      final compressed = _declaredCompressedLength;
      final uncompressed = _declaredUncompressedLength;
      // Past the limit a claimed length would make the parse hold the rest of
      // the stream while it waits, so such a block is decoded here instead
      final limit = dispatch.maxBlockBytes;
      if (compressed != null &&
          uncompressed != null &&
          compressed <= limit &&
          uncompressed <= limit) {
        final checkSize = _checkSize(_streamFlags & 0xf);
        final total =
            size + compressed + ((4 - ((size + compressed) & 3)) & 3) + checkSize;
        if (available < total) {
          return false;
        }
        dispatch.block(Uint8List.fromList(view(total)), _streamFlags,
            uncompressed, _dictionarySize);
        // The worker holds the block to its declared lengths, so they are what
        // the index is checked against
        _blocks.add(_BlockSize(size + compressed + checkSize, uncompressed));
        skip(total);
        _stage = _Stage.blockOrIndex;
        return true;
      }
      if (!dispatch.idle) {
        _waitingForIdle = true;
        return false;
      }
    }

    _decoder.dictionaryLimit = _dictionarySize;
    if (_dictionarySize > 0 && _dictionarySize < 0x40000000) {
      _decoder.dictionaryCap =
          _dictionarySize + (_dictionarySize >> 2) + (2 << 20) + 16;
    }
    skip(size);

    // The x86 filter reads the block back, so that block alone is held. Every
    // other block is handed to the sink as its chunks come out
    _blockBuffer = _x86Filter ? OutputMemoryStream() : null;
    // A filtered block is checked over what the filter leaves, so the running
    // check is only worth keeping for a block that goes straight out
    _sink
      ..reset()
      ..divert = _blockBuffer;
    _blockCrc32 = 0;
    _blockCrc64.reset();
    _sink.watch = verify && !_x86Filter ? _foldCheck : null;
    _blockDataStart = _streamPosition;
    _needDictionaryReset = true;
    _stage = _Stage.chunkControl;
    return true;
  }

  void _readChunkControl() {
    _chunkControl = view(1)[0];
    skip(1);
    if (_chunkControl == 0) {
      _finishBlockData();
      return;
    }
    if (_chunkControl > 2 && _chunkControl < 0x80) {
      throw ArchiveException('xz: unknown LZMA2 control code $_chunkControl');
    }
    // A block decodes on its own, so its first chunk has to start the
    // dictionary: control 1 for an uncompressed chunk, reset 3 for an LZMA one
    final resets = _chunkControl < 0x80
        ? _chunkControl == 1
        : ((_chunkControl >> 5) & 0x3) == 3;
    if (_needDictionaryReset && !resets) {
      throw ArchiveException(
          'xz: the first LZMA2 chunk does not reset the dictionary');
    }
    _needDictionaryReset = false;
    _stage = _Stage.chunkHeader;
  }

  bool _readChunkHeader() {
    if (_chunkControl < 0x80) {
      if (available < 2) {
        return false;
      }
      final field = view(2);
      _chunkUncompressedLength = ((field[0] << 8) | field[1]) + 1;
      _chunkCompressedLength = _chunkUncompressedLength;
      skip(2);
      _decoder.reset(resetDictionary: _chunkControl == 1);
      _stage = _Stage.chunkBody;
      return true;
    }
    final reset = (_chunkControl >> 5) & 0x3;
    final need = reset >= 2 ? 5 : 4;
    if (available < need) {
      return false;
    }
    final field = view(need);
    _chunkUncompressedLength =
        (((_chunkControl & 0x1f) << 16) | (field[0] << 8) | field[1]) + 1;
    _chunkCompressedLength = ((field[2] << 8) | field[3]) + 1;
    int? literalContextBits;
    int? literalPositionBits;
    int? positionBits;
    if (reset >= 2) {
      var properties = field[4];
      if (properties > 224) {
        throw ArchiveException('xz: invalid LZMA properties byte');
      }
      positionBits = properties ~/ 45;
      properties -= positionBits * 45;
      literalPositionBits = properties ~/ 9;
      literalContextBits = properties - literalPositionBits * 9;
      if (literalContextBits + literalPositionBits > 4) {
        throw ArchiveException(
            'xz: invalid LZMA literal context and position bits');
      }
    }
    skip(need);
    if (reset > 0) {
      _decoder.reset(
          literalContextBits: literalContextBits,
          literalPositionBits: literalPositionBits,
          positionBits: positionBits,
          resetDictionary: reset == 3);
    }
    _stage = _Stage.chunkBody;
    return true;
  }

  void _readChunkBody() {
    final body = InputMemoryStream(view(_chunkCompressedLength));
    if (_chunkControl < 0x80) {
      // What comes back is a view of the piece that arrived, so it is copied
      // out like everything else: the caller owns that buffer again the moment
      // the call returns
      _sink.writeBytes(
          _decoder.decodeUncompressed(body, _chunkUncompressedLength));
    } else {
      _decoder.decodeToOutput(body, _chunkUncompressedLength, _sink);
      if (!_decoder.isRangeCoderFinished) {
        throw ArchiveException('xz: LZMA data is corrupt');
      }
    }
    _decoder.trimDictionary(_dictionarySize);
    skip(_chunkCompressedLength);
    _stage = _Stage.chunkControl;
  }

  void _finishBlockData() {
    _decoder.reset(resetDictionary: true);
    final compressed = _streamPosition - _blockDataStart;
    final uncompressed = _sink.written;
    final declaredCompressed = _declaredCompressedLength;
    if (declaredCompressed != null && declaredCompressed != compressed) {
      throw ArchiveException(
          "xz: compressed data doesn't match the length in the block header");
    }
    final declaredUncompressed = _declaredUncompressedLength;
    if (declaredUncompressed != null && declaredUncompressed != uncompressed) {
      throw ArchiveException(
          "xz: uncompressed data doesn't match the length in the block header");
    }
    _stage = _Stage.blockPadding;
  }

  void _readBlockCheck(int size) {
    final checkType = _streamFlags & 0xf;
    final field = view(size);

    // The check covers what the filters leave, so a filtered block is checked
    // once it has been read back and filtered
    final buffered = _blockBuffer;
    Uint8List? filtered;
    if (buffered != null) {
      filtered = buffered.getBytes();
      bcjX86Decode(filtered, _x86StartOffset);
    }

    if (verify && checkType == 0x1) {
      final expected = field[0] |
          (field[1] << 8) |
          (field[2] << 16) |
          (field[3] << 24);
      final actual = filtered != null ? getCrc32(filtered) : _blockCrc32;
      if (actual != expected) {
        throw ArchiveException('xz: CRC32 check failed');
      }
    } else if (verify && checkType == 0x4) {
      final actual =
          filtered != null ? (Crc64()..update(filtered)) : _blockCrc64;
      if (!actual.matches(field, 0)) {
        throw ArchiveException('xz: CRC64 check failed');
      }
    }
    skip(size);

    _blockLength = _sink.written;
    if (filtered != null) {
      output.add(filtered);
      _blockBuffer = null;
      _sink.divert = null;
    }
    _sink.watch = null;
    // A finished block goes out now rather than waiting in the sink: the input
    // may say nothing more for a long time without closing, and a block handed
    // to a worker next is written out behind this one
    _sink.flush();

    // What the index records is the block without its padding: the header, the
    // data and the check
    _blocks.add(_BlockSize(_streamPosition - _blockStart - _blockPadding,
        _blockLength));
    _stage = _Stage.blockOrIndex;
  }

  bool _readIndexHeader() {
    final reader = _ByteReader(view(available), 0);
    reader.byte();
    final records = reader.tryMultibyte();
    if (records == null) {
      return false;
    }
    if (records != _blocks.length) {
      throw ArchiveException('xz: stream index block count mismatch');
    }
    _indexRecords = records;
    _indexRead = 0;
    _indexCrc = getCrc32(view(reader.at));
    skip(reader.at);
    _stage = _Stage.indexRecords;
    return true;
  }

  bool _readIndexRecords() {
    while (_indexRead < _indexRecords) {
      final reader = _ByteReader(view(available), 0);
      final unpadded = reader.tryMultibyte();
      if (unpadded == null) {
        return false;
      }
      final uncompressed = reader.tryMultibyte();
      if (uncompressed == null) {
        return false;
      }
      final block = _blocks[_indexRead];
      if (block.unpadded != unpadded) {
        throw ArchiveException('xz: stream index compressed length mismatch');
      }
      if (block.uncompressed != uncompressed) {
        throw ArchiveException('xz: stream index uncompressed length mismatch');
      }
      _indexCrc = getCrc32(view(reader.at), _indexCrc);
      skip(reader.at);
      _indexRead++;
    }
    _stage = _Stage.indexPadding;
    return true;
  }

  void _readStreamFooter() {
    final crc = _readUint32();
    final footer = view(6);
    if (getCrc32(footer) != crc) {
      throw ArchiveException('xz: invalid stream footer CRC checksum');
    }
    final backwardSize = ((footer[0] |
                (footer[1] << 8) |
                (footer[2] << 16) |
                (footer[3] << 24)) +
            1) *
        4;
    if (backwardSize != _indexSize) {
      throw ArchiveException('xz: stream footer has invalid index size');
    }
    if (footer[4] != 0) {
      throw ArchiveException('xz: invalid stream footer flags');
    }
    if (footer[5] != _streamFlags) {
      throw ArchiveException(
          "xz: stream footer flags don't match the header flags");
    }
    skip(6);
    final magic = view(2);
    if (magic[0] != 89 || magic[1] != 90) {
      throw ArchiveException('xz: invalid stream footer signature');
    }
    skip(2);
    _stage = _Stage.streamPadding;
  }

  static int _checkSize(int type) {
    if (type == 0) {
      return 0;
    }
    if (type <= 0x3) {
      return 4;
    }
    if (type <= 0x6) {
      return 8;
    }
    if (type <= 0x9) {
      return 16;
    }
    if (type <= 0xc) {
      return 32;
    }
    return 64;
  }
}

/// Reads the fields of a header out of a buffer that already holds all of it
class _ByteReader {
  final Uint8List _bytes;
  final int _end;
  int at;

  _ByteReader(this._bytes, this.at, [int? end]) : _end = end ?? _bytes.length;

  int byte() {
    if (at >= _end) {
      throw ArchiveException('xz: a header field is truncated');
    }
    return _bytes[at++];
  }

  Uint8List bytes(int count) {
    if (at + count > _end) {
      throw ArchiveException('xz: a header field is truncated');
    }
    final view = Uint8List.sublistView(_bytes, at, at + count);
    at += count;
    return view;
  }

  int multibyte() {
    final value = tryMultibyte();
    if (value == null) {
      throw ArchiveException('xz: a header field is truncated');
    }
    return value;
  }

  /// Null when the bytes for it have not arrived, which is what lets the index
  /// be read out of whatever has been handed over so far
  int? tryMultibyte() {
    var value = 0;
    var multiplier = 1;
    for (var i = 0; i < 9; i++) {
      if (at + i >= _end) {
        return null;
      }
      final data = _bytes[at + i];
      value += (data & 0x7f) * multiplier;
      if (data & 0x80 == 0) {
        at += i + 1;
        return value;
      }
      multiplier *= 128;
    }
    throw ArchiveException('xz: invalid multibyte integer');
  }
}

class _BlockSize {
  final int unpadded;
  final int uncompressed;

  const _BlockSize(this.unpadded, this.uncompressed);
}

enum _Stage {
  streamHeader,
  blockOrIndex,
  blockHeader,
  chunkControl,
  chunkHeader,
  chunkBody,
  blockPadding,
  blockCheck,
  indexHeader,
  indexRecords,
  indexPadding,
  indexCrc,
  streamFooter,
  streamPadding,
}

/// Writes xz from a `Stream` of pieces into a `Stream` of pieces.
///
/// Nothing in the format needs the total size: a block header may leave its
/// lengths out, the index that carries them is written last, and the check is
/// folded in as the bytes go past. So the archive this writes is the archive
/// the whole input would have produced.
///
/// The data itself is stored rather than compressed, which is all
/// [XZEncoder] does today
class XzEncoderConverter extends ChunkedConverter {
  /// Which check the blocks carry
  final XZCheck check;

  const XzEncoderConverter({this.check = XZCheck.crc64});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      XzChunkedEncoder(
          sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
          check: check);
}

/// The sink behind [XzEncoderConverter]. What it holds is one LZMA2 chunk of
/// input, whatever the archive weighs
class XzChunkedEncoder extends ChunkedSink {
  final XZCheck check;

  XzChunkedEncoder(super.output, {this.check = XZCheck.crc64}) {
    // Refused here rather than at close, after the whole input went through
    if (check == XZCheck.sha256) {
      throw ArchiveException(
          'xz: a streamed archive cannot carry a SHA-256 check yet');
    }
  }

  late final _out = SinkOutputStream(output);

  var _started = false;
  var _blockStarted = false;
  var _blockHeaderLength = 0;
  var _dataLength = 0;
  var _uncompressed = 0;
  var _crc32 = 0;
  final _crc64 = Crc64();

  int get _flags => switch (check) {
        XZCheck.none => 0,
        XZCheck.crc32 => 0x1,
        XZCheck.crc64 => 0x4,
        XZCheck.sha256 => 0xa,
      };

  @override
  void step() {
    while (available >= _chunkMax) {
      _writeChunk(_chunkMax);
    }
  }

  @override
  void finish() {
    if (available > 0) {
      _writeChunk(available);
    }
    _writeStreamHeader();
    if (_blockStarted) {
      _out.writeByte(0); // LZMA2 end marker
      _dataLength++;
      _writeBlockEnd();
    }
    _writeIndexAndFooter();
    _out.flush();
  }

  void _writeChunk(int count) {
    _writeStreamHeader();
    _writeBlockHeader();
    final data = view(count);
    _fold(data);
    // Control 1 resets the dictionary, 2 carries the one before it on
    _out
      ..writeByte(_uncompressed == 0 ? 1 : 2)
      ..writeByte(((count - 1) >> 8) & 0xff)
      ..writeByte((count - 1) & 0xff)
      ..writeBytes(data);
    _dataLength += count + 3;
    _uncompressed += count;
    skip(count);
  }

  void _fold(Uint8List piece) {
    switch (check) {
      case XZCheck.crc32:
        _crc32 = getCrc32(piece, _crc32);
      case XZCheck.crc64:
        _crc64.update(piece);
      case XZCheck.none:
      case XZCheck.sha256:
        break;
    }
  }

  void _writeStreamHeader() {
    if (_started) {
      return;
    }
    _started = true;
    _out.writeBytes([253, 55, 122, 88, 90, 0]);
    final header = Uint8List.fromList([0, _flags]);
    _out
      ..writeBytes(header)
      ..writeUint32(getCrc32(header));
  }

  /// The header names no lengths, which is what lets a block be written before
  /// its size is known
  void _writeBlockHeader() {
    if (_blockStarted) {
      return;
    }
    _blockStarted = true;
    final filter = OutputMemoryStream()
      ..writeByte(0x21) // LZMA2
      ..writeByte(1) // one property byte
      ..writeByte(xzDictionarySizeValue(xzDefaultDictionarySize));
    var length = 6 + filter.length;
    while (length % 4 != 0) {
      length++;
    }
    final header = OutputMemoryStream()
      ..writeByte((length ~/ 4) - 1)
      ..writeByte(0) // one filter, no lengths
      ..writeBytes(filter.getBytes());
    while (header.length < length - 4) {
      header.writeByte(0);
    }
    final bytes = header.getBytes();
    _blockHeaderLength = length;
    _out
      ..writeBytes(bytes)
      ..writeUint32(getCrc32(bytes));
  }

  void _writeBlockEnd() {
    var padding = 0;
    while ((_blockHeaderLength + _dataLength + padding) % 4 != 0) {
      _out.writeByte(0);
      padding++;
    }
    var checkLength = 0;
    switch (check) {
      case XZCheck.none:
        break;
      case XZCheck.crc32:
        _out.writeUint32(_crc32);
        checkLength = 4;
      case XZCheck.crc64:
        _out.writeBytes(_crc64.bytes);
        checkLength = 8;
      case XZCheck.sha256:
        throw ArchiveException(
            'xz: a streamed archive cannot carry a SHA-256 check yet');
    }
    _blocks.add(
        _Record(_blockHeaderLength + _dataLength + checkLength, _uncompressed));
  }

  void _writeIndexAndFooter() {
    final index = OutputMemoryStream()
      ..writeByte(0)
      ..writeBytes(_multibyte(_blocks.length));
    for (final record in _blocks) {
      index
        ..writeBytes(_multibyte(record.unpadded))
        ..writeBytes(_multibyte(record.uncompressed));
    }
    while (index.length % 4 != 0) {
      index.writeByte(0);
    }
    final indexBytes = index.getBytes();
    _out
      ..writeBytes(indexBytes)
      ..writeUint32(getCrc32(indexBytes));

    final footer = OutputMemoryStream()
      ..writeUint32(((indexBytes.length + 4) ~/ 4) - 1)
      ..writeByte(0)
      ..writeByte(_flags);
    final footerBytes = footer.getBytes();
    _out
      ..writeUint32(getCrc32(footerBytes))
      ..writeBytes(footerBytes)
      ..writeBytes([89, 90]);
  }

  final _blocks = <_Record>[];

  /// Seven bits a byte, the lowest first, the top bit set while more follow
  static Uint8List _multibyte(int value) {
    final bytes = <int>[];
    var left = value;
    while (left >= 0x80) {
      bytes.add(0x80 | (left & 0x7f));
      left >>= 7;
    }
    bytes.add(left);
    return Uint8List.fromList(bytes);
  }
}

/// What one uncompressed LZMA2 chunk may carry
const _chunkMax = 1 << 16;

class _Record {
  final int unpadded;
  final int uncompressed;

  const _Record(this.unpadded, this.uncompressed);
}

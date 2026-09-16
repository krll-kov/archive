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
import 'xz_stream_decoder.dart';

/// Decodes xz from a `Stream` of pieces into a `Stream` of pieces:
///
/// ```dart
/// await for (final piece in file.openRead().transform(xzCodec.decoder)) {
///   ...
/// }
/// ```
///
/// The format does not care where the input is cut. Any pieces will do
class XzDecoderConverter extends ChunkedConverter {
  /// Checks the CRC of every block that carries one it can compute. On by
  /// default. A stream hands the compressed bytes on by the time the check
  /// would be made and there is no second chance at it
  final bool verify;

  /// Decodes blocks on isolates once this converter is bound to a stream. Only
  /// a block whose header declares both lengths can go to a worker. `xz`
  /// writes those in threaded mode. Any other block decodes here, once the
  /// blocks in front of it are out. `startChunkedConversion` cannot take this
  /// option. Its sink owes its output before it returns and a worker answers
  /// later
  final XZMultithreadOptions<Object?>? multithread;

  const XzDecoderConverter({this.verify = true, this.multithread});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) {
    if (multithread != null) {
      throw ArgumentError.value(
          multithread,
          'multithread',
          'Works through the converter bound to a stream only, since a sink owes '
              'its output before '
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
      // Not super.bind. That goes through startChunkedConversion and it
      // refuses the options this converter still carries
      yield* XzDecoderConverter(verify: verify).bind(stream);
      return;
    }
    yield* xzDecodeStreamMultithreaded(stream,
        verify: verify, workers: workers, memoryBudget: budget);
  }
}

/// xz for data that arrives in pieces, the way a `Stream` gives it.
///
/// Same shape as gzip in `dart:io`, one converter per direction. A pipeline
/// reads `stream.transform(xzCodec.decoder)`. A whole buffer reads
/// `xzCodec.decode(bytes)`
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

/// Decodes an xz archive that arrives in pieces, the way a `Stream` of bytes
/// gives it.
///
/// The pull decoder asks its input for the next field and blocks until it has
/// it. This one takes whatever arrived and stops at the first field that is
/// not there yet. Nothing waits inside the parse.
///
/// It moves one LZMA2 chunk at a time and the format caps a chunk at 64 KiB
/// compressed. It holds the dictionary the archive asks for plus one chunk,
/// however big the archive is
class XzChunkedDecoder extends ChunkedSink {
  /// Checks the CRC of every block that carries one it can compute, on by
  /// default for the reason [XzDecoderConverter.verify] gives
  final bool verify;

  /// Takes the blocks that can be decoded elsewhere. The threaded stream
  /// decoder shares this parse through it rather than repeating it
  final XzBlockDispatch? dispatch;

  /// Set while the parse waits for [dispatch] to go idle before a block it has
  /// to decode itself
  bool get waitingForIdle => _waitingForIdle;
  var _waitingForIdle = false;

  XzChunkedDecoder(super.output, {this.verify = true, this.dispatch}) {
    _sink = SinkOutputStream(output);
  }

  // The LZMA decoder, the block header parse and the LZMA2 chunk rules come
  // from the whole buffer decoder. The two cannot drift apart
  final _xz = XZStreamDecoder(maxPreallocateSize: 0);
  LzmaDecoder get _decoder => _xz.decoder;
  late final SinkOutputStream _sink;

  /// Where the parse is, and what the state it is in still needs
  _Stage _stage = _Stage.streamHeader;

  /// Position within the current stream. Block and index padding is aligned to
  /// it
  var _streamStart = 0;
  var _streamFlags = 0;
  final _blocks = <_BlockSize>[];

  /// The block being decoded
  var _blockStart = 0;
  var _blockDataStart = 0;

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
  var _chunkLength = 0;

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
  /// field is short. Every step commits only once it has all of its bytes. The
  /// next call starts where this one stopped
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
          if (available < _chunkLength) {
            return;
          }
          _readChunkBody();
        case _Stage.blockPadding:
          final pad = (4 - (_streamPosition & 3)) & 3;
          if (available < pad) {
            return;
          }
          final blockPad = view(pad);
          for (var i = 0; i < pad; i++) {
            if (blockPad[i] != 0) {
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
          final indexPad = view(pad);
          for (var i = 0; i < pad; i++) {
            if (indexPad[i] != 0) {
              throw ArchiveException('xz: invalid stream index padding');
            }
          }
          _indexCrc = getCrc32(indexPad, _indexCrc);
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
    final value =
        field[0] | (field[1] << 8) | (field[2] << 16) | (field[3] << 24);
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
    // reserved. A stream that sets any of it asks for something else
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
    _xz.failureReason = null;
    if (!_xz.readBlockHeader(InputMemoryStream(view(size)), size)) {
      throw ArchiveException('xz: ${_xz.failureReason}');
    }
    _declaredCompressedLength = _xz.blockCompressedLength;
    _declaredUncompressedLength = _xz.blockUncompressedLength;
    _dictionarySize = _xz.blockDictionarySize;
    _x86Filter = _xz.blockHasX86;
    _x86StartOffset = _xz.blockX86StartOffset;

    final dispatch = this.dispatch;
    if (dispatch != null) {
      _waitingForIdle = false;
      final compressed = _declaredCompressedLength;
      final uncompressed = _declaredUncompressedLength;
      // Past the limit a claimed length would make the parse hold the rest of
      // the stream while it waits. Such a block decodes here instead
      final limit = dispatch.maxBlockBytes;
      if (compressed != null &&
          uncompressed != null &&
          compressed <= limit &&
          uncompressed <= limit) {
        final checkSize = _checkSize(_streamFlags & 0xf);
        final total = size +
            compressed +
            ((4 - ((size + compressed) & 3)) & 3) +
            checkSize;
        if (available < total) {
          return false;
        }
        dispatch.block(Uint8List.fromList(view(total)), _streamFlags,
            uncompressed, _dictionarySize);
        // The worker holds the block to its declared lengths. The index is
        // checked against those
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

    skip(size);

    // The x86 filter reads the block back. That block alone is held. Every
    // other block is handed to the sink as its chunks come out
    _blockBuffer = _x86Filter ? OutputMemoryStream() : null;
    // A filtered block is checked over what the filter leaves. The running
    // check is only worth keeping for a block that goes straight out
    _sink
      ..reset()
      ..divert = _blockBuffer;
    _blockCrc32 = 0;
    _blockCrc64.reset();
    _sink.watch = verify && !_x86Filter ? _foldCheck : null;
    _blockDataStart = _streamPosition;
    _xz.needDictionaryReset = true;
    _xz.needProperties = true;
    _stage = _Stage.chunkControl;
    return true;
  }

  void _readChunkControl() {
    _chunkControl = view(1)[0];
    if (_chunkControl == 0) {
      skip(1);
      _finishBlockData();
      return;
    }
    if (_chunkControl > 2 && _chunkControl < 0x80) {
      throw ArchiveException('xz: unknown LZMA2 control code $_chunkControl');
    }
    _stage = _Stage.chunkHeader;
  }

  /// Waits for the lengths. The whole chunk then goes to
  /// [XZStreamDecoder.readLZMA2Chunk] at once
  bool _readChunkHeader() {
    final need = _chunkControl < 0x80
        ? 3
        : ((_chunkControl >> 5) & 0x3) >= 2
            ? 6
            : 5;
    if (available < need) {
      return false;
    }
    final field = view(need);
    _chunkLength = _chunkControl < 0x80
        ? need + ((field[1] << 8) | field[2]) + 1
        : need + ((field[3] << 8) | field[4]) + 1;
    _stage = _Stage.chunkBody;
    return true;
  }

  void _readChunkBody() {
    _xz.failureReason = null;
    final done = _xz.readLZMA2Chunk(
        InputMemoryStream(view(_chunkLength)), _sink, _dictionarySize);
    if (done == false) {
      throw ArchiveException('xz: ${_xz.failureReason}');
    }
    skip(_chunkLength);
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

    // The check covers what the filters leave. A filtered block is checked
    // once it has been read back and filtered
    final buffered = _blockBuffer;
    Uint8List? filtered;
    if (buffered != null) {
      filtered = buffered.getBytes();
      bcjX86Decode(filtered, _x86StartOffset);
    }

    if (verify && checkType == 0x1) {
      final expected =
          field[0] | (field[1] << 8) | (field[2] << 16) | (field[3] << 24);
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
    _blocks.add(_BlockSize(
        _streamPosition - _blockStart - _blockPadding, _blockLength));
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

  /// Null when the bytes for it have not arrived. The index is read out of
  /// whatever has been handed over so far
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
/// Nothing in the format needs the total size. A block header may leave its
/// lengths out, the index that carries them comes last, and the check is folded
/// in as the bytes go past. This writes the same archive as the whole input
/// would have.
///
/// It stores the data rather than compressing it. That is all [XZEncoder] does
/// today
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

  /// The header names no lengths. A block is written before its size is known
  /// that way
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

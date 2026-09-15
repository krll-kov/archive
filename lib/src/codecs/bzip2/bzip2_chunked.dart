import 'dart:convert';
import 'dart:typed_data';

import '../../util/archive_exception.dart';
import '../../util/chunked_sink.dart';
import '../../util/input_memory_stream.dart';
import '../../util/output_memory_stream.dart';
import '../bzip2_decoder.dart';
import '../bzip2_encoder.dart';
import 'bz2_bit_reader.dart';
import 'bzip2.dart';

/// bzip2 for data that arrives in pieces, the way a `Stream` gives it. The
/// shape is the one `dart:io` uses for gzip, one converter per direction
class BZip2Codec extends Codec<List<int>, List<int>> {
  /// Checks the CRC of every block and of the stream. On by default: a caller
  /// reading a stream has handed the compressed bytes back by the time the
  /// check would be made, so there is no second chance at it
  final bool verify;

  /// Hundreds of thousands of bytes a block, one to nine
  final int blockSize100k;

  const BZip2Codec({this.verify = true, this.blockSize100k = 9});

  @override
  BZip2DecoderConverter get decoder => BZip2DecoderConverter(verify: verify);

  @override
  BZip2EncoderConverter get encoder =>
      BZip2EncoderConverter(blockSize100k: blockSize100k);
}

/// The codec with its defaults, for `stream.transform(bzip2Codec.decoder)`
const bzip2Codec = BZip2Codec();

/// Decodes bzip2 from a `Stream` of pieces into a `Stream` of pieces
class BZip2DecoderConverter extends ChunkedConverter {
  final bool verify;

  const BZip2DecoderConverter({this.verify = true});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      BZip2ChunkedDecoder(
          sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
          verify: verify);
}

/// Writes bzip2 from a `Stream` of pieces into a `Stream` of pieces
class BZip2EncoderConverter extends ChunkedConverter {
  final int blockSize100k;

  const BZip2EncoderConverter({this.blockSize100k = 9});

  @override
  ByteConversionSink startChunkedConversion(Sink<List<int>> sink) =>
      BZip2ChunkedEncoder(
          sink is ByteConversionSink ? sink : ByteConversionSink.from(sink),
          blockSize100k: blockSize100k);
}

/// Writes a bzip2 archive over data that arrives in pieces.
///
/// A block is filled a byte at a time and coded once it is full. [BZip2Encoder]
/// does the same with the bytes it pulls, so the archive this writes is
/// the one `encodeBytes` writes for the same input. What it holds is one
/// block, whatever the input weighs
class BZip2ChunkedEncoder extends ChunkedSink {
  final int blockSize100k;

  BZip2ChunkedEncoder(super.output, {this.blockSize100k = 9}) {
    if (blockSize100k < 1 || blockSize100k > 9) {
      throw ArchiveException(
          'bzip2: a block is one to nine hundred thousand bytes, not '
          '$blockSize100k');
    }
  }

  late final _out = SinkOutputStream(output);
  final _encoder = BZip2Encoder();
  var _started = false;

  @override
  void step() {
    _begin();
    while (available > 0) {
      final piece = view(available);
      var at = 0;
      var full = false;
      while (at < piece.length && !full) {
        full = _encoder.addByte(piece[at]);
        at++;
      }
      skip(at);
      if (full) {
        _endBlock();
      }
    }
  }

  @override
  void finish() {
    _begin();
    // A block no byte reached writes nothing, so this is the last one or it is
    // not there at all
    _endBlock();
    _encoder.endStream();
    _out.flush();
  }

  void _endBlock() {
    if (!_encoder.endBlock()) {
      throw ArchiveException('bzip2: a block could not be coded');
    }
  }

  void _begin() {
    if (_started) {
      return;
    }
    _started = true;
    _encoder.beginStream(_out, blockSize100k: blockSize100k);
  }
}

/// Decodes a bzip2 archive that arrives in pieces.
///
/// The format is a bit stream: a block does not start on a byte boundary and
/// carries no length, so the only way to know it is all here is to find the
/// marker that follows it. One block of input and one of output is what this
/// holds, whatever the archive weighs.
///
/// A marker can also turn up inside a block by chance. The decode of that block
/// then runs out of input, and the scan carries on to the next marker. So the
/// block's output is held back until it is whole
class BZip2ChunkedDecoder extends ChunkedSink {
  final bool verify;

  BZip2ChunkedDecoder(super.output, {this.verify = true});

  late final _sink = SinkOutputStream(output);
  final _decoder = BZip2Decoder();

  _Stage _stage = _Stage.signature;

  /// Where the parse is, as a bit offset into what has arrived and not been
  /// read. Whole bytes behind it are dropped once a block is done
  var _bitAt = 0;

  final _scan = Bz2MarkerScan();

  var _combinedCrc = 0;
  var _storedBlockCrc = 0;
  var _streams = 0;

  @override
  void step() {
    while (true) {
      switch (_stage) {
        case _Stage.signature:
          if (available < 4) {
            // Refused on the first byte that is not the signature, not waited on
            final head = view(available);
            for (var i = 0; i < head.length; i++) {
              if (head[i] != BZip2.bzhSignature[i]) {
                throw ArchiveException('bzip2: not a bzip2 archive');
              }
            }
            return;
          }
          _readSignature();
        case _Stage.blockMarker:
          if (!_has(48)) {
            return;
          }
          _readBlockMarker();
        case _Stage.blockCrc:
          if (!_has(32)) {
            return;
          }
          _storedBlockCrc = _readBits(32);
          // The block runs from here to the next marker. The search for one
          // starts here too
          _resetScan();
          _stage = _Stage.blockBody;
        case _Stage.blockBody:
          if (!_readBlockBody()) {
            return;
          }
        case _Stage.streamCrc:
          if (!_has(32)) {
            return;
          }
          _readStreamCrc();
        case _Stage.streamEnd:
          // Another archive may follow this one. `bzip2 -d` reads two files
          // concatenated that way. Only the end of the input says so
          if (available == 0) {
            return;
          }
          _stage = _Stage.signature;
      }
    }
  }

  @override
  void finish() {
    if (_stage != _Stage.streamEnd || available != 0) {
      throw ArchiveException('bzip2: the archive ended part way through');
    }
    if (_streams == 0) {
      throw ArchiveException('bzip2: no archive, the input is empty');
    }
    _sink.flush();
  }

  /// True while [count] bits are here to be read at [_bitAt]
  bool _has(int count) => (_bitAt + count + 7) >> 3 <= available;

  /// Takes [count] bits, at most 32, and moves past them
  int _readBits(int count) {
    final bytes = view(available);
    var value = 0;
    for (var i = 0; i < count; i++) {
      final at = _bitAt + i;
      value = ((value << 1) | ((bytes[at >> 3] >> (7 - (at & 7))) & 1)) &
          0xffffffff;
    }
    _bitAt += count;
    return value;
  }

  void _readSignature() {
    final field = view(4);
    if (field[0] != BZip2.bzhSignature[0] ||
        field[1] != BZip2.bzhSignature[1] ||
        field[2] != BZip2.bzhSignature[2]) {
      throw ArchiveException('bzip2: not a bzip2 archive');
    }
    final blockSize100k = field[3] - BZip2.hdr0;
    if (blockSize100k < 1 || blockSize100k > 9) {
      throw ArchiveException('bzip2: the signature names no valid block size');
    }
    skip(4);
    _decoder.beginStream(blockSize100k);
    _combinedCrc = 0;
    _bitAt = 0;
    _resetScan();
    _stage = _Stage.blockMarker;
  }

  void _readBlockMarker() {
    final high = _readBits(24);
    final low = _readBits(24);
    if (high == _compressedHigh && low == _compressedLow) {
      _stage = _Stage.blockCrc;
      return;
    }
    if (high == _eosHigh && low == _eosLow) {
      _stage = _Stage.streamCrc;
      return;
    }
    throw ArchiveException('bzip2: a block carries no valid marker');
  }

  /// Decodes the block that starts at [_bitAt], once the marker that ends it
  /// has been found. False while either is still to arrive
  bool _readBlockBody() {
    while (true) {
      if (!_scan.locate(view(available), available)) {
        return false;
      }
      final held = OutputMemoryStream();
      _sink.divert = held;
      var crc = 0;
      try {
        crc = _decodeInto();
      } on _NeedMore {
        // The marker was one the block's own data happened to spell, so the
        // block runs past it and the next one is the candidate. The window
        // slides on one bit, so a marker right after it or across it is found
        _sink.divert = null;
        continue;
      } finally {
        _sink.divert = null;
      }
      if (crc < 0) {
        throw ArchiveException('bzip2: a block is malformed');
      }
      if (verify && crc != _storedBlockCrc) {
        throw ArchiveException('bzip2: block checksum does not match');
      }
      _combinedCrc = ((_combinedCrc << 1) | (_combinedCrc >> 31)) & 0xffffffff;
      _combinedCrc ^= crc;
      _emit(held.getBytes());
      _drop();
      _stage = _Stage.blockMarker;
      return true;
    }
  }

  /// Runs the block decoder over everything that has arrived, and leaves
  /// [_bitAt] on the bit that follows the block
  int _decodeInto() {
    final bytes = view(available);
    final from = _bitAt >> 3;
    final input = _BitInput(Uint8List.sublistView(bytes, from));
    final reader = Bz2BitReader(input);
    final offset = _bitAt & 7;
    if (offset > 0) {
      reader.readBits(offset);
    }
    final crc = _decoder.decodeBlock(reader, _sink);
    _bitAt = (from << 3) + (input.position << 3) - reader.bitsLeft;
    return crc;
  }

  void _readStreamCrc() {
    final stored = _readBits(32);
    if (verify && stored != _combinedCrc) {
      throw ArchiveException('bzip2: stream checksum does not match');
    }
    // What follows the check is padding to the end of the byte, and then
    // whatever the input carries next
    _bitAt = (_bitAt + 7) & ~7;
    _drop();
    _streams++;
    _stage = _Stage.streamEnd;
  }

  /// A block's own run coding can turn 900 KiB into tens of megabytes, so what
  /// it decoded to goes out in pieces the size the other codecs here hand over
  void _emit(Uint8List bytes) {
    for (var at = 0; at < bytes.length; at += _piece) {
      final end = at + _piece < bytes.length ? at + _piece : bytes.length;
      output.add(Uint8List.sublistView(bytes, at, end));
    }
  }

  /// Drops the whole bytes the parse has left behind
  void _drop() {
    final bytes = _bitAt >> 3;
    if (bytes > 0) {
      skip(bytes);
      _bitAt -= bytes << 3;
    }
    _resetScan();
  }

  void _resetScan() {
    _scan.start(_bitAt);
  }
}

/// Finds the marker that ends a bzip2 block or a stream, in bits that arrive in
/// pieces
class Bz2MarkerScan {
  /// Where the search for the next marker has reached, and the last 48 bits it
  /// has seen, held as two halves so that the shifts stay inside 32 bits
  var _scanAt = 0;
  var _scanHigh = 0;
  var _scanLow = 0;
  var _scanFilled = 0;

  /// The bit after the last one [locate] read
  int get position => _scanAt;

  /// Starts the search at bit [at] with nothing seen
  void start(int at) {
    _scanAt = at;
    _resetRegister();
  }

  void _resetRegister() {
    _scanHigh = 0;
    _scanLow = 0;
    _scanFilled = 0;
  }

  /// Walks the bits from where the last search stopped, looking for either
  /// marker. False while neither has arrived
  bool locate(Uint8List bytes, int available) {
    final end = available << 3;
    while (_scanAt < end) {
      final bit = (bytes[_scanAt >> 3] >> (7 - (_scanAt & 7))) & 1;
      _scanHigh = ((_scanHigh << 1) | (_scanLow >> 23)) & 0xffffff;
      _scanLow = ((_scanLow << 1) | bit) & 0xffffff;
      _scanAt++;
      if (_scanFilled < 48) {
        _scanFilled++;
        // The 48th bit completes the first window, so that one is compared too
        if (_scanFilled < 48) {
          continue;
        }
      }
      if ((_scanHigh == _compressedHigh && _scanLow == _compressedLow) ||
          (_scanHigh == _eosHigh && _scanLow == _eosLow)) {
        return true;
      }
    }
    return false;
  }
}

const _compressedHigh = 0x314159;
const _compressedLow = 0x265359;
const _eosHigh = 0x177245;
const _eosLow = 0x385090;

/// Raised where the block decoder reads past what has arrived
class _NeedMore implements Exception {
  const _NeedMore();
}

class _BitInput extends InputMemoryStream {
  _BitInput(super.bytes);

  @override
  int readByte() {
    if (isEOS) {
      throw const _NeedMore();
    }
    return super.readByte();
  }
}

/// What one hand over carries. gzip and xz hand over the same
const _piece = 1 << 16;

enum _Stage {
  signature,
  blockMarker,
  blockCrc,
  blockBody,
  streamCrc,
  streamEnd,
}

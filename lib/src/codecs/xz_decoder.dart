import 'dart:typed_data';

import '../util/crc32.dart';
import '../util/crc64.dart';
import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'bcj_x86.dart';
import 'lzma/lzma_decoder.dart';

// The XZ specification can be found at
// https://tukaani.org/xz/xz-file-format.txt.

/// Decompress data with the xz format decoder.
class XZDecoder {
  Uint8List decodeBytes(List<int> data, {bool verify = false}) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    // The stream indexes give the output size up front, which avoids growing
    // the output buffer while decoding. A zero size is left to the default
    // because the buffer cannot grow out of an empty allocation.
    final int? size = _uSize(bytes);
    final OutputMemoryStream output =
        OutputMemoryStream(size: size != null && size > 0 ? size : null);

    decodeStream(InputMemoryStream(bytes), output, verify: verify);
    return output.getBytes();
  }

  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false}) {
    final decoder = _XZStreamDecoder(verify: verify);
    return decoder.decode(input, output);
  }

  /// Gets uncompressed size of XZ archive, if it's valid. When archive
  /// is not valid, return value is null. May be used with [decodeStream]
  /// for memory efficieny.
  ///
  /// ```dart
  /// final Uint8List from = Uint8List(0); // your archive
  /// final OutputMemoryStream output = OutputMemoryStream(size: const XZDecoder().uncompressedSize(from));
  /// final bool ok = XZDecoder().decodeStream(InputMemoryStream(from), output);
  /// if (!ok) throw 'XZ decode failed';
  /// return output.getBytes();
  /// ```
  int? uncompressedSize(List<int> data) =>
      _uSize(data is Uint8List ? data : Uint8List.fromList(data));
}

/// Decodes an XZ stream.
class _XZStreamDecoder {
  // True if checksums are confirmed.
  final bool verify;

  // LZMA decoder.
  final decoder = LzmaDecoder();

  // Stream flags, which are sent in both the header and the footer.
  var streamFlags = 0;

  // Block sizes.
  final _blockSizes = <_XZBlockSize>[];

  // Position of the start of the stream being decoded. Padding inside a stream
  // is aligned to this, not to the start of [input], which may have been
  // positioned elsewhere by the caller.
  var _streamStart = 0;

  _XZStreamDecoder({this.verify = false});

  /// Decode this stream and return the uncompressed data.
  bool decode(InputStream input, OutputStream output) {
    while (true) {
      if (!_decodeStream(input, output)) {
        return false;
      }

      // Streams can be concatenated, and each one may be followed by padding.
      if (!_skipStreamPadding(input)) {
        return false;
      }
      if (input.isEOS) {
        return true;
      }
    }
  }

  // Decodes a single stream from [input].
  bool _decodeStream(InputStream input, OutputStream output) {
    // Each stream has its own flags, block list and dictionary.
    _streamStart = input.position;
    streamFlags = 0;
    _blockSizes.clear();
    decoder.dictionaryCap = 0;
    decoder.reset(resetDictionary: true);

    if (!_readStreamHeader(input, output)) {
      return false;
    }

    while (!input.isEOS) {
      final blockHeader = input.peekBytes(1).readByte();

      if (blockHeader == 0) {
        final indexSize = _readStreamIndex(input);
        if (indexSize < 0) {
          return false;
        }
        return _readStreamFooter(input, indexSize);
      }

      final blockLength = (blockHeader + 1) * 4;
      if (!_readBlock(input, output, blockLength)) {
        return false;
      }
    }

    // Valid XZ always goes trough _readStreamFooter
    return false;
  }

  // Skips the padding that may follow a stream. Padding is zero bytes in
  // multiples of four, and is followed by another stream or the end of the
  // input.
  bool _skipStreamPadding(InputStream input) {
    var count = 0;
    while (!input.isEOS) {
      if (input.peekBytes(1).readByte() != 0) {
        break;
      }
      input.skip(1);
      count++;
    }
    return count % 4 == 0;
  }

  // Reads an XZ steam header from [input].
  bool _readStreamHeader(InputStream input, OutputStream output) {
    final magic = input.readBytes(6).toUint8List();
    final magicIsValid = magic[0] == 253 &&
        magic[1] == 55 /* '7' */ &&
        magic[2] == 122 /* 'z' */ &&
        magic[3] == 88 /* 'X' */ &&
        magic[4] == 90 /* 'Z' */ &&
        magic[5] == 0;
    if (!magicIsValid) {
      return false;
      //throw ArchiveException('Invalid XZ stream header signature');
    }

    final header = input.readBytes(2);
    if (header.readByte() != 0) {
      return false;
      //throw ArchiveException('Invalid stream flags');
    }
    streamFlags = header.readByte();
    header.reset();

    final crc = input.readUint32();
    if (getCrc32(header.toUint8List()) != crc) {
      return false;
      //throw ArchiveException('Invalid stream header CRC checksum');
    }

    return true;
  }

  // Reads a data block from [input].
  bool _readBlock(InputStream input, OutputStream output, int headerLength) {
    final blockStart = input.position;
    final header = input.readBytes(headerLength - 4);

    header.skip(1); // Skip length field
    final blockFlags = header.readByte();
    final nFilters = (blockFlags & 0x3) + 1;
    final hasCompressedLength = blockFlags & 0x40 != 0;
    final hasUncompressedLength = blockFlags & 0x80 != 0;

    int? compressedLength;
    if (hasCompressedLength) {
      compressedLength = _readMultibyteInteger(header);
    }
    int? uncompressedLength;
    if (hasUncompressedLength) {
      uncompressedLength = _readMultibyteInteger(header);
    }

    final filters = <int>[];
    var dictionarySize = 0;

    for (var i = 0; i < nFilters; i++) {
      final id = _readMultibyteInteger(header);
      final propertiesLength = _readMultibyteInteger(header);
      final properties = header.readBytes(propertiesLength).toUint8List();
      if (id == 0x03) {
        // delta filter
        final distance = properties[0];
        filters.add(id);
        filters.add(distance);
      } else if (id == 0x04) {
        // x86 BCJ filter
        var startOffset = 0;
        if (propertiesLength == 4) {
          startOffset = properties[0] |
              properties[1] << 8 |
              properties[2] << 16 |
              properties[3] << 24;
        }
        filters.add(id);
        filters.add(startOffset);
      } else if (id == 0x21) {
        // lzma2 filter
        final v = properties[0];
        if (v > 40) {
          return false;
          //throw ArchiveException('Invalid LZMA dictionary size');
        } else if (v == 40) {
          dictionarySize = 0xffffffff;
        } else {
          final mantissa = 2 | (v & 0x1);
          final exponent = (v >> 1) + 11;
          dictionarySize = mantissa << exponent;
        }
        filters.add(id);
        filters.add(dictionarySize);
      } else {
        filters.add(id);
        filters.add(0);
      }
    }

    if (dictionarySize > 0 && dictionarySize < 0x40000000) {
      decoder.dictionaryCap =
          dictionarySize + (dictionarySize >> 2) + (2 << 20) + 16;
    }

    if (_readPadding(header) < 0) {
      return false;
    }
    header.reset();

    final crc = input.readUint32();
    if (getCrc32(header.toUint8List()) != crc) {
      return false;
      //throw ArchiveException('Invalid block CRC checksum');
    }

    // Entries are stored as (id, value) pairs. The supported chains are LZMA2
    // on its own, or the x86 BCJ filter followed by LZMA2.
    final hasX86 =
        filters.length == 4 && filters[0] == 0x04 && filters[2] == 0x21;
    if (!hasX86 && (filters.length != 2 || filters.first != 0x21)) {
      return false;
    }
    final x86StartOffset = hasX86 ? filters[1] : 0;

    final startPosition = input.position;
    final startDataLength = output.length;

    // The decoded block is needed again when a filter has to be applied or a
    // checksum verified.
    final checkType = streamFlags & 0xf;
    final needsBlockData = hasX86 ||
        (verify &&
            (checkType == 0x1 || (checkType == 0x4 && isCrc64Supported())));
    Uint8List? blockData;

    if (needsBlockData && output is! OutputMemoryStream) {
      // Streams that are not backed by a contiguous buffer cannot be read back
      // after the data has been written, so the block is decoded into a
      // temporary buffer and appended afterwards.
      final block = OutputMemoryStream(size: uncompressedLength);
      if (!_readLZMA2(input, block, dictionarySize)) {
        return false;
      }
      blockData = block.getBytes();
      if (hasX86) {
        bcjX86Decode(blockData, x86StartOffset);
      }
      output.writeBytes(blockData);
    } else {
      if (!_readLZMA2(input, output, dictionarySize)) {
        return false;
      }
      if (hasX86) {
        // subset() returns a view into the output buffer, so the filter is
        // applied in place without allocating a copy of the block.
        bcjX86Decode(output.subset(startDataLength), x86StartOffset);
      }
    }

    final actualCompressedLength = input.position - startPosition;
    final actualUncompressedLength = output.length - startDataLength;

    if (compressedLength != null &&
        compressedLength != actualCompressedLength) {
      return false;
      //throw ArchiveException("Compressed data doesn't match expected length");
    }

    uncompressedLength ??= actualUncompressedLength;
    if (uncompressedLength != actualUncompressedLength) {
      return false;
      //throw ArchiveException("Uncompressed data doesn't match expected length");
    }

    final paddingSize = _readPadding(input, _streamStart);
    if (paddingSize < 0) {
      return false;
    }

    // Checksum
    switch (checkType) {
      case 0: // none
        break;
      case 0x1: // CRC32
        final int expectedCrc = input.readUint32();
        if (verify &&
            getCrc32(blockData ?? output.subset(startDataLength)) !=
                expectedCrc) {
          return false;
        }
        break;
      case 0x2:
      case 0x3:
        input.skip(4);
        /*if (verify) {
          throw ArchiveException('Unknown check type $checkType');
        }*/
        break;
      case 0x4: // CRC64
        final int expectedCrc = input.readUint64();
        if (verify &&
            isCrc64Supported() &&
            getCrc64(blockData ?? output.subset(startDataLength)) !=
                expectedCrc) {
          return false;
        }
        break;
      case 0x5:
      case 0x6:
        input.skip(8);
        /*if (verify) {
          throw ArchiveException('Unknown check type $checkType');
        }*/
        break;
      case 0x7:
      case 0x8:
      case 0x9:
        input.skip(16);
        /*if (verify) {
          throw ArchiveException('Unknown check type $checkType');
        }*/
        break;
      case 0xa: // SHA-256
        /*final expectedCrc =*/
        input.readBytes(32).toUint8List();
        /*if (verify) {
          final actualCrc =
              sha256.convert(data.toBytes().sublist(startDataLength)).bytes;
          for (var i = 0; i < 32; i++) {
            if (actualCrc[i] != expectedCrc[i]) {
              throw ArchiveException('SHA-256 check failed');
            }
          }
        }*/
        break;
      case 0xb:
      case 0xc:
        input.skip(32);
        /*if (verify) {
          throw ArchiveException('Unknown check type $checkType');
        }*/
        break;
      case 0xd:
      case 0xe:
      case 0xf:
        input.skip(64);
        /*if (verify) {
          throw ArchiveException('Unknown check type $checkType');
        }*/
        break;
      default:
        //throw ArchiveException('Unknown block check type $checkType');
        return false;
    }

    final unpaddedLength = input.position - blockStart - paddingSize;
    _blockSizes.add(_XZBlockSize(unpaddedLength, uncompressedLength));

    return true;
  }

  // Reads LZMA2 data from [input].
  bool _readLZMA2(InputStream input, OutputStream output, int dictionarySize) {
    while (!input.isEOS) {
      final control = input.readByte();
      // Control values:
      // 00000000 - end marker
      // 00000001 - reset dictionary and uncompresed data
      // 00000010 - uncompressed data
      // 1rrxxxxx - LZMA data with reset (r) and high bits of size field (x)
      if (control & 0x80 == 0) {
        if (control == 0) {
          decoder.reset(resetDictionary: true);
          return true;
        } else if (control == 1) {
          decoder.reset(resetDictionary: true);
          final length = (input.readByte() << 8 | input.readByte()) + 1;
          output.writeBytes(
              decoder.decodeUncompressed(input.readBytes(length), length));
          decoder.trimDictionary(dictionarySize);
        } else if (control == 2) {
          // uncompressed data
          final length = (input.readByte() << 8 | input.readByte()) + 1;
          output.writeBytes(
              decoder.decodeUncompressed(input.readBytes(length), length));
          decoder.trimDictionary(dictionarySize);
        } else {
          return false;
          //throw ArchiveException('Unknown LZMA2 control code $control');
        }
      } else {
        // Reset flags:
        // 0 - reset nothing
        // 1 - reset state
        // 2 - reset state, properties
        // 3 - reset state, properties and dictionary
        final reset = (control >> 5) & 0x3;
        final uncompressedLength = ((control & 0x1f) << 16 |
                input.readByte() << 8 |
                input.readByte()) +
            1;
        final compressedLength = (input.readByte() << 8 | input.readByte()) + 1;
        int? literalContextBits;
        int? literalPositionBits;
        int? positionBits;
        if (reset >= 2) {
          // The three LZMA decoder properties are combined into a single number.
          var properties = input.readByte();
          if (properties > 224) {
            return false;
          }
          positionBits = properties ~/ 45;
          properties -= positionBits * 45;
          literalPositionBits = properties ~/ 9;
          literalContextBits = properties - literalPositionBits * 9;
          if (literalContextBits + literalPositionBits > 4) {
            return false;
          }
        }
        if (reset > 0) {
          decoder.reset(
              literalContextBits: literalContextBits,
              literalPositionBits: literalPositionBits,
              positionBits: positionBits,
              resetDictionary: reset == 3);
        }

        decoder.decodeToOutput(
            input.readBytes(compressedLength), uncompressedLength, output);
        decoder.trimDictionary(dictionarySize);
      }
    }

    // 00000000 - end marker, if not reached - there's an issue with file
    return false;
  }

  // Reads an XZ stream index from [input].
  // Returns the length of the index in bytes.
  int _readStreamIndex(InputStream input) {
    final startPosition = input.position;
    input.skip(1); // Skip index indicator
    final nRecords = _readMultibyteInteger(input);
    if (nRecords != _blockSizes.length) {
      return -1;
      //throw ArchiveException('Stream index block count mismatch');
    }

    for (var i = 0; i < nRecords; i++) {
      final unpaddedLength = _readMultibyteInteger(input);
      final uncompressedLength = _readMultibyteInteger(input);
      if (_blockSizes[i].unpaddedLength != unpaddedLength) {
        return -1;
        //throw ArchiveException('Stream index compressed length mismatch');
      }
      if (_blockSizes[i].uncompressedLength != uncompressedLength) {
        return -1;
        //throw ArchiveException('Stream index uncompressed length mismatch');
      }
    }
    if (_readPadding(input, _streamStart) < 0) {
      return -1;
    }

    // Re-read for CRC calculation
    final indexLength = input.position - startPosition;
    input.rewind(indexLength);
    final indexData = input.readBytes(indexLength);

    final crc = input.readUint32();
    if (getCrc32(indexData.toUint8List()) != crc) {
      return -1;
      //throw ArchiveException('Invalid stream index CRC checksum');
    }

    return indexLength + 4;
  }

  // Reads an XZ stream footer from [input] and check the index size matches
  // [indexSize].
  bool _readStreamFooter(InputStream input, int indexSize) {
    final crc = input.readUint32();
    final footer = input.readBytes(6);
    final backwardSize = (footer.readUint32() + 1) * 4;
    if (backwardSize != indexSize) {
      return false;
      //throw ArchiveException('Stream footer has invalid index size');
    }
    if (footer.readByte() != 0) {
      return false;
      //throw ArchiveException('Invalid stream flags');
    }
    final footerFlags = footer.readByte();
    if (footerFlags != streamFlags) {
      return false;
      //throw ArchiveException("Stream footer flags don't match header flags");
    }
    footer.reset();

    if (getCrc32(footer.toUint8List()) != crc) {
      return false;
      //throw ArchiveException('Invalid stream footer CRC checksum');
    }

    // The stream is invalid if at least one byte is corrupted.
    final magic = input.readBytes(2).toUint8List();
    if (magic[0] != 89 /* 'Y' */ || magic[1] != 90 /* 'Z' */) {
      return false;
      //throw ArchiveException('Invalid XZ stream footer signature');
    }

    return true;
  }

  // Reads a multibyte integer from [input].
  int _readMultibyteInteger(InputStream input) {
    var value = 0;
    var shift = 0;
    while (true) {
      final data = input.readByte();
      value |= (data & 0x7f) << shift;
      if (data & 0x80 == 0) {
        return value;
      }
      shift += 7;
    }
  }

  // Reads padding from [input] until the read position is aligned to a 4 byte
  // boundary. The padding bytes are confirmed to be zeros.
  // Returns he number of padding bytes.
  int _readPadding(InputStream input, [int origin = 0]) {
    var count = 0;
    while ((input.position - origin) % 4 != 0) {
      if (input.readByte() != 0) {
        return -1;
        //throw ArchiveException('Non-zero padding byte');
      }
      count++;
    }
    return count;
  }
}

// Information about a block size.
class _XZBlockSize {
  // The block size excluding padding.
  final int unpaddedLength;

  // The size of the data in the block when uncompressed.
  final int uncompressedLength;

  const _XZBlockSize(this.unpaddedLength, this.uncompressedLength);
}

// Largest size that is worth pre-allocating from a stream index. A valid index
// can describe an output that is much larger than the available memory, so
// anything above this is treated as unknown.
const _maxPreallocateSize = 1 << 31;

// Returns the offset of the start of the stream padding that ends at [end].
// Padding is zero bytes in multiples of four.
int _skipTrailingZeroPadding(Uint8List d, int end) {
  while (end >= 4 &&
      d[end - 1] == 0 &&
      d[end - 2] == 0 &&
      d[end - 3] == 0 &&
      d[end - 4] == 0) {
    end -= 4;
  }
  return end;
}

// Returns the total uncompressed size of every stream in [d], taken from the
// stream indexes, or null if it cannot be determined.
//
// This only sizes the output buffer up front, so anything unexpected makes it
// give up instead of failing: the data itself is validated by the decoder.
int? _uSize(Uint8List d) {
  try {
    var end = _skipTrailingZeroPadding(d, d.length);
    var total = 0;

    // Streams can be concatenated, so walk backwards from the last stream footer
    // to the first stream header.
    while (end > 0) {
      // Stream footer: CRC32 (4), backward size (4), stream flags (2), 'YZ' (2).
      if (end < 32 ||
          d[end - 2] != 89 /* 'Y' */ ||
          d[end - 1] != 90 /* 'Z' */) {
        return null;
      }
      final footerStart = end - 12;

      // Backward size holds the size of the index in four byte units, minus one.
      final backwardSize = d[footerStart + 4] |
          d[footerStart + 5] << 8 |
          d[footerStart + 6] << 16 |
          d[footerStart + 7] << 24;
      final indexSize = (backwardSize + 1) * 4;
      final indexStart = footerStart - indexSize;
      // The smallest index is eight bytes, and it is preceded by at least the
      // twelve byte stream header.
      if (indexSize < 8 || indexStart < 12 || d[indexStart] != 0) {
        return null;
      }

      // The index ends with the CRC32 of everything before it in the index.
      final crcStart = footerStart - 4;
      final storedCrc = d[crcStart] |
          d[crcStart + 1] << 8 |
          d[crcStart + 2] << 16 |
          d[crcStart + 3] << 24;
      if (getCrc32(Uint8List.sublistView(d, indexStart, crcStart)) !=
          storedCrc) {
        return null;
      }

      var position = indexStart + 1;
      // Reads a multibyte integer, returning -1 when it is malformed or runs past
      // the last record.
      int readMultibyteInteger() {
        var value = 0;
        var multiplier = 1;

        for (var i = 0; i < 9; i++) {
          if (position >= crcStart) {
            return -1;
          }

          final data = d[position++];
          value += (data & 0x7f) * multiplier;

          if ((data & 0x80) == 0) {
            return value;
          }

          multiplier *= 128;
        }
        return -1;
      }

      final recordCount = readMultibyteInteger();
      // Every record takes at least two bytes.
      if (recordCount < 0 || recordCount > (crcStart - position) ~/ 2) {
        return null;
      }

      var blocksSize = 0;
      for (var i = 0; i < recordCount; i++) {
        final unpaddedLength = readMultibyteInteger();
        final uncompressedLength = readMultibyteInteger();
        if (unpaddedLength <= 0 || uncompressedLength < 0) {
          return null;
        }
        // Blocks are padded to a four byte boundary.
        final paddedLength = (unpaddedLength + 3) & ~3;
        if (paddedLength < 0 || paddedLength < unpaddedLength) return null;
        blocksSize += paddedLength;
        if (blocksSize < 0) return null;

        total += uncompressedLength;
        if (blocksSize > indexStart || total > _maxPreallocateSize) {
          return null;
        }
      }

      // The twelve byte stream header sits in front of the blocks.
      final streamStart = indexStart - blocksSize - 12;
      if (streamStart < 0 ||
          streamStart + 5 >= d.length ||
          d[streamStart] != 253 ||
          d[streamStart + 1] != 55 /* '7' */ ||
          d[streamStart + 2] != 122 /* 'z' */ ||
          d[streamStart + 3] != 88 /* 'X' */ ||
          d[streamStart + 4] != 90 /* 'Z' */ ||
          d[streamStart + 5] != 0) {
        return null;
      }

      end = _skipTrailingZeroPadding(d, streamStart);
    }

    return total;
  } catch (_) {
    return null;
  }
}

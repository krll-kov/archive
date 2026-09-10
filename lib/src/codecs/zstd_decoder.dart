import 'dart:typed_data';

import '../util/archive_exception.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'zstd/zstd_constants.dart';
import 'zstd/zstd_dictionary.dart';
import 'zstd/zstd_frame_decoder.dart';
import 'zstd/zstd_window.dart';

/// Decompress data with the zstd format decoder.
class ZstdDecoder {
  /// Frames declaring a window above this are rejected rather than allocated
  /// for, since the header is only as trustworthy as whoever wrote the file.
  /// The format permits up to 3.75 TB; the default matches the reference
  /// decoder's own ceiling
  final int windowSizeLimit;

  /// Applied to every frame, whether or not the frame names a dictionary id.
  /// A frame that names one is rejected unless this dictionary carries it
  final ZstdDictionary? dictionary;

  ZstdDecoder({int? windowSizeLimit, this.dictionary})
      : windowSizeLimit = windowSizeLimit ?? zstdDefaultWindowSizeLimit {
    if (this.windowSizeLimit < 1024) {
      throw ArgumentError.value(windowSizeLimit, 'windowSizeLimit',
          'Must be at least the 1 KB minimum window');
    }
  }

  /// Decompress [data], which must hold whole frames. A malformed archive
  /// yields the frames that decoded whole before the failure, unless
  /// [throwOnError]. [verify] checks the checksum of every frame carrying one,
  /// at the cost of hashing the whole output
  Uint8List decodeBytes(List<int> data,
      {bool verify = false, bool throwOnError = false}) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    // One frame decodes into its own buffer and is handed back as a view of it.
    // Several would have to be joined afterwards, holding every frame and the
    // join at once, so they go through one sink instead
    if (_frameCount(bytes) > 1) {
      final sink = OutputMemoryStream();
      final total = uncompressedSize(bytes);
      if (total != null && total > 0) {
        sink.reserve(total);
      }
      try {
        _decode(bytes, verify, sink, null);
      } catch (error) {
        if (throwOnError) {
          throw ArchiveException('Invalid zstd archive: $error');
        }
      }
      return sink.getBytes();
    }
    final parts = <Uint8List>[];
    try {
      _decode(bytes, verify, null, parts);
    } catch (error) {
      if (throwOnError) {
        throw ArchiveException('Invalid zstd archive: $error');
      }
    }
    return parts.isEmpty ? Uint8List(0) : parts[0];
  }

  /// How many frames carry content, without decoding any of them. Anything the
  /// walk cannot make sense of reads as one, which keeps the decode itself the
  /// only place that reports a malformed archive
  int _frameCount(Uint8List bytes) {
    var at = 0;
    var frames = 0;
    try {
      while (at + 4 <= bytes.length) {
        final magic = _uint32At(bytes, at);
        if (magic >= zstdSkippableMagicMin && magic <= zstdSkippableMagicMax) {
          at += 8 + _uint32At(bytes, at + 4);
          continue;
        }
        if (magic != zstdMagic) {
          return 1;
        }
        final header =
            readFrameHeader(bytes, at + 4, bytes.length, windowSizeLimit);
        at = _skipFrame(bytes, at + 4 + header.size, header);
        frames++;
        if (frames > 1) {
          return frames;
        }
      }
    } catch (_) {
      return 1;
    }
    return frames;
  }

  /// Decompress [input] into [output], holding one block of the compressed
  /// side and a window of the result, whatever the archive weighs
  bool decodeStream(InputStream input, OutputStream output,
      {bool verify = false, bool throwOnError = false}) {
    try {
      _stream(input, output, verify);
      return true;
    } catch (error) {
      if (throwOnError) {
        throw ArchiveException('Invalid zstd archive: $error');
      }
      return false;
    }
  }

  /// Walks the frames of [input] a block at a time, so neither the compressed
  /// side nor the decoded one is ever held whole
  void _stream(InputStream input, OutputStream output, bool verify) {
    Uint8List? scratch;
    var frames = 0;
    while (!input.isEOS) {
      if (input.length < 4) {
        throw ZstdFrameException('Trailing bytes are not a frame');
      }
      final magic = _uint32At(input.peekBytes(4).toUint8List(), 0);
      if (magic >= zstdSkippableMagicMin && magic <= zstdSkippableMagicMax) {
        if (input.length < 8) {
          throw ZstdFrameException('Skippable frame header is truncated');
        }
        final size = _uint32At(input.peekBytes(8).toUint8List(), 4);
        if (input.length < 8 + size) {
          throw ZstdFrameException('Skippable frame is truncated');
        }
        input.skip(8 + size);
        continue;
      }
      if (magic != zstdMagic) {
        throw ZstdFrameException('Not a zstd frame');
      }

      // The longest header is the magic, the descriptor, a window byte, four
      // bytes of dictionary id and eight of content size
      final ahead = input.length < 18 ? input.length : 18;
      final front = input.peekBytes(ahead).toUint8List();
      final header = readFrameHeader(front, 4, ahead, windowSizeLimit);
      final dictionary = this.dictionary;
      if (header.dictionaryId != 0 &&
          (dictionary == null || dictionary.id != header.dictionaryId)) {
        throw ZstdFrameException(
            'Frame needs dictionary ${header.dictionaryId}');
      }
      input.skip(4 + header.size);

      final window = ZstdWindow(header.windowSize, output: output);
      if (dictionary != null && dictionary.content.isNotEmpty) {
        window.prime(dictionary.content);
      }
      // One block of compressed bytes plus its header, which is all the
      // decoder ever needs of the input at once
      scratch ??= Uint8List(zstdBlockMaximumSize + 3);
      if (scratch.length < header.blockSizeMax + 3) {
        scratch = Uint8List(header.blockSizeMax + 3);
      }
      ZstdFrameDecoder().decodeBlocksFrom(
          input, window, header, verify, dictionary, scratch);
      window.finish();
      frames++;
    }
    if (frames == 0) {
      throw ZstdFrameException('No frame: the input is empty');
    }
  }

  /// Reads the size the frames declare, or null when any of them does not
  /// say. It is a claim by whoever wrote the archive, not a fact
  int? uncompressedSize(List<int> data) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    var at = 0;
    var total = 0;
    try {
      while (at + 4 <= bytes.length) {
        final magic = _uint32At(bytes, at);
        if (magic >= zstdSkippableMagicMin && magic <= zstdSkippableMagicMax) {
          at += 8 + _uint32At(bytes, at + 4);
          continue;
        }
        if (magic != zstdMagic) {
          return null;
        }
        final header =
            readFrameHeader(bytes, at + 4, bytes.length, windowSizeLimit);
        final size = header.contentSize;
        if (size == null) {
          return null;
        }
        total += size;
        // Only the header was read, so the blocks have to be walked to find
        // where the next frame starts
        at = _skipFrame(bytes, at + 4 + header.size, header);
      }
    } catch (_) {
      return null;
    }
    return total;
  }

  void _decode(Uint8List bytes, bool verify, OutputMemoryStream? output,
      List<Uint8List>? parts) {
    final end = bytes.length;
    var at = 0;
    if (end == 0) {
      throw ZstdFrameException('No frame: the input is empty');
    }
    while (at < end) {
      if (at + 4 > end) {
        throw ZstdFrameException('Trailing bytes are not a frame');
      }
      final magic = _uint32At(bytes, at);
      if (magic >= zstdSkippableMagicMin && magic <= zstdSkippableMagicMax) {
        if (at + 8 > end) {
          throw ZstdFrameException('Skippable frame header is truncated');
        }
        final size = _uint32At(bytes, at + 4);
        if (at + 8 + size > end) {
          throw ZstdFrameException('Skippable frame is truncated');
        }
        at += 8 + size;
        continue;
      }
      if (magic != zstdMagic) {
        throw ZstdFrameException('Not a zstd frame');
      }

      final header = readFrameHeader(bytes, at + 4, end, windowSizeLimit);
      final dictionary = this.dictionary;
      if (header.dictionaryId != 0 &&
          (dictionary == null || dictionary.id != header.dictionaryId)) {
        throw ZstdFrameException(
            'Frame needs dictionary ${header.dictionaryId}');
      }
      final prefix = dictionary?.content.length ?? 0;
      final window = ZstdWindow(header.windowSize, output: output);
      final size = header.contentSize;
      if (output == null && size != null && size > 0) {
        // The scratch a block needs above its own output has to be part of the
        // one allocation, or the last blocks grow the buffer and copy it all
        window.reserve(prefix + size + header.blockReserve);
      }
      if (prefix > 0) {
        window.prime(dictionary!.content);
      }
      final frame = ZstdFrameDecoder();
      at += 4 + header.size;
      final completed = output?.length ?? 0;
      try {
        at += frame.decodeBlocks(
            bytes, at, end, window, header, verify, dictionary);
        if (output != null) {
          window.finish();
        } else {
          parts!.add(Uint8List.sublistView(
              window.buffer, window.origin, window.position));
        }
      } catch (_) {
        if (output != null) {
          output.length = completed;
        }
        rethrow;
      }
    }
  }

  /// Walks the block headers of a frame whose header ends at [start] and
  /// returns where the frame ends
  int _skipFrame(Uint8List bytes, int start, ZstdFrameHeader header) {
    var at = start;
    while (true) {
      if (at + 3 > bytes.length) {
        throw ZstdFrameException('Block header is truncated');
      }
      final block = bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16);
      final type = (block >> 1) & 3;
      final size = block >> 3;
      at += 3 + (type == zstdBlockRle ? 1 : size);
      if (block & 1 != 0) {
        break;
      }
    }
    return at + (header.hasChecksum ? 4 : 0);
  }

  static int _uint32At(Uint8List bytes, int at) =>
      bytes[at] |
      (bytes[at + 1] << 8) |
      (bytes[at + 2] << 16) |
      (bytes[at + 3] << 24);
}

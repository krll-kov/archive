import 'dart:typed_data';

import '../../util/output_stream.dart';
import '../../util/xxh64.dart';
import 'zstd_block_encoder.dart';
import 'zstd_block_splitter.dart';
import 'zstd_constants.dart';
import 'zstd_dictionary.dart';
import 'zstd_level_params.dart';

/// Writes one frame covering `src[start...end]`, header, blocks and checksum
class ZstdFrameEncoder {
  final Xxh64 _hash = Xxh64();
  final Uint32List _rep = Uint32List(3);

  final ZstdBlockSplitter _splitter = ZstdBlockSplitter();

  void encode(Uint8List src, int start, int end, OutputStream out,
      {bool checksum = true,
      int level = zstdDefaultLevel,
      ZstdDictionary? dictionary}) {
    final size = end - start;
    final dict = dictionary != null && dictionary.content.isNotEmpty
        ? dictionary
        : null;
    final prefix = dict?.content.length ?? 0;
    // `ZSTD_getCParamRowSize` and `ZSTD_adjustCParams_internal` both size the
    // frame by the dictionary buffer, headers and all, not by its content
    final params = zstdParamsForLevel(level, size + (dict?.sourceSize ?? 0));
    // A frame that fits its level's window declares the content instead, which
    // costs a decoder nothing extra and saves the window field
    final singleSegment = size <= (1 << params.windowLog);
    final windowSize = singleSegment ? size : 1 << params.windowLog;
    // How far a match may reach is the level's window, which a frame declaring
    // its content does not shrink: with a dictionary the two differ
    final matchWindow = 1 << params.windowLog;

    _writeHeader(out, size, singleSegment, checksum, params.windowLog,
        dict?.id ?? 0);

    if (checksum) {
      _hash.reset();
      _hash.update(src, start, size);
    }

    // The parse works in one buffer of absolute positions, so the dictionary
    // has to sit directly before the content it is a dictionary for
    var body = src;
    var at = start;
    var last = end;
    if (dict != null) {
      body = Uint8List(prefix + size);
      body.setRange(0, prefix, dict.content);
      body.setRange(prefix, prefix + size, src, start);
      at = prefix;
      last = prefix + size;
    }
    final base = at - prefix;

    final blockSizeMax =
        windowSize < zstdBlockMaximumSize ? windowSize : zstdBlockMaximumSize;
    final blocks = ZstdBlockEncoder(blockSizeMax, params);
    _rep.setAll(0, dict?.repeatOffsets ?? zstdInitialRepeatOffsets);
    if (dict != null) {
      blocks.prime(body, base, at, dict);
    }

    if (size == 0) {
      blocks.encode(body, at, at, base, out, true, _rep);
    }
    // Everything a block saved so far, which is what stops the splitter from
    // cutting up data that does not compress
    var savings = 0;
    while (at < last) {
      final left = last - at;
      final take =
          _splitter.sizeFor(body, at, left, blockSizeMax, params, savings);
      final reach = at - matchWindow;
      final before = out.length;
      blocks.encode(body, at, at + take, reach > base ? reach : base, out,
          at + take == last, _rep);
      savings += take - (out.length - before);
      at += take;
    }

    if (checksum) {
      final digest = _hash.digestLow;
      out.writeByte(digest & 0xff);
      out.writeByte((digest >>> 8) & 0xff);
      out.writeByte((digest >>> 16) & 0xff);
      out.writeByte((digest >>> 24) & 0xff);
    }
  }

  static void _writeHeader(OutputStream out, int size, bool singleSegment,
      bool checksum, int windowLog, int dictionaryId) {
    final int contentSizeFlag;
    if (singleSegment && size < 256) {
      contentSizeFlag = 0;
    } else if (size >= 256 && size < 65536 + 256) {
      contentSizeFlag = 1;
    } else if (size < 4294967296) {
      contentSizeFlag = 2;
    } else {
      contentSizeFlag = 3;
    }
    // `ZSTD_writeFrameHeader`: as many bytes as the id needs, and the flag
    // names which of the four widths that is
    final idFlag = dictionaryId == 0
        ? 0
        : (dictionaryId < 256 ? 1 : (dictionaryId < 65536 ? 2 : 3));

    out.writeByte(zstdMagic & 0xff);
    out.writeByte((zstdMagic >>> 8) & 0xff);
    out.writeByte((zstdMagic >>> 16) & 0xff);
    out.writeByte((zstdMagic >>> 24) & 0xff);

    out.writeByte((contentSizeFlag << 6) |
        (singleSegment ? 0x20 : 0) |
        (checksum ? 4 : 0) |
        idFlag);

    if (!singleSegment) {
      // Exponent in the top five bits, eighths of it in the bottom three
      out.writeByte((windowLog - 10) << 3);
    }

    final idBytes = const [0, 1, 2, 4][idFlag];
    for (var i = 0; i < idBytes; i++) {
      out.writeByte((dictionaryId >>> (i << 3)) & 0xff);
    }

    // Divided rather than shifted, since the size reaches past 32 bits and a
    // shift there is not portable
    var value = contentSizeFlag == 1 ? size - 256 : size;
    final bytes = contentSizeFlag == 0 ? 1 : 1 << contentSizeFlag;
    for (var i = 0; i < bytes; i++) {
      out.writeByte(value % 256);
      value ~/= 256;
    }
  }
}

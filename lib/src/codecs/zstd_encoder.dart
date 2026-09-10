import 'dart:typed_data';

import '../util/input_memory_stream.dart';
import '../util/input_stream.dart';
import '../util/output_memory_stream.dart';
import '../util/output_stream.dart';
import 'zstd/zstd_dictionary.dart';
import 'zstd/zstd_frame_encoder.dart';
import 'zstd/zstd_level_params.dart';

/// Compress data with the zstd format encoder
class ZstdEncoder {
  /// Whether the frame carries an XXH64 of its content
  final bool checksum;

  final int level;

  /// Placed before the content so matches can reach into it, and named in the
  /// frame header, so only the same dictionary reads the frame back
  final ZstdDictionary? dictionary;

  const ZstdEncoder(
      {this.checksum = true, this.level = zstdDefaultLevel, this.dictionary});

  Uint8List encodeBytes(List<int> data, {int? level}) {
    final output = OutputMemoryStream();
    encodeStream(InputMemoryStream(data), output, level: level);
    return output.getBytes();
  }

  List<int> encode(List<int> data, {int? level}) =>
      encodeBytes(data, level: level);

  /// Compress [input] into [output] as one frame, reading the input whole
  void encodeStream(InputStream input, OutputStream output, {int? level}) {
    final bytes = input.toUint8List();
    ZstdFrameEncoder().encode(bytes, 0, bytes.length, output,
        checksum: checksum,
        level: level ?? this.level,
        dictionary: dictionary);
  }
}

Uint8List zstdEncode(List<int> data, {int? level}) =>
    const ZstdEncoder().encodeBytes(data, level: level);

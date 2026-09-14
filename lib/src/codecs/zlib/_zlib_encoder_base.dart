import 'dart:typed_data';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';

abstract class ZLibEncoderBase {
  const ZLibEncoderBase();

  Uint8List encodeBytes(List<int> bytes,
      {int? level, int? windowBits, bool raw = false});

  void encodeStream(InputStream input, OutputStream output,
      {int? level, int? windowBits, bool raw = false});

  /// A sink that compresses into [output] piece by piece. Null where the
  /// backend only runs whole, and then [encodeStream] is all there is
  Sink<List<int>>? startEncode(OutputStream output,
          {int? level, int? windowBits, bool raw = false}) =>
      null;
}

/// Hands every piece the codec produces straight to [output], where
/// `ChunkedConversionSink.withCallback` would hold the whole of it to the end
class ZLibOutputSink implements Sink<List<int>> {
  final OutputStream _output;

  /// Bytes this sink put into [_output], whose own length may count more
  var written = 0;

  ZLibOutputSink(this._output);

  @override
  void add(List<int> data) {
    _output.writeBytes(data);
    written += data.length;
  }

  @override
  void close() => _output.flush();
}

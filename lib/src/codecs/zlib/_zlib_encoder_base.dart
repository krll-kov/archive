import 'dart:typed_data';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';

abstract class ZLibEncoderBase {
  const ZLibEncoderBase();

  Uint8List encodeBytes(List<int> bytes,
      {int? level, int? windowBits, bool raw = false});

  void encodeStream(InputStream input, OutputStream output,
      {int? level, int? windowBits, bool raw = false});
}

/// Hands every piece the codec produces straight to [output], where
/// `ChunkedConversionSink.withCallback` would hold the whole of it to the end
class ZLibOutputSink implements Sink<List<int>> {
  final OutputStream _output;

  ZLibOutputSink(this._output);

  @override
  void add(List<int> data) => _output.writeBytes(data);

  @override
  void close() => _output.flush();
}

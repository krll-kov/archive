import 'dart:typed_data';

import 'byte_order.dart';
import 'input_stream.dart';
import 'output_stream.dart';

/// Passes every write to [output] and calls [onProgress] with the number of
/// bytes written through it, once per [interval] bytes and on flush and close.
///
/// A decoder rarely knows its output size in advance, so a fraction is read
/// off the input instead:
///
/// ```dart
/// final total = input.length;
/// final out = ProgressOutputStream(OutputFileStream(path),
///     (_) => onProgress(input.position / total));
/// const GZipDecoder().decodeStream(input, out);
/// ```
class ProgressOutputStream implements OutputStream {
  final OutputStream output;
  final void Function(int written) onProgress;
  final int interval;

  int _written = 0;
  int _reported = 0;

  ProgressOutputStream(this.output, this.onProgress, {this.interval = 0x10000});

  /// Bytes written through this stream so far
  int get written => _written;

  @override
  ByteOrder get byteOrder => output.byteOrder;

  @override
  set byteOrder(ByteOrder value) => output.byteOrder = value;

  @override
  int get length => output.length;

  @override
  bool get isOpen => output.isOpen;

  @override
  void open() => output.open();

  @override
  Future<void> close() {
    _report();
    return output.close();
  }

  @override
  void closeSync() {
    _report();
    output.closeSync();
  }

  @override
  void clear() => output.clear();

  @override
  void flush() {
    output.flush();
    _report();
  }

  @override
  void writeByte(int value) {
    output.writeByte(value);
    _add(1);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    output.writeBytes(bytes, length: length);
    _add(length ?? bytes.length);
  }

  @override
  void writeRange(Uint8List bytes, int start, int end) {
    output.writeRange(bytes, start, end);
    _add(end - start);
  }

  @override
  void reserve(int total) => output.reserve(total);

  @override
  void writeStream(InputStream stream) {
    final count = stream.length;
    output.writeStream(stream);
    _add(count);
  }

  @override
  void writeUint16(int value) {
    output.writeUint16(value);
    _add(2);
  }

  @override
  void writeUint32(int value) {
    output.writeUint32(value);
    _add(4);
  }

  @override
  void writeUint64(int value) {
    output.writeUint64(value);
    _add(8);
  }

  @override
  void writeBackReference(int distance, int count) {
    output.writeBackReference(distance, count);
    _add(count);
  }

  @override
  Uint8List subset(int start, [int? end]) => output.subset(start, end);

  @override
  Uint8List getBytes() => output.getBytes();

  void _add(int count) {
    _written += count;
    if (_written - _reported >= interval) {
      _reported = _written;
      onProgress(_written);
    }
  }

  void _report() {
    if (_written != _reported) {
      _reported = _written;
      onProgress(_written);
    }
  }
}

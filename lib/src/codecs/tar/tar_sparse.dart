import 'dart:typed_data';

import '../../util/file_content.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_stream.dart';
import 'tar_file.dart';

const _maxValue = TarFile.maxNumericField;

class TarSparse {
  int realSize = -1;
  final regions = <(int, int)>[];
  bool extended = false;
  int extensionBlocks = 0;
  bool mapInData = false;
  int mapLength = 0;
  bool broken = false;

  var _count = -1;
  var _offset = -1;
  var _value = 0;
  var _line = 0;
  var _comment = false;
  var _scanned = 0;

  void add(int offset, int length) {
    if (length != 0) {
      regions.add((offset, length));
    }
  }

  bool? readMap(Uint8List chunk) {
    if (_scanned == 0) {
      regions.clear();
    }
    for (var i = 0; i < chunk.length; i++) {
      final c = chunk[i];
      if (++_line > 100) {
        broken = true;
        return false;
      }
      if (_comment) {
        if (c == 0x0a) {
          _comment = false;
          _line = 0;
        }
      } else if (c == 0x23 && _line == 1) {
        _comment = true;
      } else if (c == 0x0a) {
        _line = 0;
        final value = _value;
        _value = 0;
        if (_count < 0) {
          _count = value;
        } else if (_offset < 0) {
          _offset = value;
          continue;
        } else {
          add(_offset, value);
          _offset = -1;
          _count--;
        }
        if (_count == 0) {
          mapLength = (_scanned + i + 512) ~/ 512 * 512;
          return true;
        }
      } else if (c >= 0x30 && c <= 0x39) {
        final digit = c - 0x30;
        _value = _value > (_maxValue - digit) ~/ 10
            ? _maxValue
            : _value * 10 + digit;
      } else {
        broken = true;
        return false;
      }
    }
    _scanned += chunk.length;
    return null;
  }

  bool fits(int dataSize) {
    if (broken || extended || (mapInData && mapLength == 0)) {
      return false;
    }
    if (regions.isEmpty && dataSize > mapLength) {
      regions.add((0, dataSize - mapLength));
    }
    var end = 0;
    var stored = 0;
    for (final (offset, length) in regions) {
      if (offset < end || length < 0 || length > realSize - offset) {
        return false;
      }
      end = offset + length;
      stored += length;
    }
    return stored == dataSize - mapLength;
  }
}

final _zeros = Uint8List(1 << 16);

class FileContentSparse extends FileContent {
  FileContentSparse(this._data, this._regions, this.length);

  final InputStream _data;
  final List<(int, int)> _regions;

  @override
  final int length;

  @override
  InputStream getStream({bool decompress = true}) =>
      InputMemoryStream(readBytes());

  @override
  Uint8List readBytes() {
    final out = Uint8List(length);
    var at = 0;
    for (final (offset, size) in _regions) {
      out.setRange(offset, offset + size,
          _data.subset(position: at, length: size).toUint8List());
      at += size;
    }
    return out;
  }

  @override
  void write(OutputStream output) {
    var end = 0;
    void hole(int to) {
      while (end < to) {
        final n = to - end < _zeros.length ? to - end : _zeros.length;
        output.writeBytes(_zeros, length: n);
        end += n;
      }
    }

    var at = 0;
    for (final (offset, size) in _regions) {
      hole(offset);
      output.writeStream(_data.subset(position: at, length: size));
      at += size;
      end = offset + size;
    }
    hole(length);
  }

  @override
  void decompress(OutputStream output) => write(output);

  @override
  Future<void> close() async => _data.close();

  @override
  void closeSync() => _data.closeSync();
}

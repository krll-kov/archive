import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';

// A codec has three ways in: the whole buffer, the older InputStream pair, and
// the chunked converter. They have to agree with each other where the format
// says they should, every one of them has to read back as the original, and
// the system tool has to accept what they wrote.

Uint8List _source(int length, int seed) {
  final bytes = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    // Compressible, with runs, so every path has real work to do
    bytes[i] = (state >> 16) % 4 == 0 ? 0x41 : (state >> 8) & 0xff;
  }
  return bytes;
}

Uint8List _chunked(
    Converter<List<int>, List<int>> codec, Uint8List source, int piece) {
  final held = BytesBuilder(copy: false);
  final sink = codec.startChunkedConversion(_Held(held));
  for (var at = 0; at < source.length; at += piece) {
    final end = at + piece < source.length ? at + piece : source.length;
    sink.add(Uint8List.sublistView(source, at, end));
  }
  sink.close();
  return held.toBytes();
}

Uint8List _old(
    void Function(InputStream, OutputStream) body, Uint8List source) {
  final output = OutputMemoryStream();
  body(InputMemoryStream(source), output);
  return output.getBytes();
}

/// What the system tool makes of it, or null where that tool is not here
bool? _throughTool(String tool, List<String> args, Uint8List archive,
    Uint8List want, Directory directory) {
  if (!File('/usr/bin/$tool').existsSync() &&
      !File('/opt/homebrew/bin/$tool').existsSync()) {
    return null;
  }
  final path = '${directory.path}/probe';
  File(path).writeAsBytesSync(archive);
  final run = Process.runSync(tool, [...args, path], stdoutEncoding: null);
  if (run.exitCode != 0) {
    return false;
  }
  final got = run.stdout as List<int>;
  if (got.length != want.length) {
    return false;
  }
  for (var i = 0; i < want.length; i++) {
    if (got[i] != want[i]) {
      return false;
    }
  }
  return true;
}

void main() {
  final source = _source(400000, 7);

  final codecs = <String, _Paths>{
    'zstd': _Paths(
      whole: () => ZstdEncoder().encodeBytes(source),
      old: () => _old((i, o) => ZstdEncoder().encodeStream(i, o), source),
      converter: zstdCodec.encoder,
      decoder: zstdCodec.decoder,
      back: (a) => ZstdDecoder().decodeBytes(a, verify: true, throwOnError: true),
      tool: 'zstd',
      toolArgs: ['-dc'],
      // The chunked encoder writes what ZSTD_compressStream2 writes, which is
      // a different archive from the one shot ZSTD_compress2
      chunkedMatchesWhole: false,
    ),
    'bzip2': _Paths(
      whole: () => BZip2Encoder().encodeBytes(source),
      old: () => _old((i, o) => BZip2Encoder().encodeStream(i, o), source),
      converter: bzip2Codec.encoder,
      decoder: bzip2Codec.decoder,
      back: (a) => BZip2Decoder().decodeBytes(a, verify: true),
      tool: 'bzip2',
      toolArgs: ['-dc'],
      chunkedMatchesWhole: true,
    ),
    'xz': _Paths(
      whole: () => XZEncoder().encodeBytes(source),
      old: () => _old((i, o) => XZEncoder().encodeStream(i, o), source),
      converter: xzCodec.encoder,
      decoder: xzCodec.decoder,
      back: (a) => XZDecoder().decodeBytes(a, verify: true),
      tool: 'xz',
      toolArgs: ['-dc'],
      chunkedMatchesWhole: true,
    ),
  };

  for (final entry in codecs.entries) {
    final name = entry.key;
    final paths = entry.value;

    group('$name, the three ways in', () {
      test('the older stream writes what the whole buffer writes', () {
        expect(paths.old(), paths.whole());
      });

      test('the converter writes the same whatever the pieces', () {
        final want = _chunked(paths.converter, source, source.length);
        for (final piece in [1, 4095, 65536]) {
          expect(_chunked(paths.converter, source, piece), want,
              reason: 'piece $piece');
        }
        if (paths.chunkedMatchesWhole) {
          expect(want, paths.whole());
        } else {
          expect(want, isNot(paths.whole()));
        }
      });

      test('all three read back as the original', () {
        for (final archive in [paths.whole(), paths.old(), _chunked(paths.converter, source, 8192)]) {
          expect(paths.back(archive), source);
          expect(_chunked(paths.decoder, archive, 997), source);
        }
      });

      test('the system tool reads all three back as the original', () {
        final directory = Directory.systemTemp.createTempSync('codec_paths');
        try {
          for (final archive in [
            paths.whole(),
            paths.old(),
            _chunked(paths.converter, source, 8192)
          ]) {
            final result = _throughTool(
                paths.tool, paths.toolArgs, archive, source, directory);
            if (result == null) {
              return; // that tool is not installed here
            }
            expect(result, isTrue);
          }
        } finally {
          directory.deleteSync(recursive: true);
        }
      });
    });
  }
}

class _Paths {
  final Uint8List Function() whole;
  final Uint8List Function() old;
  final Converter<List<int>, List<int>> converter;
  final Converter<List<int>, List<int>> decoder;
  final Uint8List Function(Uint8List) back;
  final String tool;
  final List<String> toolArgs;
  final bool chunkedMatchesWhole;

  const _Paths({
    required this.whole,
    required this.old,
    required this.converter,
    required this.decoder,
    required this.back,
    required this.tool,
    required this.toolArgs,
    required this.chunkedMatchesWhole,
  });
}

class _Held implements Sink<List<int>> {
  _Held(this._held);

  final BytesBuilder _held;

  @override
  void add(List<int> data) => _held.add(data);

  @override
  void close() {}
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../archive/archive_file.dart';
import '../../util/_pieces.dart';
import '../../util/archive_exception.dart';
import '../../util/cancellable_stream.dart';
import '../../util/chunked_sink.dart';
import '../../util/input_memory_stream.dart';
import '../tar_encoder.dart';
import 'tar_file.dart';

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.yield_codecs.encoder}
class TarChunkedEncoder {
  final Sink<List<int>> output;

  /// The encoding used to write the entry name, matching what
  /// [TarDecoderTransformer] uses to read it back
  final Encoding filenameEncoding;

  TarChunkedEncoder(this.output, {this.filenameEncoding = const Utf8Codec()}) {
    _encoder.start(_out);
  }

  late final _encoder = TarEncoder(filenameEncoding: filenameEncoding);
  late final _out = SinkOutputStream(output);
  var _closed = false;

  void add(ArchiveFile entry) {
    if (_closed) {
      throw StateError('Cannot add to a closed encoder');
    }
    _encoder.add(entry);
  }

  /// Writes the entry header and returns the payload stream for callers
  /// that need to provide the content piece-by-piece
  TarFile? addHeader(ArchiveFile entry) {
    if (_closed) {
      throw StateError('Cannot add to a closed encoder');
    }
    return _encoder.addHeader(entry);
  }

  /// Pushes what the header left in the buffer out to the sink, so a caller
  /// that writes the content itself writes it behind the header
  void flush() => _out.flush();

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _encoder.finish();
    output.close();
  }
}

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.yield_codecs.encoder}
class TarCodec {
  final Encoding filenameEncoding;

  /// {@macro archive.codecs.auto_close}
  final bool autoClose;

  const TarCodec(
      {this.filenameEncoding = const Utf8Codec(), this.autoClose = false});

  TarDecoderTransformer get decoder =>
      TarDecoderTransformer(filenameEncoding: filenameEncoding);

  TarEncoderTransformer get encoder => TarEncoderTransformer(
      filenameEncoding: filenameEncoding, autoClose: autoClose);
}

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.decoder}
/// {@macro archive.yield_codecs.encoder}
const tarCodec = TarCodec();

/// {@macro archive.codecs.not_converter}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.encoder}
class TarEncoderTransformer
    extends StreamTransformerBase<ArchiveFile, List<int>> {
  final Encoding filenameEncoding;

  /// {@macro archive.codecs.auto_close}
  final bool autoClose;

  const TarEncoderTransformer(
      {this.filenameEncoding = const Utf8Codec(), this.autoClose = false});

  /// The chunk size used to stream the entry's payload. Since entries aren't
  /// buffered in full, the encoder yields the content in pieces of this size
  static const _piece = 64 * 1024;

  @override
  Stream<List<int>> bind(Stream<ArchiveFile> stream) =>
      cancellableStream<ArchiveFile, List<int>>(
          stream, (input, signal) => _write(input, signal));

  Stream<List<int>> _write(
      StreamIterator<ArchiveFile> input, CancelSignal signal) async* {
    final held = <List<int>>[];
    final encoder =
        TarChunkedEncoder(Pieces(held), filenameEncoding: filenameEncoding);
    while (await input.moveNext()) {
      final entry = input.current;
      try {
        // We process the header but leave the content raw. Yielding here lets
        // the reader start consuming the payload before the entire entry is buffered
        final file = encoder.addHeader(entry);
        encoder.flush();
        while (held.isNotEmpty) {
          yield held.removeAt(0);
        }
        if (file == null) {
          continue;
        }
        final body = file.contentStream;
        if (body != null) {
          while (!body.isEOS) {
            final take = body.length < _piece ? body.length : _piece;
            // An InputStream can report a length of 0 before its end. Without
            // this check the loop yields empty pieces forever
            if (take <= 0) {
              break;
            }
            yield body.readBytes(take).toUint8List();
          }
        }
        final pad = file.padding;
        if (pad > 0) {
          yield Uint8List(pad);
        }
      } finally {
        // Runs as finally block to catch stream cancellations
        // triggered at the yield
        if (autoClose) {
          entry.closeSync();
        }
      }
    }
    if (signal.cancelled) {
      return;
    }
    encoder.close();
    while (held.isNotEmpty) {
      yield held.removeAt(0);
    }
  }
}

/// {@macro archive.codecs.not_converter}
/// {@macro archive.yield_codecs.one_at_time}
///
/// {@macro archive.codecs.without_on_done}
/// {@macro archive.yield_codecs.encoder}
class TarDecoderTransformer extends StreamTransformerBase<List<int>, TarEntry> {
  final Encoding filenameEncoding;

  const TarDecoderTransformer({this.filenameEncoding = const Utf8Codec()});

  @override
  Stream<TarEntry> bind(Stream<List<int>> stream) =>
      cancellableStream<List<int>, TarEntry>(stream,
          (input, signal) => _read(_Reader(input), filenameEncoding, signal));
}

/// The parsed type flag. Note that older tar files often use an empty field
/// for plain files rather than the standard '0'
enum TarEntryType {
  file,
  hardLink,
  symbolicLink,
  characterDevice,
  blockDevice,
  directory,
  fifo,
  contiguousFile,

  /// A flag this package has no name for, left to [TarEntry.typeFlag]
  other;

  static TarEntryType of(String flag) => switch (flag) {
        TarFile.normalFile || '' || '\u0000' => file,
        TarFile.hardLink => hardLink,
        TarFile.symbolicLink => symbolicLink,
        TarFile.charSpec => characterDevice,
        TarFile.blockSpec => blockDevice,
        TarFile.directory => directory,
        TarFile.fifo => fifo,
        TarFile.contFile => contiguousFile,
        _ => other,
      };
}

/// A single tar entry parsed from a Stream
class TarEntry {
  final String name;

  /// The size specified in the header, matching the byte count of [content]
  final int size;
  final int mode;
  final int ownerId;
  final int groupId;
  final int lastModTime;

  /// The entry type. Use [typeFlag] to access raw or unmapped flags directly
  final TarEntryType type;
  final String typeFlag;
  final String? symbolicLink;

  TarEntry._(TarFile file, this._reader)
      : name = file.filename,
        type = TarEntryType.of(file.typeFlag),
        size = file.fileSize,
        mode = file.mode,
        ownerId = file.ownerId,
        groupId = file.groupId,
        lastModTime = file.lastModTime,
        typeFlag = file.typeFlag,
        symbolicLink = (file.nameOfLinkedFile?.isNotEmpty ?? false)
            ? file.nameOfLinkedFile
            : null,
        _left = file.fileSize;

  final _Reader _reader;
  int _left;
  var _taken = false;
  var _done = false;

  /// Indicates that the reader skipped over this entry's unread bytes
  var _gone = false;

  /// Resolves when the content stream stops pulling from the reader
  Future<void> _settled = Future.value();

  /// A standard file only (not a link or a device)
  bool get isFile => type == TarEntryType.file;

  bool get isDirectory => type == TarEntryType.directory;

  bool get isSymbolicLink => type == TarEntryType.symbolicLink;

  /// Yields the entry's data on the fly. The bytes can only be consumed once,
  /// and only while the parser is actively on this entry
  Stream<List<int>> get content {
    if (_done) {
      throw StateError(
          'tar: the archive has moved past $name, its content is gone');
    }
    if (_taken) {
      throw StateError('tar: the content of $name was already read');
    }
    _taken = true;
    return _detached(_pieces());
  }

  /// Canceling [pieces] is synchronous so the caller can easily time out on a
  /// dead stream. Any active read is left to gracefully fail whenever its
  /// next piece arrives
  Stream<List<int>> _detached(Stream<List<int>> pieces) {
    StreamSubscription<List<int>>? inner;
    late final StreamController<List<int>> out;
    out = StreamController<List<int>>(
      onListen: () {
        final settled = Completer<void>();
        _settled = settled.future;
        inner = pieces.listen(out.add, onError: out.addError, onDone: () {
          if (!settled.isCompleted) {
            settled.complete();
          }
          unawaited(out.close());
        });
        _finish = () {
          if (!settled.isCompleted) {
            settled.complete();
          }
        };
      },
      onPause: () => inner?.pause(),
      onResume: () => inner?.resume(),
      onCancel: () {
        unawaited(inner!
            .cancel()
            .catchError((Object _) {})
            .whenComplete(() => _finish?.call()));
      },
    );
    return out.stream;
  }

  void Function()? _finish;

  Stream<List<int>> _pieces() async* {
    if (_gone) {
      throw StateError(
          'tar: the archive has moved past $name, its content is gone');
    }
    while (_left > 0) {
      final piece = await _reader.some(_left);
      if (piece.isEmpty) {
        throw ArchiveException('tar: unexpected end of archive $name');
      }
      _left -= piece.length;
      yield piece;
    }
  }
}

Stream<TarEntry> _read(
    _Reader reader, Encoding encoding, CancelSignal signal) async* {
  final metadata = TarMetadata();
  try {
    while (true) {
      final header = await reader.exact(512);
      // A block of zeros ends the archive; padding or another archive follows
      if (header == null || _allZero(header)) {
        break;
      }
      // Since seeking backwards isn't supported, accidentally parsing payload
      // as a header consumes and destroys that data. The checksum is the
      // sole indicator that we're looking at a real header
      if (!tarHeaderChecksumMatches(header)) {
        throw ArchiveException('tar: invalid header checksum');
      }
      // The header is read again, followed immediately by its content,
      // exactly where `TarMetadata` expects to find it
      var file = TarFile.read(InputMemoryStream(header),
          storeData: false, encoding: encoding, size: metadata.size);
      if (TarMetadata.describesNext(file)) {
        final body = await reader.exact(_padded(file.fileSize));
        if (body == null) {
          throw ArchiveException('tar: unexpected end of archive');
        }
        final whole = Uint8List(512 + file.fileSize)
          ..setRange(0, 512, header)
          ..setRange(512, 512 + file.fileSize, body);
        file = TarFile.read(InputMemoryStream(whole),
            storeData: false, encoding: encoding, size: metadata.size);
        metadata.take(file, encoding);
        continue;
      }
      metadata.applyTo(file);

      final entry = TarEntry._(file, reader);
      yield entry;
      entry._done = true;
      // A paused content read never completes on its own, so a cancel has to
      // end the wait below as well
      signal.onCancel = () => entry._finish?.call();
      // We share the reader with the active content read, meaning
      // it must complete before we can proceed
      await entry._settled;
      if (signal.cancelled) {
        return;
      }
      entry._gone = entry._left > 0;
      await reader.skip(entry._left + _padding(entry.size));
      entry._left = 0;
    }
  } finally {
    await reader.cancel();
  }
}

/// The full entry size, padded to the nearest block
int _padded(int size) => size + _padding(size);

int _padding(int size) => (512 - (size % 512)) % 512;

bool _allZero(Uint8List block) {
  for (final byte in block) {
    if (byte != 0) {
      return false;
    }
  }
  return true;
}

/// Pulls a format-specified number of bytes from the `Stream`
class _Reader {
  _Reader(this._it);

  final StreamIterator<List<int>> _it;
  Uint8List _held = Uint8List(0);
  int _at = 0;

  Future<bool> _more() async {
    while (_at >= _held.length) {
      if (!await _it.moveNext()) {
        return false;
      }
      final piece = _it.current;
      _held = piece is Uint8List ? piece : Uint8List.fromList(piece);
      _at = 0;
    }
    return true;
  }

  /// Up to [max] bytes of what has arrived, empty once the input is over
  Future<Uint8List> some(int max) async {
    if (!await _more()) {
      return Uint8List(0);
    }
    var take = _held.length - _at;
    if (take > max) {
      take = max;
    }
    final piece = Uint8List.sublistView(_held, _at, _at + take);
    _at += take;
    return piece;
  }

  /// {@macro archive.header_size_trust}
  static const _reserve = 1 << 16;

  /// Exactly [count] bytes, or null if the input ended before any arrived
  Future<Uint8List?> exact(int count) async {
    if (count == 0) {
      return Uint8List(0);
    }
    var out = Uint8List(count < _reserve ? count : _reserve);
    var got = 0;
    while (got < count) {
      final piece = await some(count - got);
      if (piece.isEmpty) {
        if (got == 0) {
          return null;
        }
        throw ArchiveException('tar: unexpected end of archive');
      }
      if (got + piece.length > out.length) {
        var size = out.length;
        while (size < got + piece.length) {
          size <<= 1;
        }
        out = Uint8List(size)..setRange(0, got, out);
      }
      out.setRange(got, got + piece.length, piece);
      got += piece.length;
    }
    return out.length == count ? out : Uint8List.sublistView(out, 0, count);
  }

  Future<void> skip(int count) async {
    var left = count;
    while (left > 0) {
      final piece = await some(left);
      if (piece.isEmpty) {
        throw ArchiveException('tar: unexpected end of archive');
      }
      left -= piece.length;
    }
  }

  Future<void> cancel() => _it.cancel();
}

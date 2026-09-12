import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../archive/archive_file.dart';
import '../../util/archive_exception.dart';
import '../../util/chunked_sink.dart';
import '../../util/input_memory_stream.dart';
import '../tar_encoder.dart';
import 'tar_file.dart';

/// Writes a tar into a `Sink` an entry at a time, so neither the archive nor an
/// entry exists whole. An entry's size goes in the header before its bytes, so
/// a length not known until the content is generated has to be measured first
class TarChunkedEncoder {
  final Sink<List<int>> output;

  /// What a name is written as, the same field [TarStreamDecoder] reads it back
  /// through
  final Encoding filenameEncoding;

  TarChunkedEncoder(this.output,
      {this.filenameEncoding = const Utf8Codec()}) {
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

  /// Writes an entry's header and returns what is left of it, for a caller that
  /// hands the content out itself rather than in one call
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

/// tar as a `Stream` both ways, the shape the other codecs use. Not a
/// `dart:convert` `Codec`, since neither side is bytes to bytes
class TarCodec {
  final Encoding filenameEncoding;

  const TarCodec({this.filenameEncoding = const Utf8Codec()});

  TarStreamDecoder get decoder =>
      TarStreamDecoder(filenameEncoding: filenameEncoding);

  TarStreamEncoder get encoder =>
      TarStreamEncoder(filenameEncoding: filenameEncoding);
}

/// The codec with its defaults, for `stream.transform(tarCodec.decoder)`
const tarCodec = TarCodec();

/// [TarChunkedEncoder] behind the shape the other codecs use
class TarStreamEncoder extends StreamTransformerBase<ArchiveFile, List<int>> {
  final Encoding filenameEncoding;

  const TarStreamEncoder({this.filenameEncoding = const Utf8Codec()});

  /// What an entry's content is handed out in. An entry is not held whole, so
  /// this is all the encoder owes beyond the header it has already written
  static const _piece = 64 * 1024;

  @override
  Stream<List<int>> bind(Stream<ArchiveFile> stream) async* {
    final held = <List<int>>[];
    final encoder = TarChunkedEncoder(_Pieces(held),
        filenameEncoding: filenameEncoding);
    await for (final entry in stream) {
      // The header goes through the encoder, the content does not: a yield in
      // between is what lets a reader have the first bytes before the last of
      // the entry has been read
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
          yield body.readBytes(take).toUint8List();
        }
      }
      final pad = file.padding;
      if (pad > 0) {
        yield Uint8List(pad);
      }
    }
    encoder.close();
    while (held.isNotEmpty) {
      yield held.removeAt(0);
    }
  }
}

class _Pieces implements Sink<List<int>> {
  _Pieces(this._held);

  final List<List<int>> _held;

  @override
  void add(List<int> data) => _held.add(data);

  @override
  void close() {}
}

/// Reads a tar out of a `Stream`, one entry at a time, holding one entry's
/// header rather than the archive. [TarEntry.content] has to be read before
/// the loop moves on, since the bytes are gone by then; what is left unread is
/// skipped. Over a source that can seek, `TarDecoder` is already lazy
class TarStreamDecoder extends StreamTransformerBase<List<int>, TarEntry> {
  final Encoding filenameEncoding;

  const TarStreamDecoder({this.filenameEncoding = const Utf8Codec()});

  @override
  Stream<TarEntry> bind(Stream<List<int>> stream) =>
      _read(stream, filenameEncoding);
}

/// What an entry is, as the header's type flag names it. Old archives leave
/// the field empty for a plain file, which is why that is not only `'0'`
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

/// One entry of a tar being read out of a `Stream`
class TarEntry {
  final String name;

  /// What the header says the entry holds, which is what [content] carries
  final int size;
  final int mode;
  final int ownerId;
  final int groupId;
  final int lastModTime;
  /// What the entry is. [typeFlag] is the raw field behind it, for the flags
  /// this has no name for
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
        symbolicLink = file.nameOfLinkedFile,
        _left = file.fileSize;

  final _Reader _reader;
  int _left;
  var _taken = false;
  var _done = false;

  /// A plain file, and only that: a link or a device is not one
  bool get isFile => type == TarEntryType.file;

  bool get isDirectory => type == TarEntryType.directory;

  bool get isSymbolicLink => type == TarEntryType.symbolicLink;

  /// The entry's bytes as they arrive, once and while it is the current entry
  Stream<List<int>> get content {
    if (_done) {
      throw StateError(
          'tar: the archive has moved past $name, its content is gone');
    }
    if (_taken) {
      throw StateError('tar: the content of $name was already read');
    }
    _taken = true;
    return _pieces();
  }

  Stream<List<int>> _pieces() async* {
    while (_left > 0) {
      final piece = await _reader.some(_left);
      if (piece.isEmpty) {
        throw ArchiveException('tar: the archive ended part way through $name');
      }
      _left -= piece.length;
      yield piece;
    }
  }
}

Stream<TarEntry> _read(Stream<List<int>> source, Encoding encoding) async* {
  final reader = _Reader(source);
  final metadata = TarMetadata();
  try {
    while (true) {
      final header = await reader.exact(512);
      // A block of zeros ends the archive; padding or another archive follows
      if (header == null || _allZero(header)) {
        break;
      }
      // Nothing here can seek back, so a header read from junk is content
      // already lost. The sum is what says this block is a header at all
      if (!tarHeaderChecksumMatches(header)) {
        throw ArchiveException('tar: invalid header checksum');
      }
      // A header describing the next entry is read again with its content
      // behind it, which is where `TarMetadata` looks for it
      var file = TarFile.read(InputMemoryStream(header),
          storeData: false, encoding: encoding, size: metadata.size);
      if (TarMetadata.describesNext(file)) {
        final body = await reader.exact(_padded(file.fileSize));
        if (body == null) {
          throw ArchiveException('tar: the archive ended part way through');
        }
        final whole = Uint8List(512 + file.fileSize)
          ..setRange(0, 512, header)
          ..setRange(512, 512 + file.fileSize, body);
        file = TarFile.read(InputMemoryStream(whole),
            storeData: false, encoding: encoding, size: metadata.size);
        metadata.take(file);
        continue;
      }
      metadata.applyTo(file);

      final entry = TarEntry._(file, reader);
      yield entry;
      entry._done = true;
      await reader.skip(entry._left + _padding(entry.size));
      entry._left = 0;
    }
  } finally {
    await reader.cancel();
  }
}

/// What the whole of an entry weighs, its content rounded up to a block
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

/// Bytes out of a `Stream`, by the count the format names
class _Reader {
  _Reader(Stream<List<int>> source) : _it = StreamIterator(source);

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

  /// Exactly [count] bytes, null where the input ended before any of them
  Future<Uint8List?> exact(int count) async {
    if (count == 0) {
      return Uint8List(0);
    }
    final out = Uint8List(count);
    var got = 0;
    while (got < count) {
      final piece = await some(count - got);
      if (piece.isEmpty) {
        if (got == 0) {
          return null;
        }
        throw ArchiveException('tar: the archive ended part way through');
      }
      out.setRange(got, got + piece.length, piece);
      got += piece.length;
    }
    return out;
  }

  Future<void> skip(int count) async {
    var left = count;
    while (left > 0) {
      final piece = await some(left);
      if (piece.isEmpty) {
        throw ArchiveException('tar: the archive ended part way through');
      }
      left -= piece.length;
    }
  }

  Future<void> cancel() => _it.cancel();
}

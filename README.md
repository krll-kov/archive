# archive
[![Dart CI](https://github.com/brendan-duncan/archive/actions/workflows/build.yaml/badge.svg)](https://github.com/brendan-duncan/archive/actions/workflows/build.yaml)
[![pub package](https://img.shields.io/pub/v/archive.svg)](https://pub.dev/packages/archive)

## 4.0 Update

The Archive library was originally written when the web was the primary use of Dart. File IO was less of a concern
and the design was around having everything in memory. As other uses of Dart came about, such as Flutter, a lot
of File IO operations were added to the library, but not in a very clean way.

The design goal for the 4.0 revision of the library is to ensure File IO is a primary focus, while minimizing memory
usage. Memory-only interfaces are still available for web platforms.

#### [Migrating 3.x to 4.x](doc/migrating_3_to_4.md).

### Migration quick tips:
* **decodeBuffer** has been renamed to **decodeStream** in the various decoder classes.
* **InputStream** has been renamed to **InputMemoryStream**.
* **OutputStream** has been renamed to **OutputMemoryStream**.

---

## Overview

A Dart library to encode and decode various archive and compression formats.

The archive library currently supports the following codecs:

- Zip
- Tar
- ZLib
- GZip
- BZip2
- XZ (Encoder just stores, does not compress)
- Zstandard (zstd)

---

## Usage

**package:archive/archive.dart**
* Can be used for both web and native applications.

**package:archive/archive_io.dart**
  * Provides some extra utilities for 'dart:io' based applications.


#### Decoding a zip file in memory

```dart
import 'package:archive/archive.dart';
import 'dart:io';
void main() {
  final bytes = File('test.zip').readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final entry in archive) {
    if (entry.isFile) {
      final fileBytes = file.readBytes();
      File('out/${file.fullPathName}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(fileBytes);
    }
  }
}
```

#### Using InputFileStream and OutputFileStream to extract a zip:
```dart
import 'dart:io';
import 'package:archive/archive.dart';
void main() {
  // Use an InputFileStream to access the zip file without storing it in memory.
  // Note that using InputFileStream will result in an error from the web platform  
  // as there is no file system there.
  final inputStream = InputFileStream('test.zip');
  // Decode the zip from the InputFileStream. The archive will have the contents of the
  // zip, without having stored the data in memory. 
  final archive = ZipDecoder().decodeStream(inputStream);
  final symbolicLinks = []; // keep a list of the symbolic link entities, if any.
  // For all of the entries in the archive
  for (final file in archive) {
    // You should create symbolic links **after** the rest of the archive has been
    // extracted, otherwise the file being linked might not exist yet.
    if (file.isSymbolicLink) {
      symbolicLinks.add(file);
      continue;
    }
    if (file.isFile) {
      // Write the file content to a directory called 'out'.
      // In practice, you should make sure file.name doesn't include '..' paths
      // that would put it outside of the extraction directory.
      // An OutputFileStream will write the data to disk.
      final outputStream = OutputFileStream('out/${file.name}');
      // The writeContent method will decompress the file content directly to disk without
      // storing the decompressed data in memory. 
      entity.writeContent(outputStream);
      // Make sure to close the output stream so the File is closed.
      outputStream.closeSync();
    } else {
      // If the entity is a directory, create it. Normally writing a file will create
      // the directories necessary, but sometimes an archive will have an empty directory
      // with no files.
      Directory('out/${file.name}').createSync(recursive: true);
    }
  }
  // Create symbolic links **after** the rest of the archive has been extracted to make sure
  // the file being linked exists.
  for (final entity in symbolicLinks) {
    // Before using this in production code, you should ensure the symbolicLink path
    // points to a file within the archive, otherwise it could be a security issue.
    final link = Link('out/${entity.fullPathName}');
    link.createSync(entity.symbolicLink!, recursive: true);
  }
}
```

#### Showing progress while extracting:
`ProgressOutputStream` wraps any `OutputStream` and calls back with the number of bytes written
through it so far, at most once per 64 KiB.

Extracting a zip, with progress over the whole archive:
```dart
import 'package:archive/archive.dart';

void main() async {
  final archive = ZipDecoder().decodeStream(InputFileStream('test.zip'));
  // The zip directory records every file's unpacked size
  final total = archive.fold<int>(0, (sum, f) => sum + (f.isFile ? f.size : 0));
  var done = 0;
  for (final file in archive) {
    if (!file.isFile) continue;
    final out = ProgressOutputStream(OutputFileStream('out/${file.name}'),
        (written) => print('${(done + written) * 100 ~/ total}%'));
    file.writeContent(out);
    await out.close();
    done += file.size;
  }
}
```

Unpacking a `.tar.gz` into a `.tar`. A gzip stream does not say how big it unpacks, so the
progress is how much of the compressed file has been read:
```dart
import 'package:archive/archive.dart';

void main() async {
  final input = InputFileStream('data.tar.gz');
  final total = input.length;
  final out = ProgressOutputStream(OutputFileStream('data.tar'),
      (_) => print('${input.position * 100 ~/ total}%'));
  const GZipDecoder().decodeStream(input, out);
  await out.close();
  await input.close();
}
```

Decoding is synchronous, so in Flutter run it in `Isolate.run` and send the progress through a
`SendPort`, otherwise the UI will not repaint until it finishes.

### Dart async* StreamTransformers/ByteConversionSink/Converter support

Codecs that take data as it arrives expose a `Codec` with a converter for each
direction, the shape `dart:io` uses for `gzip`.

| codec | decoding                             | encoding                                     |
|-------|--------------------------------------|----------------------------------------------|
| xz    | `xzCodec.decoder`                    | `xzCodec.encoder` (stores, doesn't compress) |
| zstd  | `zstdCodec.decoder`                  | `zstdCodec.encoder`                          |
| bzip2 | `bzip2Codec.decoder`                 | `bzip2Codec.encoder`                         |
| tar   | `tarCodec.decoder`                   | `tarCodec.encoder`                           |
| zip   | `-- (impractical by format)*`        | `zipCodec.encoder**`                         |
| zlib  | `-- (dart already has zlib.decoder)` | `-- (dart already has zlib.encoder)`         |
| gzip  | `-- (dart already has gzip.decoder)` | `-- (dart already has gzip.encoder)`         |
> *Zip stores its central directory at the end of the file so decode converter is of no use here. 
> It needs to access data from the end of archive, while converter does not provide such access.
> **ZipCodec for encoder uses `streamed = true` by default, this means it enabled 3 general purpose flag, CRC remains
> filled with zeroes and goes to data descriptor with real data to consume less RAM. If default format is needed, use as 
> const ZipCodec(streamed: false);

Decoding as the bytes arrive, single-threaded, holding the window the archive
asks for and one chunk rather than the archive:

```dart
import 'package:archive/archive.dart';
import 'dart:io';

await for (final piece
    in File('data.xz').openRead().transform(xzCodec.decoder)) {
  // piece is the next part of the decoded data
}
```

A `.tar.zst` downloaded and unpacked as it arrives, without holding the body:

```dart
import 'package:path/path.dart' as p;

final request =
    await HttpClient().getUrl(Uri.parse('https://example.com/data.tar.zst'));
final HttpClientResponse response = await request.close();

await for (final TarEntry entry in response
    .transform(zstdCodec.decoder)
    .transform(tarCodec.decoder)) {
  final target = p.join('out', entry.name);
  if (!p.isWithin('out', target)) continue; // `../` would escape out/
  if (entry.type == TarEntryType.file) {
    await File(target).create(recursive: true);
    await entry.content.pipe(File(target).openWrite());
  }
}
```

An entry's `content` reads the bytes that follow its header in the same stream,
so read it inside the loop body, before the next entry. A skipped entry is
passed over for you. Kept for later, its `content` throws `StateError`.

Encoding the other way, so that a source and a destination that are themselves
streams need no buffer between them:

```dart
import 'package:archive/archive.dart';
import 'dart:io';

final out = File('data.xz').openWrite();
await File('data')
    .openRead()
    .transform(xzCodec.encoder)
    .pipe(out);
```

A `.tar.zst` packed straight into an upload, with no temporary file:

```dart
Stream<ArchiveFile> filesOf(Directory dir) async* {
  await for (final entity in dir.list(recursive: true)) {
    if (entity is File) {
      yield ArchiveFile.stream(
          p.relative(entity.path, from: dir.path),
          InputFileStream(entity.path));
    }
  }
}

final upload =
    await HttpClient().putUrl(Uri.parse('https://example.com/backup'));
upload.headers.contentType = ContentType('application', 'zstd');
await upload.addStream(filesOf(Directory('data'))
    .transform(tarCodec.encoder)      // Stream<ArchiveFile> -> Stream<List<int>>
    .transform(zstdCodec.encoder));
final response = await upload.close();
```

`zipCodec.encoder` packs the same `Stream<ArchiveFile>` with no second
transform, since zip deflates each entry itself:

```dart
final upload =
    await HttpClient().putUrl(Uri.parse('https://example.com/backup'));
upload.headers.contentType = ContentType('application', 'zip');
await upload.addStream(
    filesOf(Directory('data')).transform(zipCodec.encoder));
final response = await upload.close();
```


Both directions also take a whole buffer: `xzCodec.decode(bytes)` and
`xzCodec.encode(bytes)`, or the sinks directly through
`startChunkedConversion` for code that pushes rather than awaits.

The block checks are verified by default when decoding a stream, unlike the
other entry points: the compressed bytes are handed back as they pass, so there
is no second chance at the check. `XzCodec(verify: false)` skips them, which is
worth about 6% of the decode.

A failure reaches the stream as an error, and a sink that has failed reports the
same failure rather than reading what follows it.

### Running a codec off the UI isolate

The converters are asynchronous in shape only: the work for a piece runs to
completion synchronously. Longest single call over 3 MB fed in 16 KiB pieces,
AOT on an Apple M-series:

| call | worst single call |
| --- | --- |
| `zstdCodec.decoder` | 0.5 ms |
| `ZstdEncoderConverter(level: 3)` | 1.3 ms |
| `xzCodec.decoder` | 2.2 ms |
| `BZip2DecoderConverter()`, 100k blocks | 5 ms |
| `bzip2Codec.decoder`, 900k blocks | 34 ms |
| `bzip2Codec.encoder`, 900k blocks | 73 ms |
| `ZstdEncoderConverter(level: 19)` | 98 ms |
| `zipCodec.encoder` | one entry: 4 ms per 256 KiB, 67 ms per 4 MiB |

zip blocks for one whole entry, since deflate runs to the end of it in one go.
tar is not in the table: reading 20000 entries costs 42 ms in total, so the
cost of a `.tar.zst` is the zstd row. A frame is 16 ms at 60 Hz, so use an
isolate for the lower half of that table and for anything large. Keep the whole pipeline on the worker, so only paths
cross the boundary rather than every piece:

```dart
await Isolate.run(() async {
  final out = File('data.tar').openWrite();
  await File('data.tar.bz2').openRead().transform(bzip2Codec.decoder).pipe(out);
});
```

### Spreading one call over isolates

Two codecs split a single call across isolates: xz decoding and zstd
compression. Pass the options and the call returns at once, with the result
arriving through `onDone`, since an isolate cannot be waited on synchronously.
Where isolates do not exist, dart2js and dart2wasm, the same code runs in the
calling isolate and writes the same bytes.

zstd writes the frame `zstd -T` writes, which is not the frame the single
threaded encoder writes, and it is the same for any number of workers. Prefer
the file form: each worker reads its own job straight from disk, so the input
never sits in the calling isolate, and a gigabyte at level 6 costs 151 MB this
way against 2 GB through `encodeBytes`:

```dart
final input = InputFileStream('data.bin');
final output = OutputFileStream('data.bin.zst');
final completer = Completer<bool>();
ZstdEncoder(level: 6).encodeStream(input, output,
    multithread: ZstdMultithreadOptions(
      onDone: completer.complete,
      onError: (error, _) => completer.completeError(error),
      workers: 4,
    ));
await completer.future;
await output.close();
await input.close();
```

xz over a whole buffer, one block to a worker:

```dart
final completer = Completer<Uint8List>();
XZDecoder().decodeBytes(compressed,
    multithread: XZMultithreadOptions(
      onDone: completer.complete,
      onError: (error, _) => completer.completeError(error),
      workers: 4,
    ));
final data = await completer.future;
```

`decodeStream` takes the same options, and over an `InputFileStream` a worker
reads its own block through a window rather than holding the archive.

A zstd `Stream` takes them too, through the codec, and then `transform` reads
the way it always did:

```dart
await File('data.bin')
    .openRead()
    .transform(ZstdCodec(
      level: 6,
      multithread: ZstdMultithreadOptions(workers: 4),
    ).encoder)
    .pipe(File('data.bin.zst').openWrite());
```

The stream carries its own end and its own errors, so `onDone` stays empty
here. `startChunkedConversion` refuses the options rather than quietly falling
back: a sink owes its output before it returns, and a worker answers later.

`workers` never changes the bytes, only the time, and `memoryBudget` caps how
many of them run at once, a gigabyte by default: a zstd worker is charged for
its job, its prefix, its output and the level's tables, an xz one for the
dictionary its block names and the block itself, and at least one always runs.
xz adds `fileReadBufferSize`, the window a worker reads its block through when
it opens the file itself.

zstd's `jobSize` and `overlapLog` are the two that do change the bytes, the way
`zstd -T` does. A value that cannot be honoured throws `ArgumentError` at the
call rather than reaching `onError`, and an input too small to be worth
splitting takes the single threaded path on its own.

### Recognizing a format from its first bytes

`CodecsRecognizer` reads a header and says what wrote it, without decoding
anything:

```dart
import 'package:archive/archive.dart';
import 'dart:io';

final head = await File('data.bin').openRead(0, CodecsRecognizer.headerBytes)
    .fold<List<int>>(<int>[], (held, piece) => held..addAll(piece));

switch (CodecsRecognizer.recognize(head)) {
  case ArchiveFormat.zstd:
    // ...
  case ArchiveFormat.xz:
    // ...
  default:
    // ArchiveFormat.unknown
}
```

Each format is also its own check: `isGZip`, `isZLib`, `isBZip2`, `isXZ`,
`isZstd`, `isZip`, `isTar`.

How much of the file is needed depends on the format: two bytes for zlib, three
for gzip, four for bzip2, zstd and zip, six for xz. Only tar needs more, since a
header written before the ustar versions carries no magic at all and is
identified by the checksum over its whole 512 byte block. 263 bytes are enough
for a ustar tar, `CodecsRecognizer.headerBytes` for any of them.

Formats with no header of their own, raw LZMA and raw deflate among them, cannot
be recognized this way.

#### extractFileToDisk
`extractFileToDisk` is a convenience function to extract the contents of
an archive file directory to an output directory.
The type of archive it is will be determined by the file extension.
```dart
import 'package:archive/archive_io.dart';
// ...
extractFileToDisk('test.zip', 'out');
```
#### extractArchiveToDisk
`extractArchiveToDisk` is a convenience function to write the contents of an Archive
to an output directory.
```dart
import 'package:archive/archive_io.dart';
// ...
// Use an InputFileStream to access the zip file without storing it in memory.
final inputStream = InputFileStream('test.zip');
// Decode the zip from the InputFileStream. The archive will have the contents of the
// zip, without having stored the data in memory. 
final archive = ZipDecoder().decodeStream(inputStream);
extractArchiveToDisk(archive, 'out');
```
#### Zstandard

A dictionary, trained by `zstd --train`, is passed to both sides and named in
the frame header, so only the same dictionary reads the frame back:

```dart
final dictionary = ZstdDictionary(File('dict').readAsBytesSync());
final compressed =
    ZstdEncoder(level: 6, dictionary: dictionary).encodeBytes(bytes);
final data = ZstdDecoder(dictionary: dictionary).decodeBytes(compressed);
```

Unlike original zstd lib, compressions levels 19-22 do not require --ultra flag to work
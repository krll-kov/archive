import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

// The io file handle is imported directly rather than through
// file_handle.dart, whose conditional export resolves to the web class when
// the analyser has no platform in mind, and that one has no path
import '../../util/_file_handle_io.dart';
import '../../util/input_file_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/xxh64.dart';
import 'zstd_dictionary.dart';
import 'zstd_mt_frame_encoder.dart';

const bool zstdIsolatesSupported = true;

/// Compresses every job on an isolate, at most [workers] at a time, and
/// returns their output in job order. A job carries its own prefix, so nothing
/// is shared and the bytes do not depend on how many run at once.
///
/// The workers are spawned once and fed job after job: a fresh isolate per job
/// costs a heap and a set of tables each time, which is what made the memory
/// grow with the job count rather than with the pool
Future<List<Uint8List>> zstdMtCompressJobs(
    Uint8List src, List<int> starts, int prefixSize, int level,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    int cap = 0,
    bool firstIsFirstJob = true,
    int size = 0}) {
  // The job is copied out of the shared input once and then moved rather than
  // copied again: a message holding a Uint8List is serialised on its way to
  // the isolate, a transfer is not
  Object source(int start, int end, int prefix) =>
      TransferableTypedData.fromList(
          [Uint8List.fromList(Uint8List.sublistView(src, start - prefix, end))]);
  return _compress(starts, prefixSize, size > 0 ? size : src.length, level,
      source,
      jobSize: jobSize,
      overlapLog: overlapLog,
      workers: workers,
      cap: cap,
      firstIsFirstJob: firstIsFirstJob);
}

/// As [zstdMtCompressJobs], with each job read from the file itself, so the
/// input never sits in the calling isolate
Future<List<Uint8List>> zstdMtCompressFileJobs(String path, int offset,
    int size, List<int> starts, int prefixSize, int level,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    int cap = 0,
    void Function(Uint8List part)? onPart}) {
  Object source(int start, int end, int prefix) =>
      [path, offset + start - prefix, prefix + (end - start)];
  return _compress(starts, prefixSize, size, level, source,
      jobSize: jobSize,
      overlapLog: overlapLog,
      workers: workers,
      cap: cap,
      onPart: onPart);
}

/// The frame's checksum, taken over the file in one pass rather than over a
/// copy in memory. The jobs cannot help with it: XXH64 does not combine
int zstdMtFileDigest(String path, int offset, int size) {
  final hash = Xxh64()..reset();
  final file = File(path).openSync();
  try {
    file.setPositionSync(offset);
    final buffer = Uint8List(1 << 20);
    var left = size;
    while (left > 0) {
      final want = left < buffer.length ? left : buffer.length;
      final got = file.readIntoSync(buffer, 0, want);
      if (got <= 0) {
        break;
      }
      hash.update(buffer, 0, got);
      left -= got;
    }
  } finally {
    file.closeSync();
  }
  return hash.digestLow;
}

/// The file [input] reads from, as path, offset and length, or null when it is
/// not backed by one
List<Object>? zstdMtFileRegion(InputStream input) {
  if (input is! InputFileStream) {
    return null;
  }
  final handle = input.fileBuffer.file;
  if (handle is! FileHandle) {
    return null;
  }
  return [handle.path, input.fileOffset + input.position, input.length];
}

Future<List<Uint8List>> _compress(List<int> starts, int prefixSize, int size,
    int level, Object Function(int start, int end, int prefix) source,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    required int cap,
    bool firstIsFirstJob = true,
    void Function(Uint8List part)? onPart}) async {
  final parts = List<Uint8List?>.filled(starts.length, null);
  final cores = Platform.numberOfProcessors;
  // Zero means "as many as the machine has", one core left for the caller
  var pool = workers > 0 ? workers : cores - 1;
  if (cap > 0 && pool > cap) {
    pool = cap;
  }
  if (pool > starts.length) {
    pool = starts.length;
  }
  if (pool < 1) {
    pool = 1;
  }

  final receive = ReceivePort();
  final done = Completer<void>();
  final isolates = <Isolate>[];
  final held = <int, Uint8List>{};
  var written = 0;
  var next = 0;
  var left = starts.length;
  Object? failure;
  StackTrace? failureStack;

  void give(SendPort worker) {
    if (next >= starts.length) {
      worker.send(null);
      return;
    }
    final index = next++;
    final start = starts[index];
    final end = index + 1 < starts.length ? starts[index + 1] : size;
    final prefix = start < prefixSize ? start : prefixSize;
    worker.send([
      index,
      source(start, end, prefix),
      prefix,
      level,
      size,
      index == 0 && firstIsFirstJob,
      index == starts.length - 1,
      jobSize,
      overlapLog,
    ]);
  }

  receive.listen((message) {
    if (message is SendPort) {
      give(message);
      return;
    }
    final reply = message as List;
    final worker = reply[0] as SendPort;
    final index = reply[1] as int;
    final error = reply[3];
    if (error != null) {
      failure ??= error;
      failureStack ??= StackTrace.fromString(reply[4] as String);
    } else {
      final part =
          (reply[2] as TransferableTypedData).materialize().asUint8List();
      if (onPart == null) {
        parts[index] = part;
      } else {
        // Only the parts that ran ahead of their turn are held, the rest go
        // straight out, so a frame of any size costs the pool and not itself
        held[index] = part;
        while (held.containsKey(written)) {
          onPart(held.remove(written)!);
          written++;
        }
      }
    }
    left--;
    if (left == 0) {
      if (!done.isCompleted) {
        done.complete();
      }
      return;
    }
    give(worker);
  });

  try {
    for (var i = 0; i < pool; i++) {
      isolates.add(await Isolate.spawn(_zstdMtWorker, receive.sendPort,
          onError: receive.sendPort, errorsAreFatal: true));
    }
    await done.future;
  } finally {
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    receive.close();
  }

  if (failure != null) {
    Error.throwWithStackTrace(failure!, failureStack ?? StackTrace.current);
  }
  if (onPart != null) {
    return const [];
  }
  return [for (final part in parts) part!];
}

/// The compressed parts of [input], in job order, with the jobs cut out of the
/// bytes as they arrive and handed to a pool of at most [workers]. The header
/// and the checksum are the caller's, as everywhere else here
Stream<Uint8List> zstdMtCompressStream(Stream<List<int>> input, int level,
    {required int jobSize,
    required int overlapLog,
    required int workers,
    int cap = 0,
    ZstdDictionary? dictionary}) async* {
  final geometry =
      ZstdMtFrameEncoder.geometry(level, zstdMtSizeUnknown,
          jobSize: jobSize, overlapLog: overlapLog);
  final ring = ZstdMtRing(geometry[0], geometry[1]);
  final cores = Platform.numberOfProcessors;
  var pool = workers > 0 ? workers : cores - 1;
  if (cap > 0 && pool > cap) {
    pool = cap;
  }
  if (pool < 1) {
    pool = 1;
  }

  // The workers are spawned once and fed job after job, as everywhere else
  // here: an isolate per job pays for a heap and a table set each time
  final receive = ReceivePort();
  final isolates = <Isolate>[];
  final idle = <SendPort>[];
  final queued = <List<Object>>[];
  final held = <int, Uint8List>{};
  final parts = StreamController<Uint8List>();
  var written = 0;
  var sent = 0;
  var back = 0;
  var ended = false;
  Completer<void>? room;
  Object? failure;
  StackTrace? failureStack;

  void hand(SendPort worker) {
    if (queued.isEmpty) {
      idle.add(worker);
      return;
    }
    worker.send(queued.removeAt(0));
  }

  void finishIfDone() {
    if (ended && back == sent && !parts.isClosed) {
      if (failure != null) {
        parts.addError(failure!, failureStack);
      }
      unawaited(parts.close());
    }
  }

  receive.listen((message) {
    if (message is SendPort) {
      hand(message);
      return;
    }
    final reply = message as List;
    final worker = reply[0] as SendPort;
    final index = reply[1] as int;
    final error = reply[3];
    if (error != null) {
      failure ??= error;
      failureStack ??= StackTrace.fromString(reply[4] as String);
    } else {
      held[index] =
          (reply[2] as TransferableTypedData).materialize().asUint8List();
      while (held.containsKey(written)) {
        parts.add(held.remove(written)!);
        written++;
      }
    }
    back++;
    if (room != null && !room!.isCompleted && sent - back < pool) {
      room!.complete();
    }
    hand(worker);
    finishIfDone();
  });

  for (var i = 0; i < pool; i++) {
    isolates.add(await Isolate.spawn(_zstdMtWorker, receive.sendPort,
        onError: receive.sendPort, errorsAreFatal: true));
  }

  void submit(Uint8List job, int prefix, bool first, bool last) {
    // The dictionary belongs to the first job and does not cross the port, so
    // that one is compressed here and takes its place in the order like any
    // other part
    if (first && dictionary != null) {
      final content = dictionary.content;
      final held0 = Uint8List(content.length + job.length)
        ..setRange(0, content.length, content)
        ..setRange(content.length, content.length + job.length, job);
      final out = OutputMemoryStream();
      ZstdMtFrameEncoder.encodeJob(
          held0, content.length, out, level, zstdMtSizeUnknown,
          firstJob: true,
          lastJob: last,
          jobSize: jobSize,
          overlapLog: overlapLog,
          dictionary: dictionary);
      held[sent] = out.getBytes();
      sent++;
      back++;
      while (held.containsKey(written)) {
        parts.add(held.remove(written)!);
        written++;
      }
      finishIfDone();
      return;
    }
    final message = <Object>[
      sent,
      TransferableTypedData.fromList([job]),
      prefix,
      level,
      zstdMtSizeUnknown,
      first,
      last,
      jobSize,
      overlapLog,
    ];
    sent++;
    if (idle.isEmpty) {
      queued.add(message);
    } else {
      idle.removeAt(0).send(message);
    }
  }

  try {
    // The reader runs beside the yielding, so parts leave as they finish
    // rather than piling up behind a source that never pauses
    unawaited(() async {
      try {
        await for (final chunk in input) {
          for (final job in ring.add(chunk)) {
            submit(job, sent == 0 ? 0 : geometry[1], sent == 0, false);
            // No more jobs in flight than workers: each one holds its own
            // buffer, so a looser gate is paid for in memory
            while (sent - back >= pool) {
              room = Completer<void>();
              await room!.future;
            }
          }
        }
        final tail = ring.close();
        submit(tail, sent == 0 ? 0 : geometry[1], sent == 0, true);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
      ended = true;
      finishIfDone();
    }());
    yield* parts.stream;
  } finally {
    for (final isolate in isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    receive.close();
  }
}

/// One worker: it takes job after job and keeps its heap between them
void _zstdMtWorker(SendPort toMain) {
  final port = ReceivePort();
  toMain.send(port.sendPort);
  port.listen((message) {
    if (message == null) {
      port.close();
      return;
    }
    final job = message as List;
    final index = job[0] as int;
    try {
      final source = job[1];
      final Uint8List buffer;
      if (source is TransferableTypedData) {
        buffer = source.materialize().asUint8List();
      } else {
        final region = source as List;
        final file = File(region[0] as String).openSync();
        try {
          file.setPositionSync(region[1] as int);
          buffer = file.readSync(region[2] as int);
        } finally {
          file.closeSync();
        }
      }
      final out = OutputMemoryStream();
      ZstdMtFrameEncoder.encodeJob(
          buffer, job[2] as int, out, job[3] as int, job[4] as int,
          firstJob: job[5] as bool,
          lastJob: job[6] as bool,
          jobSize: job[7] as int,
          overlapLog: job[8] as int);
      toMain.send([
        port.sendPort,
        index,
        TransferableTypedData.fromList([out.getBytes()]),
        null,
        null,
      ]);
    } catch (error, stack) {
      toMain.send([port.sendPort, index, null, '$error', '$stack']);
    }
  });
}

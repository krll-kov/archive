import 'dart:typed_data';

import '../../util/input_stream.dart';
import 'xz_index.dart';

/// True when the decode can run on isolates. It is false here. dart2js and
/// dart2wasm cannot start an isolate. The decode runs in the calling isolate
const bool xzIsolatesSupported = false;

/// Where an xz archive sits in a file on disk: the path, offset and length
class XZFileRegion {
  final String path;
  final int offset;
  final int length;

  const XZFileRegion(this.path, this.offset, this.length);
}

/// Always null here. This platform has no files to read blocks from
XZFileRegion? xzFileRegionOf(InputStream input) => null;

/// Nothing reaches this on the web. Callers need a region from
/// [xzFileRegionOf] first. It returns null here
XZLayout? xzLayoutOfFile(XZFileRegion region, {int? maxUncompressedSize}) =>
    null;

Stream<Uint8List> xzDecodeStreamMultithreaded(Stream<List<int>> input,
        {required bool verify, int? workers, int? memoryBudget}) =>
    throw UnsupportedError('Isolates are not available on this platform');

/// Never called on this platform. Callers check [xzIsolatesSupported] first
Future<bool> xzDecodeMultithreaded({
  Uint8List? bytes,
  String? path,
  int fileOffset = 0,
  int fileLength = 0,
  required XZLayout? layout,
  required bool verify,
  required int maxPreallocateSize,
  int? workers,
  int? memoryBudget,
  required void Function(int outputOffset, Uint8List chunk) onChunk,
  void Function(int outputOffset, bool ok)? onBlockDone,
  void Function(String reason)? onFailureReason,
  bool orderedOutput = false,
  required int fileReadBufferSize,
}) =>
    throw UnsupportedError('Isolates are not available on this platform');

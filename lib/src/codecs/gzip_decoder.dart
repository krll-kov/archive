import 'dart:typed_data';

import '../util/input_stream.dart';
import '../util/output_stream.dart';
import 'zlib/_gzip_decoder.dart';

/// Decompress data with the gzip format decoder.
/// The actual decoder used will depend on the platform the code is run on.
/// In a 'dart:io' based platform, like Flutter, the native GZipCodec will
/// be used to improve performance. On web platforms, a Dart implementation
/// of ZLib will be used, via the [Inflate] class.
/// If you want to force the use of the Dart implementation, you can use the
/// [GZipDecoderWeb] class.
class GZipDecoder {
  const GZipDecoder();

  /// Decompress the given [bytes] with the GZip format.
  ///
  /// {@macro archive.verify_throw_on_error}
  ///
  /// On dart:io only a single member gzip gets `ArchiveChecksumException`.
  Uint8List decodeBytes(List<int> bytes,
          {bool verify = false, bool throwOnError = false}) =>
      platformGZipDecoder.decodeBytes(bytes,
          verify: verify, throwOnError: throwOnError);

  /// Decompress the given [input] with the GZip format, writing the
  /// decompressed data to the [output] stream.
  ///
  /// {@macro archive.verify_throw_on_error}
  ///
  /// On dart:io only a single member gzip gets `ArchiveChecksumException`.
  bool decodeStream(InputStream input, OutputStream output,
          {bool verify = false, bool throwOnError = false}) =>
      platformGZipDecoder.decodeStream(input, output,
          verify: verify, throwOnError: throwOnError);
}

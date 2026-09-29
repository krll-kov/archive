import 'dart:convert';
import 'dart:typed_data';

import '../../archive/compression_type.dart';
import '../../util/aes.dart';
import '../../util/archive_exception.dart';
import '../../util/chunked_sink.dart';
import '../../util/crc32.dart';
import '../../util/decode_guard.dart';
import '../../util/encryption.dart';
import '../../util/file_content.dart';
import '../../util/input_memory_stream.dart';
import '../../util/input_stream.dart';
import '../../util/output_memory_stream.dart';
import '../../util/output_stream.dart';
import '../bzip2_decoder.dart';
import '../lzma/lzma_decoder.dart';
import '../zlib_decoder.dart';
import 'zip_file_header.dart';

/// Internal class used by [ZipDecoder].
class ZipAesHeader {
  static const signature = 39169;

  int vendorVersion;
  String vendorId;
  int encryptionStrength; // 1: 128-bit, 2: 192-bit, 3: 256-bit
  int compressionMethod;

  ZipAesHeader(this.vendorVersion, this.vendorId, this.encryptionStrength,
      this.compressionMethod);
}

enum ZipEncryptionMode { none, zipCrypto, aes }

const _compressionTypes = <int, CompressionType>{
  0: CompressionType.none,
  8: CompressionType.deflate,
  12: CompressionType.bzip2,
  14: CompressionType.lzma
};

/// A file object used by [ZipDecoder].
class ZipFile extends FileContent {
  static const zipSignature = 0x04034b50;
  static const zipCompressionStore = 0;
  static const zipCompressionDeflate = 8;
  static const zipCompressionBZip2 = 12;
  static const zipCompressionLzma = 14;
  static const zipCompressionAexEncryption = 99;

  int version = 0;
  int flags = 0;
  CompressionType compressionMethod = CompressionType.none;
  int lastModFileTime = 0;
  int lastModFileDate = 0;
  int crc32 = 0;
  int compressedSize = 0;
  int uncompressedSize = 0;
  String filename = '';
  Uint8List? extraField;
  ZipFileHeader? header;
  bool verify = false;
  bool throwOnError = false;
  int? unsupportedMethod;

  // Content of the file. If compressionMethod is not STORE, then it is
  // still compressed.
  InputStream? _rawContent;
  int? _computedCrc32;
  ZipEncryptionMode _encryptionType = ZipEncryptionMode.none;
  ZipAesHeader? _aesHeader;
  String? _password;

  // Commit https://github.com/brendan-duncan/archive/commit/11131912b01e5a2b46c8ac4916d945bdad752f4c
  // moved these keys to BigInt: on web k1 * 134775813 lost bits.
  // _updateKeys splits that multiply into 16-bit halves that stay below 2^48,
  // so an int is exact on web too and ZipCrypto decrypts 6.6-8.6x faster.
  final _keys = <int>[0, 0, 0];

  ZipFile(this.header);

  @override
  bool get isCompressed =>
      _rawContent != null && compressionMethod != CompressionType.none;

  bool get hasCrc32 => _aesHeader?.vendorVersion != 2;

  void read(InputStream input, {String? password, bool verify = false}) {
    final sig =
        input.position >= 0 && input.length >= 30 ? input.readUint32() : 0;
    if (sig != zipSignature) {
      if (verify) {
        throw ArchiveException(
            'zip: local header of ${header?.filename} is damaged');
      }
      return;
    }

    version = input.readUint16();
    flags = input.readUint16();
    final compression = input.readUint16();
    compressionMethod = _compressionTypes[compression] ?? CompressionType.none;
    lastModFileTime = input.readUint16();
    lastModFileDate = input.readUint16();
    crc32 = input.readUint32();
    compressedSize = input.readUint32();
    uncompressedSize = input.readUint32();
    final fnLen = input.readUint16();
    final exLen = input.readUint16();
    if (verify && fnLen + exLen > input.length) {
      throw ArchiveException(
          'zip: local header of ${header?.filename} is damaged');
    }
    filename = input.readString(size: fnLen);
    extraField = input.readBytes(exLen).toUint8List();

    // Use the compressedSize and uncompressedSize from the CFD header.
    // For Zip64, the sizes in the local header will be 0xFFFFFFFF.
    // header is never null here. ZipFileHeader creates every ZipFile and passes
    // itself. The null checks stay for a future ZipFile without a header
    compressedSize = header?.compressedSize ?? compressedSize;
    uncompressedSize = header?.uncompressedSize ?? uncompressedSize;
    if (verify &&
        (compressedSize < 0 ||
            uncompressedSize < 0 ||
            compressedSize > input.length)) {
      throw ArchiveException('zip: content of $filename is truncated');
    }

    _encryptionType = (flags & 0x1) != 0
        ? ZipEncryptionMode.zipCrypto
        : ZipEncryptionMode.none;

    _password = password;

    // Read compressedSize bytes for the compressed data.
    _rawContent = input.readBytes(header!.compressedSize);

    if (_encryptionType != ZipEncryptionMode.none && exLen > 2) {
      final extras = InputMemoryStream(extraField!);
      while (extras.length >= 4) {
        final id = extras.readUint16();
        final size = extras.readUint16();
        if (size > extras.length) {
          break;
        }
        final extra = extras.readBytes(size);
        if (id == ZipAesHeader.signature && size >= 7) {
          final vendorVersion = extra.readUint16();
          final vendorId = extra.readString(size: 2);
          final encryptionStrength = extra.readByte();
          final compressionMethod = extra.readUint16();

          _encryptionType = ZipEncryptionMode.aes;
          _aesHeader = ZipAesHeader(
              vendorVersion, vendorId, encryptionStrength, compressionMethod);

          // compressionMethod in the file header will be 99 for aes encrypted
          // files. The compressionMethod value in the AES extraField stores the
          // actual compressionMethod.
          this.compressionMethod =
              _compressionTypes[_aesHeader!.compressionMethod] ??
                  CompressionType.none;
        }
      }
    }
    final method = _aesHeader?.compressionMethod ?? compression;
    unsupportedMethod = _compressionTypes.containsKey(method) ? null : method;

    // If bit 3 (0x08) of the flags field is set, then the CRC-32 and file
    // sizes are not known when the header is written. The fields in the
    // local header are filled with zero, and the CRC-32 and size are
    // appended in a 12-byte structure (optionally preceded by a 4-byte
    // signature) immediately after the compressed data:
    if (verify && flags & 0x08 != 0 && input.length < 12) {
      throw ArchiveException(
          'zip: data descriptor of ${header?.filename} is damaged');
    }
    if (flags & 0x08 != 0 && input.length >= 12) {
      final sigOrCrc = input.readUint32();
      final zip64 = _hasZip64(extraField);
      var hasSignature = sigOrCrc == 0x08074b50;
      if (hasSignature && header?.crc32 == sigOrCrc) {
        final sizes = input.peekBytes(zip64 ? 16 : 8);
        if (sizes.length == (zip64 ? 16 : 8)) {
          final compressed = zip64 ? sizes.readUint64() : sizes.readUint32();
          final uncompressed = zip64 ? sizes.readUint64() : sizes.readUint32();
          if (compressed == compressedSize &&
              uncompressed == uncompressedSize) {
            hasSignature = false;
          }
        }
      }
      final descriptorSize = (zip64 ? 16 : 8) + (hasSignature ? 4 : 0);
      if (verify && input.length < descriptorSize) {
        throw ArchiveException(
            'zip: data descriptor of ${header?.filename} is damaged');
      }
      if (hasSignature) {
        crc32 = input.readUint32();
      } else {
        crc32 = sigOrCrc;
      }

      // APPNOTE 4.3.9.2: the sizes are 8 bytes each when a zip64 extra field is
      // present for the file. Only the local field says that. A central one can
      // carry an offset past 4 GB while the sizes here stay 4 bytes, and an
      // entry whose central field holds the sizes needs nothing from here
      final central = header;
      final descriptorCompressed =
          zip64 ? input.readUint64() : input.readUint32();
      final descriptorUncompressed =
          zip64 ? input.readUint64() : input.readUint32();
      // APPNOTE 4.4.8: the correct sizes go in both the descriptor and the
      // central directory, so the central ones win and these fill in only what
      // it left at zero. Do not drop the read: an archive whose central
      // directory carries no sizes has them nowhere else
      // central is never null here. ZipFileHeader creates every ZipFile and
      // passes itself. The null checks stay for a future ZipFile without
      // a header
      if (central == null || central.compressedSize == 0) {
        compressedSize = descriptorCompressed;
      }
      if (central == null || central.uncompressedSize == 0) {
        uncompressedSize = descriptorUncompressed;
      }
    }
  }

  /// Whether [extra] holds a zip64 extended information field, id 0x0001
  static bool _hasZip64(Uint8List? extra) {
    if (extra == null) {
      return false;
    }
    var at = 0;
    while (at + 4 <= extra.length) {
      final id = extra[at] | (extra[at + 1] << 8);
      final size = extra[at + 2] | (extra[at + 3] << 8);
      if (id == 0x0001) {
        return true;
      }
      at += 4 + size;
    }
    return false;
  }

  /// This will decompress the data (if necessary) in order to calculate the
  /// crc32 checksum for the decompressed data and verify it with the value
  /// stored in the zip.
  bool verifyCrc32() {
    final contentStream = _getStream();
    _computedCrc32 ??= getCrc32(contentStream.toUint8List());
    return !hasCrc32 ||
        (_computedCrc32 == crc32 &&
            (header == null || _computedCrc32 == header!.crc32));
  }

  @override
  void decompress(OutputStream output) {
    guardDecode('zip', verify, throwOnError, () {
      if (!verify) {
        final start = output.length;
        _decompress(output);
        if (throwOnError) {
          _checkSize(output.length - start);
        }
        return true;
      }
      final crc = _Crc32Tee(output);
      final tee = SinkOutputStream(crc);
      _decompress(tee);
      tee.flush();
      _checkSize(tee.length);
      _checkCrc32(crc.value);
      return true;
    });
  }

  void _decrypt() {
    if (_encryptionType != ZipEncryptionMode.none) {
      if (_rawContent!.length <= 0) {
        _encryptionType = ZipEncryptionMode.none;
      } else {
        if (_encryptionType == ZipEncryptionMode.zipCrypto) {
          _rawContent = _decodeZipCrypto(_rawContent!);
        } else if (_encryptionType == ZipEncryptionMode.aes) {
          _rawContent = _decodeAes(_rawContent!);
        }
        _encryptionType = ZipEncryptionMode.none;
      }
    }
  }

  void _decompress(OutputStream output) {
    if (_rawContent == null) {
      return;
    }
    _checkMethod();

    _decrypt();

    if (compressionMethod == CompressionType.deflate) {
      final savePos = _rawContent!.position;
      // Raw deflate has no checksum of its own, zip checks CRC32
      // in _checkCrc32
      ZLibDecoder()
          .decodeStream(_rawContent!, output, raw: true, throwOnError: true);
      _rawContent!.setPosition(savePos);
    } else if (compressionMethod == CompressionType.bzip2) {
      final savePos = _rawContent!.position;
      final ok = BZip2Decoder().decodeStream(_rawContent!, output);
      _rawContent!.setPosition(savePos);
      if (!ok) {
        throw ArchiveException('Invalid bzip2 data for $filename');
      }
    } else if (compressionMethod == CompressionType.lzma) {
      _decodeLzma(output);
    } else {
      final savePos = _rawContent!.position;
      output.writeStream(_rawContent!);
      _rawContent!.setPosition(savePos);
    }
  }

  void _decodeLzma(OutputStream output) {
    final input = _rawContent!;
    final savePos = input.position;
    try {
      input.skip(2);
      final propertiesSize = input.readUint16();
      final properties = input.readBytes(propertiesSize).toUint8List();
      if (properties.length < 5 || properties[0] >= 9 * 5 * 5) {
        throw ArchiveException('Invalid LZMA properties for $filename');
      }
      final bits = properties[0];
      final dictionarySize = properties[1] |
          (properties[2] << 8) |
          (properties[3] << 16) |
          (properties[4] << 24);
      final decoder = LzmaDecoder()
        ..dictionaryLimit = dictionarySize < 4096 ? 4096 : dictionarySize
        ..reset(
            literalContextBits: bits % 9,
            literalPositionBits: bits ~/ 9 % 5,
            positionBits: bits ~/ 45,
            resetDictionary: true);
      decoder.decodeToOutput(input, uncompressedSize, output);
    } on ArchiveException {
      rethrow;
    } catch (error) {
      if (!isDecodeDataError(error)) {
        rethrow;
      }
      throw ArchiveException('Invalid LZMA data for $filename: $error');
    } finally {
      input.setPosition(savePos);
    }
  }

  @override
  int get length => getRawContent().length;

  /// Get the decompressed content from the file. The file isn't decompressed
  /// until it is requested.
  @override
  InputStream getStream({bool decompress = true}) {
    InputStream stream = InputMemoryStream(Uint8List(0));
    guardDecode('zip', verify, throwOnError, () {
      stream = _getStream(decompress: decompress);
      if ((verify || throwOnError) && decompress) {
        _checkSize(stream.length);
      }
      if (verify && decompress) {
        if (stream is! InputMemoryStream &&
            stream.length <= _maxVerifyBufferSize) {
          stream = InputMemoryStream(stream.toUint8List());
        }
        _checkCrc32(_crc32Of(stream));
      }
      return true;
    });
    return stream;
  }

  InputStream _getStream({bool decompress = true}) {
    if (_rawContent == null) {
      return InputMemoryStream(Uint8List(0));
    }
    _decrypt();

    if (!decompress) {
      return _rawContent!;
    }
    _checkMethod();

    const maxDecodeBufferSize = 500 * 1024 * 1024; // 500MB

    if (compressionMethod == CompressionType.deflate) {
      final savePos = _rawContent!.position;
      late Uint8List content;
      if (_rawContent!.length <= maxDecodeBufferSize) {
        final compressed = _rawContent!.toUint8List();
        // Raw deflate has no checksum of its own, zip checks CRC32
        // in _checkCrc32
        content = ZLibDecoder()
            .decodeBytes(compressed, raw: true, throwOnError: true);
      } else {
        final decompress = OutputMemoryStream(
            size: uncompressedSize <= maxDecodeBufferSize
                ? uncompressedSize
                : maxDecodeBufferSize);
        // Raw deflate has no checksum of its own, zip checks CRC32
        // in _checkCrc32
        ZLibDecoder().decodeStream(_rawContent!, decompress,
            raw: true, throwOnError: true);
        content = decompress.getBytes();
      }
      _rawContent!.setPosition(savePos);
      return InputMemoryStream(content);
    } else if (compressionMethod == CompressionType.bzip2) {
      final output = OutputMemoryStream();
      final savePos = _rawContent!.position;
      final ok = BZip2Decoder().decodeStream(_rawContent!, output);
      final content = output.getBytes();
      _rawContent!.setPosition(savePos);
      if (!ok) {
        throw ArchiveException('Invalid bzip2 data for $filename');
      }
      return InputMemoryStream(content);
    } else if (compressionMethod == CompressionType.lzma) {
      final output = OutputMemoryStream();
      _decodeLzma(output);
      return InputMemoryStream(output.getBytes());
    } else {
      // Copy of stored entry needed 1.3 GB RAM for 1 GB entry, so we read file
      // on demand and verify buffers at most 1 MB. InputFileStream.subset()
      // starts at 0, so we pass current position
      return _rawContent!.subset(position: _rawContent!.position);
    }
  }

  static const _maxVerifyBufferSize = 1 << 20;

  static int _crc32Of(InputStream stream) {
    if (stream is InputMemoryStream) {
      return getCrc32(stream.toUint8List());
    }
    final probe = stream.subset(position: stream.position);
    final chunk = Uint8List(1 << 20);
    var crc = 0;
    while (true) {
      final got = probe.readInto(chunk, 0, chunk.length);
      if (got <= 0) {
        return crc;
      }
      crc = getCrc32(Uint8List.sublistView(chunk, 0, got), crc);
    }
  }

  Uint8List getRawContent() {
    if (_rawContent == null) {
      return Uint8List(0);
    }
    return _rawContent!.toUint8List();
  }

  @override
  String toString() => filename;

  List<Uint8List?> _passwordBytes() {
    final password = _password;
    if (password == null) {
      return [null];
    }
    final utf = Uint8List.fromList(utf8.encode(password));
    final old = Uint8List.fromList(password.codeUnits);
    return Uint8ListEquality.equals(utf, old) ? [utf] : [utf, old];
  }

  void _initKeys(Uint8List password) {
    _keys[0] = 305419896;
    _keys[1] = 591751049;
    _keys[2] = 878082192;
    for (final c in password) {
      _updateKeys(c);
    }
  }

  void _updateKeys(int c) {
    _keys[0] = getCrc32Byte(_keys[0], c);
    final k1 = (_keys[1] + (_keys[0] & 0xff)) & 0xffffffff;
    // On web an int is exact only below 2^53, and k1 * 134775813 reaches 2^59.
    // Multiplying by 16-bit halves keeps every partial product below 2^48.
    _keys[1] =
        (k1 * 0x8405 + (((k1 * 0x0808) & 0xffff) << 16) + 1) & 0xffffffff;
    _keys[2] = getCrc32Byte(_keys[2], _keys[1] >> 24);
  }

  int _decryptByte() {
    final temp = (_keys[2] & 0xffff) | 2;
    return ((temp * (temp ^ 1)) >> 8) & 0xff;
  }

  int _decodeByte(int c) {
    c ^= _decryptByte();
    _updateKeys(c);
    return c;
  }

  InputStream _decodeZipCrypto(InputStream input) {
    if (_rawContent == null) {
      return InputMemoryStream(Uint8List(0));
    }

    final start = _rawContent!.position;
    final check =
        flags & 0x08 != 0 ? (lastModFileTime >> 8) & 0xff : crc32 >>> 24;
    final candidates = [
      for (final password in _passwordBytes())
        if (password != null) password
    ];
    final passing = [
      for (final password in candidates)
        if (_zipCryptoHeader(password, start) == check) password
    ];
    // ZipCrypto checks 1 byte, so a wrong candidate passes 1 time in 256.
    // This keeps archives with password created with previous package versions
    // bytes readable
    if (passing.length > 1) {
      for (final password in passing) {
        final bytes = _zipCryptoBody(password, start);
        if (_plainCrc32(bytes) == crc32) {
          return InputMemoryStream(bytes);
        }
      }
    }
    if (passing.isEmpty) {
      for (final password in candidates) {
        final bytes = _zipCryptoBody(password, start);
        if (_plainCrc32(bytes) == crc32) {
          return InputMemoryStream(bytes);
        }
      }
      throw ArchivePasswordException(
          'zip: wrong or missing password for $filename');
    }
    return InputMemoryStream(_zipCryptoBody(passing.first, start));
  }

  int _zipCryptoHeader(Uint8List? password, int start) {
    _rawContent!.setPosition(start);
    if (password != null) {
      _initKeys(password);
    }
    var last = 0;
    for (var k = 0; k < 12; ++k) {
      last = _decodeByte(_rawContent!.readByte());
    }
    return last;
  }

  Uint8List _zipCryptoBody(Uint8List? password, int start) {
    _zipCryptoHeader(password, start);
    final bytes = _rawContent is InputMemoryStream
        ? Uint8List.fromList(_rawContent!.toUint8List())
        : _rawContent!.toUint8List();
    for (var i = 0; i < bytes.length; ++i) {
      final temp = bytes[i] ^ _decryptByte();
      _updateKeys(temp);
      bytes[i] = temp;
    }
    return bytes;
  }

  int? _plainCrc32(Uint8List decrypted) {
    final raw = _rawContent;
    final type = _encryptionType;
    _rawContent = InputMemoryStream(decrypted);
    _encryptionType = ZipEncryptionMode.none;
    try {
      return getCrc32(getStream().toUint8List());
    } catch (_) {
      return null;
    } finally {
      _rawContent = raw;
      _encryptionType = type;
    }
  }

  InputStream _decodeAes(InputStream input) {
    Uint8List salt;
    int keySize = 16;
    if (_aesHeader!.encryptionStrength == 1) {
      // 128-bit
      salt = input.readBytes(8).toUint8List();
      keySize = 16;
    } else if (_aesHeader!.encryptionStrength == 2) {
      // 192-bit
      salt = input.readBytes(12).toUint8List();
      keySize = 24;
    } else {
      // 256-bit
      salt = input.readBytes(16).toUint8List();
      keySize = 32;
    }

    final verify = input.readBytes(2).toUint8List();
    final dataBytes = input.readBytes(input.length - 10);
    final dataMac = input.readBytes(10);

    ArchiveException failure = ArchivePasswordException('password error');
    for (final password in _passwordBytes()) {
      if (password == null) {
        continue;
      }
      final derivedKey = _deriveKey(password, salt, derivedKeyLength: keySize);
      final keyData = Uint8List.fromList(derivedKey.sublist(0, keySize));
      final hmacKeyData =
          Uint8List.fromList(derivedKey.sublist(keySize, keySize * 2));
      // var authCode = deriveKey.sublist(keySize, keySize*2);
      final pwdCheck = derivedKey.sublist(keySize * 2, keySize * 2 + 2);
      if (!Uint8ListEquality.equals(pwdCheck, verify)) {
        continue;
      }

      // InputMemoryStream gives view into buffer, and decrypting it in
      // place corrupts zip. InputFileStream gives new bytes
      final bytes = dataBytes is InputMemoryStream
          ? Uint8List.fromList(dataBytes.toUint8List())
          : dataBytes.toUint8List();
      final aes = Aes(keyData, hmacKeyData, keySize);
      aes.processData(bytes, 0, bytes.length);
      if (!Uint8ListEquality.equals(dataMac.toUint8List(), aes.mac)) {
        failure = ArchiveChecksumException('macs don\'t match');
        continue;
      }
      return InputMemoryStream(bytes);
    }
    throw failure;
  }

  static Uint8List deriveKey(String password, Uint8List salt,
          {int derivedKeyLength = 32}) =>
      _deriveKey(Uint8List.fromList(utf8.encode(password)), salt,
          derivedKeyLength: derivedKeyLength);

  static Uint8List _deriveKey(Uint8List passwordBytes, Uint8List salt,
      {int derivedKeyLength = 32}) {
    const iterationCount = 1000;
    final totalSize = (derivedKeyLength * 2) + 2;

    final params = PcPbkdf2Parameters(salt, iterationCount, totalSize);
    final keyDerivator = PcPBKDF2KeyDerivator(PcHMac(PcSHA1Digest(), 64));

    keyDerivator.init(params);
    return keyDerivator.process(passwordBytes);
  }

  @override
  Future<void> close() async {
    await _rawContent?.close();
  }

  @override
  void closeSync() {
    _rawContent?.closeSync();
  }

  @override
  void write(OutputStream output) => output.writeStream(getStream());

  void _checkCrc32(int value) {
    if (hasCrc32 &&
        (value != crc32 || (header != null && value != header!.crc32))) {
      throw ArchiveChecksumException('zip: CRC32 of $filename does not match');
    }
  }

  void _checkMethod() {
    if (unsupportedMethod != null) {
      throw ArchiveException(
          'zip: unsupported compression method for $filename');
    }
  }

  void _checkSize(int size) {
    if (size != uncompressedSize) {
      throw ArchiveException(
          'zip: uncompressed size of $filename does not match');
    }
  }
}

class _Crc32Tee implements Sink<List<int>> {
  final OutputStream output;
  var value = 0;

  _Crc32Tee(this.output);

  @override
  void add(List<int> data) {
    value = getCrc32(data, value);
    output.writeBytes(data);
  }

  @override
  void close() {}
}

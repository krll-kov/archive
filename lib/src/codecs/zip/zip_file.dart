import 'dart:typed_data';

import '../../archive/compression_type.dart';
import '../../util/aes.dart';
import '../../util/archive_exception.dart';
import '../../util/crc32.dart';
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

  // Content of the file. If compressionMethod is not STORE, then it is
  // still compressed.
  InputStream? _rawContent;
  int? _computedCrc32;
  ZipEncryptionMode _encryptionType = ZipEncryptionMode.none;
  ZipAesHeader? _aesHeader;
  String? _password;

  final _keys = <BigInt>[BigInt.from(0), BigInt.from(0), BigInt.from(0)];

  ZipFile(this.header);

  @override
  bool get isCompressed =>
      _rawContent != null && compressionMethod != CompressionType.none;

  bool get hasCrc32 => _aesHeader?.vendorVersion != 2;

  void read(InputStream input, {String? password}) {
    final sig = input.readUint32();
    if (sig != zipSignature) {
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
    filename = input.readString(size: fnLen);
    extraField = input.readBytes(exLen).toUint8List();

    // Use the compressedSize and uncompressedSize from the CFD header.
    // For Zip64, the sizes in the local header will be 0xFFFFFFFF.
    // header is never null here. ZipFileHeader creates every ZipFile and passes
    // itself. The null checks stay for a future ZipFile without a header
    compressedSize = header?.compressedSize ?? compressedSize;
    uncompressedSize = header?.uncompressedSize ?? uncompressedSize;

    _encryptionType = (flags & 0x1) != 0
        ? ZipEncryptionMode.zipCrypto
        : ZipEncryptionMode.none;

    _password = password;

    // Read compressedSize bytes for the compressed data.
    _rawContent = input.readBytes(header!.compressedSize);

    if (_encryptionType != ZipEncryptionMode.none && exLen > 2) {
      final extra = InputMemoryStream(extraField!);
      while (!extra.isEOS) {
        final id = extra.readUint16();
        if (id == ZipAesHeader.signature) {
          extra.readUint16(); // dataSize = 7
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

    if (_encryptionType == ZipEncryptionMode.zipCrypto && password != null) {
      _initKeys(password);
    }

    // If bit 3 (0x08) of the flags field is set, then the CRC-32 and file
    // sizes are not known when the header is written. The fields in the
    // local header are filled with zero, and the CRC-32 and size are
    // appended in a 12-byte structure (optionally preceded by a 4-byte
    // signature) immediately after the compressed data:
    if (flags & 0x08 != 0) {
      final sigOrCrc = input.readUint32();
      if (sigOrCrc == 0x08074b50) {
        crc32 = input.readUint32();
      } else {
        crc32 = sigOrCrc;
      }

      // APPNOTE 4.3.9.2: the sizes are 8 bytes each when a zip64 extra field is
      // present for the file. Only the local field says that. A central one can
      // carry an offset past 4 GB while the sizes here stay 4 bytes, and an
      // entry whose central field holds the sizes needs nothing from here
      final central = header;
      final zip64 = _hasZip64(extraField);
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
    final contentStream = getStream();
    _computedCrc32 ??= getCrc32(contentStream.toUint8List());
    return !hasCrc32 || _computedCrc32 == crc32;
  }

  @override
  void decompress(OutputStream output) {
    if (_rawContent == null) {
      return;
    }

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

    if (compressionMethod == CompressionType.deflate) {
      final savePos = _rawContent!.position;
      ZLibDecoder().decodeStream(_rawContent!, output, raw: true);
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
      output.writeStream(_rawContent!);
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
      final decoder = LzmaDecoder()
        ..dictionaryLimit = properties[1] |
            (properties[2] << 8) |
            (properties[3] << 16) |
            (properties[4] << 24)
        ..reset(
            literalContextBits: bits % 9,
            literalPositionBits: bits ~/ 9 % 5,
            positionBits: bits ~/ 45,
            resetDictionary: true);
      decoder.decodeToOutput(input, uncompressedSize, output);
    } on ArchiveException {
      rethrow;
    } catch (error) {
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
    if (_rawContent == null) {
      return InputMemoryStream(Uint8List(0));
    }
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

    if (!decompress) {
      return _rawContent!;
    }

    const maxDecodeBufferSize = 500 * 1024 * 1024; // 500MB

    if (compressionMethod == CompressionType.deflate) {
      final savePos = _rawContent!.position;
      late Uint8List content;
      if (_rawContent!.length <= maxDecodeBufferSize) {
        final compressed = _rawContent!.toUint8List();
        content = ZLibDecoder().decodeBytes(compressed, raw: true);
      } else {
        final decompress = OutputMemoryStream(size: uncompressedSize);
        ZLibDecoder().decodeStream(_rawContent!, decompress, raw: true);
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
      final output = OutputMemoryStream(size: uncompressedSize);
      _decodeLzma(output);
      return InputMemoryStream(output.getBytes());
    } else {
      final content = _rawContent!.toUint8List();
      return InputMemoryStream(content);
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

  void _initKeys(String password) {
    _keys[0] = BigInt.from(305419896);
    _keys[1] = BigInt.from(591751049);
    _keys[2] = BigInt.from(878082192);
    for (final c in password.codeUnits) {
      _updateKeys(c);
    }
  }

  void _updateKeys(int c) {
    _keys[0] = BigInt.from(getCrc32Byte(_keys[0].toInt(), c));
    _keys[1] += _keys[0] & BigInt.from(0xff);
    _keys[1] = (_keys[1] * BigInt.from(134775813) + BigInt.from(1)) &
        BigInt.from(0xffffffff);
    _keys[2] =
        BigInt.from(getCrc32Byte(_keys[2].toInt(), (_keys[1] >> 24).toInt()));
  }

  int _decryptByte() {
    final temp = (_keys[2] & BigInt.from(0xffff)).toInt() | 2;
    return ((temp * (temp ^ 1)) >> 8) & 0xff;
  }

  void _decodeByte(int c) {
    c ^= _decryptByte();
    _updateKeys(c);
  }

  InputStream _decodeZipCrypto(InputStream input) {
    if (_rawContent == null) {
      return InputMemoryStream(Uint8List(0));
    }

    for (var i = 0; i < 12; ++i) {
      _decodeByte(_rawContent!.readByte());
    }
    final bytes = Uint8List.fromList(_rawContent!.toUint8List());
    for (var i = 0; i < bytes.length; ++i) {
      final temp = bytes[i] ^ _decryptByte();
      _updateKeys(temp);
      bytes[i] = temp;
    }
    return InputMemoryStream(bytes);
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
    final bytes = Uint8List.fromList(dataBytes.toUint8List());

    final derivedKey = deriveKey(_password!, salt, derivedKeyLength: keySize);
    final keyData = Uint8List.fromList(derivedKey.sublist(0, keySize));
    final hmacKeyData =
        Uint8List.fromList(derivedKey.sublist(keySize, keySize * 2));
    // var authCode = deriveKey.sublist(keySize, keySize*2);
    final pwdCheck = derivedKey.sublist(keySize * 2, keySize * 2 + 2);
    if (!Uint8ListEquality.equals(pwdCheck, verify)) {
      throw Exception('password error');
    }

    final aes = Aes(keyData, hmacKeyData, keySize);
    aes.processData(bytes, 0, bytes.length);
    if (!Uint8ListEquality.equals(dataMac.toUint8List(), aes.mac)) {
      throw Exception('macs don\'t match');
    }
    return InputMemoryStream(bytes);
  }

  static Uint8List deriveKey(String password, Uint8List salt,
      {int derivedKeyLength = 32}) {
    if (password.isEmpty) {
      return Uint8List(0);
    }
    final passwordBytes = Uint8List.fromList(password.codeUnits);
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
}

@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';

import '_test_util.dart';

void main() {
  final testData = Uint8List(120);
  for (var i = 0; i < testData.length; ++i) {
    testData[i] = i;
  }
  final testPath = '$testOutputPath/test_123.bin';
  File(testPath)
    ..createSync(recursive: true)
    ..writeAsBytesSync(testData);

  group('InputStreamFile', () {
    test('length', () async {
      final fs = InputFileStream(testPath)..open();
      expect(fs.length, testData.length);
    });

    test('FileBuffer read count near 2^63 stops at file end', () {
      final buffer = FileBuffer(FileHandle(testPath), bufferSize: 8);
      addTearDown(buffer.closeSync);
      final bytes = Uint8List(testData.length + 2)
        ..fillRange(0, testData.length + 2, 255);
      expect(buffer.readInto(1, bytes, 1, 0x7fffffffffffffff),
          testData.length - 1);
      expect(bytes.sublist(1, testData.length), testData.sublist(1));
      expect(bytes[0], 255);
      expect(bytes[testData.length], 255);
      expect(buffer.readBytes(1, 0x7fffffffffffffff), testData.sublist(1));
    }, testOn: 'vm');

    for (final count in [8, 16, 127]) {
      test('readInto retries short file reads until $count bytes arrive', () {
        final input = InputFileStream.withFileBuffer(
            FileBuffer(_ShortReadHandle(testPath), bufferSize: 8));
        addTearDown(input.closeSync);
        final bytes = Uint8List(count + 2)..fillRange(0, count + 2, 255);
        final expected = count < testData.length ? count : testData.length;

        expect(input.readInto(bytes, 1, count), expected);
        expect(bytes.sublist(1, 1 + expected), testData.sublist(0, expected));
        expect(bytes.first, 255);
        expect(bytes.skip(1 + expected), everyElement(255));
        expect(input.position, expected);

        final tail = Uint8List(testData.length);
        final remaining = testData.length - expected;
        expect(input.readInto(tail, 0, tail.length), remaining);
        expect(tail.sublist(0, remaining), testData.sublist(expected));
        expect(input.isEOS, isTrue);
      });
    }

    test('toUint8List and readBytes retry short file reads', () {
      final input = InputFileStream.withFileBuffer(
          FileBuffer(_ShortReadHandle(testPath), bufferSize: 8));
      addTearDown(input.closeSync);
      expect(input.toUint8List(), testData);
      expect(input.readBytes(6).toUint8List(), testData.sublist(0, 6));
    });

    test('readInto on subset stops at subset end', () {
      final file = InputFileStream(testPath, bufferSize: 2);
      addTearDown(file.closeSync);
      final input = file.subset(position: 10, length: 3);
      final bytes = Uint8List(10)..fillRange(0, 10, 255);

      expect(input.readInto(bytes, 1, 1), 1);
      expect(input.readInto(bytes, 2, 8), 2);
      expect(bytes, [255, 10, 11, 12, 255, 255, 255, 255, 255, 255]);
      expect(input.position, 3);
      expect(input.length, 0);
      expect(input.isEOS, isTrue);
      expect(input.readInto(bytes, 0, 10), 0);
      expect(input.position, 3);
      expect(bytes, [255, 10, 11, 12, 255, 255, 255, 255, 255, 255]);
    });

    test('readBytes', () async {
      final input = InputFileStream(testPath)..open();
      expect(input.length, equals(120));
      var same = true;
      var ai = 0;
      while (!input.isEOS) {
        final bs = input.readBytes(50);
        final bytes = bs.toUint8List();
        for (var i = 0; i < bytes.length; ++i) {
          same = bytes[i] == ai + i;
          if (!same) {
            expect(same, equals(true));
            return;
          }
        }
        ai += bytes.length;
      }
    });

    test('position', () async {
      final fs = InputFileStream(testPath, bufferSize: 2)
        ..open()
        ..setPosition(50);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[50 + i]);
      }
    });

    test('skip', () async {
      final fs = InputFileStream(testPath, bufferSize: 2)
        ..open()
        ..skip(50);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[50 + i]);
      }
    });

    test('rewind', () async {
      final fs = InputFileStream(testPath, bufferSize: 2)
        ..open()
        ..skip(50)
        ..rewind(10);
      final bs = fs.readBytes(50);
      final b = bs.toUint8List();
      expect(b.length, 50);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[40 + i]);
      }
    });

    test('peakBytes', () async {
      final fs = InputFileStream(testPath, bufferSize: 2)..open();
      final bs = fs.peekBytes(10);
      final b = bs.toUint8List();
      expect(fs.position, 0);
      expect(b.length, 10);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[i]);
      }
    });

    test('peakBytes past the end of the file', () async {
      // Used to report the whole count and return the buffer's leftovers
      final fs = InputFileStream(testPath, bufferSize: 8)..open();
      fs.skip(testData.length - 5);
      final bs = fs.peekBytes(512);
      expect(bs.length, 5);
      final b = bs.toUint8List();
      expect(b.length, 5);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[testData.length - 5 + i]);
      }
      expect(fs.position, testData.length - 5);
    });

    test('a short peek does not shrink the cache', () async {
      // The tar decoder's pattern: two bytes peeked ahead of every record
      // A short peek used to become the size of the cache
      // A buffer of eight records, and a file too big to sit in one
      const recordSize = 512;
      final big = Uint8List(64 * 1024);
      for (var i = 0; i < big.length; ++i) {
        big[i] = i & 0xff;
      }
      final bigPath = '$testOutputPath/test_cache.bin';
      File(bigPath)
        ..createSync(recursive: true)
        ..writeAsBytesSync(big);

      final handle = _CountingHandle(bigPath);
      final fs = InputFileStream.withFileBuffer(
          FileBuffer(handle, bufferSize: 8 * recordSize));
      var records = 0;
      while (!fs.isEOS) {
        expect(fs.peekBytes(2).toUint8List().first,
            equals((records * recordSize) & 0xff));
        expect(
            fs.readBytes(recordSize).toUint8List().length, equals(recordSize));
        records++;
      }
      expect(records, equals(big.length ~/ recordSize));
      // Eight records per buffer: one read to fill it, and a read that ends
      // exactly at the end of the buffer is still a hit
      expect(handle.reads, equals(records ~/ 8));
      fs.closeSync();
    });

    test('the cache keeps its size past a short read at the end', () {
      // The count of a short read at the end of the file used to become the
      // size of the buffer allocated after a close, or for a copy
      final whole = FileBuffer(FileHandle(testPath));
      final first = whole.readUint64(0);
      final last = whole.readUint64(testData.length - 8);

      final closed = FileBuffer(FileHandle(testPath), bufferSize: 16);
      closed.readUint8(testData.length - 3);
      closed.closeSync();
      expect(closed.readUint64(0), equals(first));
      expect(closed.readUint64(testData.length - 8), equals(last));

      final other = FileBuffer(FileHandle(testPath), bufferSize: 16);
      other.readUint8(testData.length - 3);
      final copy = FileBuffer.from(other);
      expect(copy.readUint64(0), equals(first));
      expect(copy.readUint64(testData.length - 8), equals(last));
      // Nor can a copy be given a buffer too small for a 64-bit read
      expect(
          FileBuffer.from(other, bufferSize: 2).readUint64(0), equals(first));
    });

    test('read multi-byte value at end of file', () async {
      // Regression test for #410: reading a uint16/24/32 whose last byte is
      // the final byte of the file used to incorrectly return 0
      final fs = InputFileStream(testPath, bufferSize: 2)..open();

      fs.setPosition(testData.length - 2);
      expect(fs.readUint16(), (119 << 8) | 118);

      fs.setPosition(testData.length - 3);
      expect(fs.readUint24(), 117 | (118 << 8) | (119 << 16));

      fs.setPosition(testData.length - 4);
      expect(fs.readUint32(), 116 | (117 << 8) | (118 << 16) | (119 << 24));
    });

    test('reads multi-byte values in stream byte order', () {
      final memory =
          InputMemoryStream(testData, byteOrder: ByteOrder.bigEndian);
      final streams = [
        InputFileStream(testPath, byteOrder: ByteOrder.bigEndian),
        InputFileStream.withFileHandle(FileHandle(testPath),
            byteOrder: ByteOrder.bigEndian),
        InputFileStream.withFileBuffer(FileBuffer(FileHandle(testPath)),
            byteOrder: ByteOrder.bigEndian),
        InputFileStream(testPath)..byteOrder = ByteOrder.bigEndian,
      ];
      for (final input in streams) {
        addTearDown(input.closeSync);
        memory.setPosition(0);
        expect(input.readUint16(), memory.readUint16());
        expect(input.readUint24(), memory.readUint24());
        expect(input.readUint32(), memory.readUint32());
        expect(input.readUint64(), memory.readUint64());
      }
    });

    test("clone", () async {
      final input = InputFileStream(testPath)..open();
      final input2 =
          InputFileStream.fromFileStream(input, position: 6, length: 5);
      final bs = input2.readBytes(5);
      final b = bs.toUint8List();
      expect(b.length, 5);
      for (var i = 0; i < b.length; ++i) {
        expect(b[i], testData[6 + i]);
      }
    });
  });
}

// Counts the reads that reach the file
class _CountingHandle extends AbstractFileHandle {
  final FileHandle _inner;
  int reads = 0;

  _CountingHandle(String path) : _inner = FileHandle(path);

  @override
  int get position => _inner.position;

  @override
  set position(int p) => _inner.position = p;

  @override
  int get length => _inner.length;

  @override
  bool get isOpen => _inner.isOpen;

  @override
  bool open({FileAccess mode = FileAccess.read}) => _inner.open(mode: mode);

  @override
  Future<void> close() => _inner.close();

  @override
  void closeSync() => _inner.closeSync();

  @override
  int readInto(Uint8List buffer, [int? length]) {
    reads++;
    return _inner.readInto(buffer, length);
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) =>
      _inner.writeFromSync(buffer, start, end);
}

class _ShortReadHandle extends _CountingHandle {
  _ShortReadHandle(super.path);

  @override
  int readInto(Uint8List buffer, [int? length]) {
    final count = length ?? buffer.length;
    return super.readInto(buffer, count > 3 ? 3 : count);
  }
}

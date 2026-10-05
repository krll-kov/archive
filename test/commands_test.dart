import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('bin/tar.dart list test2.tar.gz', testOn: 'vm', () {
    // Test that 'tar --list' does not throw.
    listTarFiles('test/_data/test2.tar.gz');
  });

  test('bin/tar.dart list test2.tar.gz2', testOn: 'vm', () {
    // Test that 'tar --list' does not throw.
    listTarFiles('test/_data/test2.tar.bz2');
  });

  List<String> printed(void Function() body) {
    final lines = <String>[];
    runZoned(body,
        zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => lines.add(line)));
    return lines;
  }

  test('list reads uncompressed tar', testOn: 'vm', () {
    expect(printed(() => listTarFiles('test/_data/test2.tar')),
        printed(() => listTarFiles('test/_data/test2.tar.gz')));
  });

  test('list and extract leave no temporary folder', testOn: 'vm', () {
    final temp = Directory.systemTemp.createTempSync('commands_temp');
    final out = Directory.systemTemp.createTempSync('commands_out');
    addTearDown(() {
      temp.deleteSync(recursive: true);
      out.deleteSync(recursive: true);
    });
    IOOverrides.runZoned(() {
      printed(() {
        listTarFiles('test/_data/test2.tar.gz');
        listTarFiles('test/_data/test2.tar.bz2');
        extractTarFiles('test/_data/test2.tar.gz', out.path);
      });
    }, getSystemTempDirectory: () => temp);
    expect(temp.listSync(), isEmpty);
  });

  test('extract of damaged tar.gz throws and leaves no temporary folder',
      testOn: 'vm', () {
    final temp = Directory.systemTemp.createTempSync('commands_temp');
    final out = Directory.systemTemp.createTempSync('commands_out');
    addTearDown(() {
      temp.deleteSync(recursive: true);
      out.deleteSync(recursive: true);
    });
    final whole = File('test/_data/test2.tar.gz').readAsBytesSync();
    final damaged = File(p.join(temp.path, 'damaged.tar.gz'))
      ..writeAsBytesSync(whole.sublist(0, whole.length ~/ 2));
    IOOverrides.runZoned(() {
      expect(() => printed(() => extractTarFiles(damaged.path, out.path)),
          throwsA(isA<ArchiveException>()));
    }, getSystemTempDirectory: () => temp);
    damaged.deleteSync();
    expect(temp.listSync(), isEmpty);
  });

  test('tar extract', testOn: 'vm', () {
    final dir = Directory.systemTemp.createTempSync('foo');

    try {
      //print(dir.path);

      final inputPath = p.join('test/_data/test2.tar.gz');

      {
        final tempDir = Directory.systemTemp.createTempSync('dart_archive');
        final tarPath = '${tempDir.path}${Platform.pathSeparator}temp.tar';
        final input = InputFileStream(inputPath);
        final output = OutputFileStream(tarPath);
        GZipDecoder().decodeStream(input, output);

        final aBytes = File(tarPath).readAsBytesSync();
        final bBytes = File(p.join('test/_data/test2.tar')).readAsBytesSync();

        expect(aBytes.length, equals(bBytes.length));
        var same = true;
        for (var i = 0; same && i < aBytes.length; ++i) {
          same = aBytes[i] == bBytes[i];
        }
        expect(same, equals(true));

        input.closeSync();
        output.closeSync();

        tempDir.deleteSync(recursive: true);
      }

      extractTarFiles('test/_data/test2.tar.gz', dir.path);
      expect(dir.listSync(recursive: true).length, 4);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  /*test('tar create', () {
    final dir = Directory.systemTemp.createTempSync('foo');
    final file = File('${dir.path}${Platform.pathSeparator}foo.txt');
    file.writeAsStringSync('foo bar');

    try {
      // Test that 'tar --create' does not throw.
      tar_command.createTarFile(dir.path);
    } finally {
      dir.delete(recursive: true);
    }
  });*/
}

import 'package:archive/src/util/archive_exception.dart';
import 'package:archive/src/util/decode_guard.dart';
import 'package:test/test.dart';

void main() {
  bool fails() => false;
  bool checksum() => throw ArchiveChecksumException('checksum');
  bool damage() => throw ArchiveException('damage');
  bool range() => throw RangeError('range');

  final plain =
      allOf(isA<ArchiveException>(), isNot(isA<ArchiveChecksumException>()));

  test('without flags nothing is thrown', () {
    for (final decode in [fails, checksum, damage, range]) {
      expect(guardDecode('x', false, false, decode), isFalse);
    }
    expect(guardDecode('x', false, false, () => true), isTrue);
  });

  test('throwOnError throws ArchiveException, never the checksum one', () {
    for (final decode in [fails, checksum, damage, range]) {
      expect(() => guardDecode('x', false, true, decode), throwsA(plain));
    }
  });

  test('verify throws ArchiveChecksumException only for a checksum', () {
    expect(() => guardDecode('x', true, false, checksum),
        throwsA(isA<ArchiveChecksumException>()));
    for (final decode in [fails, damage, range]) {
      expect(() => guardDecode('x', true, false, decode), throwsA(plain));
    }
  });

  test('throwIfStrict follows the rules of guardDecode', () {
    String outcome(void Function() f) {
      try {
        f();
        return 'none';
      } catch (error) {
        return '${error.runtimeType} ${(error as ArchiveException).message}';
      }
    }

    for (final error in [
      ArchiveException('damage'),
      ArchiveChecksumException('checksum'),
      ArchivePasswordException('password'),
    ]) {
      for (final (verify, throwOnError) in [
        (false, false),
        (false, true),
        (true, false),
        (true, true)
      ]) {
        expect(
            outcome(() => throwIfStrict(error, verify, throwOnError)),
            outcome(() =>
                guardDecode('x', verify, throwOnError, () => throw error)),
            reason: '$error, verify $verify, throwOnError $throwOnError');
      }
    }
  });
}

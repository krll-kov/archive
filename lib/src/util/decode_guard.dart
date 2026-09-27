import 'archive_exception.dart';

/// Runs [decode] under the `verify` and `throwOnError` rules shared by every
/// decoder: without `verify` a checksum failure is never thrown as
/// [ArchiveChecksumException], and without either flag nothing is thrown but
/// [ArchivePasswordException]
bool guardDecode(
    String format, bool verify, bool throwOnError, bool Function() decode) {
  final strict = verify || throwOnError;
  try {
    if (decode()) {
      return true;
    }
    if (strict) {
      throw ArchiveException('Invalid $format data');
    }
    return false;
  } on ArchivePasswordException {
    rethrow;
  } on ArchiveChecksumException catch (error) {
    if (verify) {
      rethrow;
    }
    if (throwOnError) {
      throw ArchiveException(error.message);
    }
    return false;
  } on ArchiveException {
    if (strict) {
      rethrow;
    }
    return false;
  } catch (error) {
    if (strict) {
      throw ArchiveException('Invalid $format data: $error');
    }
    return false;
  }
}

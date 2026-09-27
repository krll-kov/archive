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
  } on CallbackFailure catch (failure) {
    Error.throwWithStackTrace(failure.error, failure.stackTrace);
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

void throwIfStrict(ArchiveException error, bool verify, bool throwOnError) {
  if (error is ArchivePasswordException) {
    throw error;
  }
  if (error is ArchiveChecksumException && !verify) {
    if (throwOnError) {
      throw ArchiveException(error.message);
    }
    return;
  }
  if (verify || throwOnError) {
    throw error;
  }
}

class CallbackFailure {
  final Object error;
  final StackTrace stackTrace;

  CallbackFailure(this.error, this.stackTrace);
}

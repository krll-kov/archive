/// An exception thrown when there was a problem in the archive library.
class ArchiveException extends FormatException {
  ArchiveException(super.message);
}

/// Thrown with `verify` when data does not match its checksum
class ArchiveChecksumException extends ArchiveException {
  ArchiveChecksumException(super.message);
}

/// Thrown regardless of `verify` and `throwOnError` when a password is wrong or
/// missing
class ArchivePasswordException extends ArchiveException {
  ArchivePasswordException(super.message);
}

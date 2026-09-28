import 'package:path/path.dart' as path;

import '../archive/archive_file.dart';

/// A hard link names its target from the archive root and a symlink from its
/// own folder. dart:io cannot make a hard link and a copy would double disk
/// use, so it becomes a symlink with the target rewritten from its folder
String linkTarget(ArchiveFile file) {
  final text = file.symbolicLink ?? '';
  if (!file.isHardLink) {
    return text;
  }
  String clean(String p) =>
      path.posix.normalize(p.replaceFirst(RegExp('^/+'), ''));
  return path.posix
      .relative(clean(text), from: path.posix.dirname(clean(file.name)));
}

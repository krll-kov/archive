import 'dart:typed_data';

bool isCrc32FastSupported_() => false;

/// The slice by eight loop folds eight bytes through a sixty four bit read,
/// which a backend with no real sixty four bit integer cannot do
int crc32Fast_(Uint8List array, int crc, List<int> base) => -1;

import '_crc64_io.dart' if (dart.library.html) '_crc64_html.dart';

int getCrc64(List<int> array, [int crc = 0]) => getCrc64_(array, crc);

bool isCrc64Supported() => isCrc64Supported_();

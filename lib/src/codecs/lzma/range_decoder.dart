// The range decoder is written twice. The native implementation relies on 64
// bit integer arithmetic to decode bits without data dependent branches, which
// cannot be expressed where an int is a JavaScript number, so JavaScript
// targets get a branching implementation instead.
//
// dart:io is available wherever an int is a real 64 bit integer, on the VM and
// on wasm alike, so the native implementation is selected against it. The
// branching implementation is the default because it is correct anywhere.
export 'range_decoder_table.dart';
export 'range_decoder_web.dart'
    if (dart.library.io) 'range_decoder_native.dart';

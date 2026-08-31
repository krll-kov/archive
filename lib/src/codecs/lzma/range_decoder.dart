// The range decoder is written twice. The native implementation relies on 64
// bit integer arithmetic to decode bits without data dependent branches, which
// cannot be expressed where an int is a JavaScript number, so JavaScript
// targets get a branching implementation instead.
//
// The condition selects the web implementation for JavaScript only. On wasm an
// int is a real 64 bit integer, so the native implementation is both correct
// and faster there, and dart:html is not available to select against.
export 'range_decoder_native.dart'
    if (dart.library.html) 'range_decoder_web.dart';
export 'range_decoder_table.dart';

/// Conditional-import facade for [CastSession] (WASM-safe, same pattern as
/// the other dart:io services).
library;

export 'cast_session_stub.dart' if (dart.library.io) 'cast_session_io.dart';

/// Conditional-import facade for fetching sidecar subtitle content without
/// importing dart:io in shared code (WASM compatibility).
library;

export 'subtitle_loader_stub.dart'
    if (dart.library.io) 'subtitle_loader_io.dart';

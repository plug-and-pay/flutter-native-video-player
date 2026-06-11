/// Conditional-import facade for [VideoDownloadController] so the package
/// stays WASM-compatible (same pattern as platform_utils/subtitle_loader).
library;

export 'video_download_controller_stub.dart'
    if (dart.library.io) 'video_download_controller_io.dart';

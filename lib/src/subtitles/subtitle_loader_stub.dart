/// Web/WASM stub: sidecar subtitles can still be provided as raw [String]
/// content; URL/file loading requires dart:io.
class SubtitleLoader {
  static Future<String> loadUrl(String url) async {
    throw UnsupportedError(
      'Loading sidecar subtitles from a URL is not supported on this '
      'platform; pass the subtitle content directly instead.',
    );
  }

  static Future<String> loadFile(String path) async {
    throw UnsupportedError(
      'Loading sidecar subtitles from a file is not supported on this '
      'platform; pass the subtitle content directly instead.',
    );
  }
}

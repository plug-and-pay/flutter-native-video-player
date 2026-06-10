import 'dart:convert';
import 'dart:io';

/// Native implementation: fetches subtitle text from a URL or local file
/// using dart:io (kept out of the rest of the package for WASM
/// compatibility, mirroring the platform_utils conditional-import pattern).
class SubtitleLoader {
  static Future<String> loadUrl(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Subtitle download failed (${response.statusCode})',
          uri: Uri.parse(url),
        );
      }
      return response.transform(utf8.decoder).join();
    } finally {
      client.close();
    }
  }

  static Future<String> loadFile(String path) => File(path).readAsString();
}

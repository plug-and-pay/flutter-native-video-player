import '../models/native_video_player_download.dart';

/// Web/WASM stub: downloads need dart:io. Mirrors the io API so shared
/// code compiles; every member throws.
class VideoDownloadController {
  VideoDownloadController({required this.directoryPath});

  final String directoryPath;

  Never _unsupported() => throw UnsupportedError(
    'VideoDownloadController is not supported on this platform '
    '(requires dart:io).',
  );

  Stream<VideoDownloadProgress> download({
    required String id,
    required String url,
    Map<String, String>? headers,
  }) => _unsupported();

  Future<void> cancel(String id) => _unsupported();

  Future<List<VideoDownload>> listDownloads() => _unsupported();

  Future<String?> localPathFor(String id) => _unsupported();

  Future<bool> isDownloaded(String id) => _unsupported();

  Future<void> remove(String id) => _unsupported();
}

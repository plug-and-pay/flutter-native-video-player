import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/native_video_player_download.dart';

/// Downloads videos for offline playback (dart:io implementation).
///
/// Scope: single-file sources — MP4/WebM/MP3 and any other progressive URL
/// (for Vimeo use the extractor's `progressiveUrl`; Bunny serves
/// `play_{height}p.mp4` next to its playlists). HLS playlists are NOT
/// downloadable here: real offline HLS needs the native downloaders
/// (AVAssetDownloadTask / Media3 DownloadManager), a separate feature.
///
/// Completed downloads are recorded in an index file inside [directoryPath],
/// so they survive restarts; play them with
/// `NativeVideoPlayerController.loadFile(path: download.filePath)`.
class VideoDownloadController {
  /// [directoryPath] is where files and the index live — typically
  /// `(await getApplicationDocumentsDirectory()).path + '/video_downloads'`
  /// from `path_provider` (the plugin deliberately doesn't depend on it).
  VideoDownloadController({required this.directoryPath});

  final String directoryPath;

  static const String _indexFileName = 'downloads_index.json';

  final Map<String, _ActiveDownload> _active = <String, _ActiveDownload>{};
  Map<String, VideoDownload>? _index;

  Future<Directory> _dir() async =>
      Directory(directoryPath).create(recursive: true);

  Future<Map<String, VideoDownload>> _loadIndex() async {
    if (_index != null) return _index!;
    final file = File('${(await _dir()).path}/$_indexFileName');
    var loaded = <String, VideoDownload>{};
    if (await file.exists()) {
      try {
        final raw = jsonDecode(await file.readAsString()) as Map;
        loaded = raw.map(
          (k, v) => MapEntry(
            k as String,
            VideoDownload.fromMap((v as Map).cast<String, dynamic>()),
          ),
        );
        // Drop entries whose file disappeared (cleared caches etc.).
        loaded.removeWhere((_, d) => !File(d.filePath).existsSync());
      } catch (_) {
        loaded = <String, VideoDownload>{};
      }
    }
    return _index = loaded;
  }

  Future<void> _saveIndex() async {
    final index = await _loadIndex();
    final file = File('${(await _dir()).path}/$_indexFileName');
    await file.writeAsString(
      jsonEncode(index.map((k, v) => MapEntry(k, v.toMap()))),
    );
  }

  /// File-system-safe name for an arbitrary id.
  String _safeName(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  String _extensionOf(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final dot = path.lastIndexOf('.');
    if (dot == -1 || path.length - dot > 6) return '.bin';
    return path.substring(dot);
  }

  /// Starts (or replays the completion of) the download for [id].
  ///
  /// Emits [VideoDownloadProgress] updates and closes after a terminal
  /// status (completed / failed / canceled). Calling this for an id that is
  /// already downloaded immediately emits `completed`. One concurrent
  /// download per id; a second call while active returns the same stream.
  Stream<VideoDownloadProgress> download({
    required String id,
    required String url,
    Map<String, String>? headers,
  }) {
    final existing = _active[id];
    if (existing != null) return existing.controller.stream;

    final controller = StreamController<VideoDownloadProgress>.broadcast();
    final active = _ActiveDownload(controller);
    _active[id] = active;
    unawaited(_run(id, url, headers, active));
    return controller.stream;
  }

  Future<void> _run(
    String id,
    String url,
    Map<String, String>? headers,
    _ActiveDownload active,
  ) async {
    final controller = active.controller;

    void emit(VideoDownloadProgress p) {
      if (!controller.isClosed) controller.add(p);
    }

    Future<void> finish() async {
      _active.remove(id);
      await controller.close();
    }

    try {
      final index = await _loadIndex();
      final done = index[id];
      if (done != null) {
        emit(
          VideoDownloadProgress(
            id: id,
            status: VideoDownloadStatus.completed,
            receivedBytes: done.sizeBytes,
            totalBytes: done.sizeBytes,
          ),
        );
        await finish();
        return;
      }

      final dir = await _dir();
      final partFile = File('${dir.path}/${_safeName(id)}.part');
      final targetFile = File(
        '${dir.path}/${_safeName(id)}${_extensionOf(url)}',
      );

      final client = HttpClient();
      active.client = client;
      final request = await client.getUrl(Uri.parse(url));
      headers?.forEach(request.headers.set);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }

      final total = response.contentLength > 0 ? response.contentLength : null;
      var received = 0;
      final sink = partFile.openWrite();
      active.sink = sink;

      emit(
        VideoDownloadProgress(
          id: id,
          status: VideoDownloadStatus.downloading,
          totalBytes: total,
        ),
      );

      // Throttle UI updates: emit at most ~every 150ms (plus completion).
      final sinceEmit = Stopwatch()..start();
      final completer = Completer<void>();
      active.subscription = response.listen(
        (chunk) {
          received += chunk.length;
          sink.add(chunk);
          if (sinceEmit.elapsedMilliseconds >= 150) {
            sinceEmit.reset();
            emit(
              VideoDownloadProgress(
                id: id,
                status: VideoDownloadStatus.downloading,
                receivedBytes: received,
                totalBytes: total,
              ),
            );
          }
        },
        onDone: () => completer.complete(),
        onError: completer.completeError,
        cancelOnError: true,
      );
      await completer.future;
      await sink.close();
      active.sink = null;

      if (active.canceled) {
        // Cancel raced with completion; treat as canceled.
        if (await partFile.exists()) await partFile.delete();
        emit(
          VideoDownloadProgress(id: id, status: VideoDownloadStatus.canceled),
        );
        await finish();
        return;
      }

      await partFile.rename(targetFile.path);
      final size = await targetFile.length();
      index[id] = VideoDownload(
        id: id,
        url: url,
        filePath: targetFile.path,
        sizeBytes: size,
        completedAt: DateTime.now(),
      );
      await _saveIndex();
      emit(
        VideoDownloadProgress(
          id: id,
          status: VideoDownloadStatus.completed,
          receivedBytes: size,
          totalBytes: size,
        ),
      );
      await finish();
    } catch (e) {
      try {
        await active.sink?.close();
        final part = File('${(await _dir()).path}/${_safeName(id)}.part');
        if (await part.exists()) await part.delete();
      } catch (_) {}
      if (active.canceled) {
        emit(
          VideoDownloadProgress(id: id, status: VideoDownloadStatus.canceled),
        );
      } else {
        emit(
          VideoDownloadProgress(
            id: id,
            status: VideoDownloadStatus.failed,
            error: '$e',
          ),
        );
      }
      await finish();
    } finally {
      active.client?.close(force: true);
    }
  }

  /// Cancels an in-flight download and removes its partial file.
  Future<void> cancel(String id) async {
    final active = _active[id];
    if (active == null) return;
    active.canceled = true;
    await active.subscription?.cancel();
    active.client?.close(force: true);
    try {
      await active.sink?.close();
    } catch (_) {}
    final part = File('${(await _dir()).path}/${_safeName(id)}.part');
    if (await part.exists()) await part.delete();
    if (!active.controller.isClosed) {
      active.controller.add(
        VideoDownloadProgress(id: id, status: VideoDownloadStatus.canceled),
      );
      await active.controller.close();
    }
    _active.remove(id);
  }

  /// Completed downloads, newest first.
  Future<List<VideoDownload>> listDownloads() async {
    final index = await _loadIndex();
    final list = index.values.toList()
      ..sort((a, b) => b.completedAt.compareTo(a.completedAt));
    return list;
  }

  /// The local file path for a completed download, or null.
  Future<String?> localPathFor(String id) async =>
      (await _loadIndex())[id]?.filePath;

  /// Whether [id] has a completed, still-present file.
  Future<bool> isDownloaded(String id) async =>
      (await localPathFor(id)) != null;

  /// Deletes the downloaded file and forgets it.
  Future<void> remove(String id) async {
    await cancel(id);
    final index = await _loadIndex();
    final entry = index.remove(id);
    if (entry != null) {
      final file = File(entry.filePath);
      if (await file.exists()) await file.delete();
      await _saveIndex();
    }
  }
}

class _ActiveDownload {
  _ActiveDownload(this.controller);

  final StreamController<VideoDownloadProgress> controller;
  StreamSubscription<List<int>>? subscription;
  IOSink? sink;
  HttpClient? client;
  bool canceled = false;
}

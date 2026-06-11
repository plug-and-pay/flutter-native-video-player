import 'package:flutter/foundation.dart';

/// Lifecycle states of one download.
enum VideoDownloadStatus { downloading, completed, failed, canceled }

/// One progress update from [VideoDownloadController.download].
@immutable
class VideoDownloadProgress {
  const VideoDownloadProgress({
    required this.id,
    required this.status,
    this.receivedBytes = 0,
    this.totalBytes,
    this.error,
  });

  /// The download id this update belongs to.
  final String id;

  final VideoDownloadStatus status;

  /// Bytes written so far.
  final int receivedBytes;

  /// Expected size from Content-Length; null when the server doesn't say.
  final int? totalBytes;

  /// Failure description when [status] is [VideoDownloadStatus.failed].
  final String? error;

  /// 0..1 when the total size is known, otherwise null (show an
  /// indeterminate indicator).
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    final f = receivedBytes / total;
    return f > 1 ? 1 : f;
  }

  @override
  String toString() =>
      'VideoDownloadProgress($id ${status.name} '
      '$receivedBytes/${totalBytes ?? '?'})';
}

/// A completed download as stored in the controller's index.
@immutable
class VideoDownload {
  const VideoDownload({
    required this.id,
    required this.url,
    required this.filePath,
    required this.sizeBytes,
    required this.completedAt,
  });

  factory VideoDownload.fromMap(Map<String, dynamic> map) => VideoDownload(
    id: map['id'] as String,
    url: map['url'] as String,
    filePath: map['filePath'] as String,
    sizeBytes: (map['sizeBytes'] as num).toInt(),
    completedAt: DateTime.fromMillisecondsSinceEpoch(
      (map['completedAtMs'] as num).toInt(),
    ),
  );

  /// Caller-chosen identifier (e.g. your video/lesson id).
  final String id;

  /// Source URL the file was downloaded from.
  final String url;

  /// Absolute path of the completed file — feed it to
  /// `NativeVideoPlayerController.loadFile(path: ...)` for offline playback.
  final String filePath;

  final int sizeBytes;
  final DateTime completedAt;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'id': id,
    'url': url,
    'filePath': filePath,
    'sizeBytes': sizeBytes,
    'completedAtMs': completedAt.millisecondsSinceEpoch,
  };
}

/// A thumbnail variant of an extracted video.
class ExtractedThumbnail {
  const ExtractedThumbnail({required this.url, this.width, this.height});

  final String url;
  final int? width;
  final int? height;

  @override
  String toString() => 'ExtractedThumbnail(${width}x$height $url)';
}

/// A scrub-preview storyboard: one sprite-sheet image holding many small
/// frames in a uniform grid (Vimeo's `thumb_preview`). Feed it to a player
/// UI by mapping a position to a grid tile — better_native_video_player's
/// `StoryboardThumbnails.fromUniformGrid` does exactly that.
class ExtractedStoryboard {
  const ExtractedStoryboard({
    required this.url,
    required this.frameWidth,
    required this.frameHeight,
    required this.columns,
    required this.frames,
    this.width,
    this.height,
  });

  /// Sprite-sheet image URL (usually tokenized like the stream URLs).
  final String url;

  /// Size of one preview frame inside the sheet.
  final double frameWidth;
  final double frameHeight;

  /// Frames per row.
  final int columns;

  /// Total frame count (evenly spaced across the video's duration).
  final int frames;

  /// Full sheet size, when known.
  final int? width;
  final int? height;

  @override
  String toString() => 'ExtractedStoryboard($frames frames, $columns cols, '
      '${frameWidth}x$frameHeight, $url)';
}

/// The result of extracting a hosted video: everything an app needs to show
/// a card (thumbnail, title, duration) and start playback (stream URL).
class ExtractedVideo {
  const ExtractedVideo({
    required this.provider,
    required this.videoId,
    this.hlsUrl,
    this.progressiveUrl,
    this.title,
    this.duration,
    this.thumbnails = const [],
    this.expiresAt,
    this.storyboard,
  });

  /// Source platform ("vimeo", "youtube").
  final String provider;

  /// Platform-specific video identifier.
  final String videoId;

  /// HLS (m3u8) stream URL, when the platform provides one. Usually
  /// tokenized — check [expiresAt] before reusing a cached value.
  final String? hlsUrl;

  /// Progressive (MP4) URL when available.
  final String? progressiveUrl;

  final String? title;
  final Duration? duration;

  /// Thumbnails sorted by area, largest first.
  final List<ExtractedThumbnail> thumbnails;

  /// When the tokenized stream URL stops working (parsed from the URL's
  /// `exp=` token where present). Null = unknown/not tokenized.
  final DateTime? expiresAt;

  /// Scrub-preview sprite sheet (Vimeo `thumb_preview`), when provided.
  final ExtractedStoryboard? storyboard;

  /// The best stream URL for playback (HLS preferred).
  String? get playbackUrl => hlsUrl ?? progressiveUrl;

  /// The largest thumbnail, or null.
  ExtractedThumbnail? get bestThumbnail =>
      thumbnails.isEmpty ? null : thumbnails.first;

  /// Whether the stream URL is still expected to be valid, with [margin]
  /// (default 1 minute) of safety.
  bool isFresh({Duration margin = const Duration(minutes: 1)}) {
    final exp = expiresAt;
    if (exp == null) return true;
    return DateTime.now().add(margin).isBefore(exp);
  }

  @override
  String toString() =>
      'ExtractedVideo($provider:$videoId, hls: ${hlsUrl != null}, '
      'thumbs: ${thumbnails.length}, duration: $duration, '
      'expiresAt: $expiresAt)';
}

/// Failure during extraction; carries enough context to decide on a
/// fallback (e.g. Huddle's queued-WebView last resort).
class VideoExtractionException implements Exception {
  const VideoExtractionException(this.provider, this.message,
      {this.statusCode});

  final String provider;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'VideoExtractionException($provider, $statusCode): $message';
}

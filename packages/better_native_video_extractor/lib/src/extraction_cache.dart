import 'dart:async';

import 'extracted_video.dart';
import 'extractor.dart';

/// Details of one failed extraction, delivered on
/// [VideoExtractionCache.failures]. [error] is usually a
/// [VideoExtractionException] (carries the source + reason).
class VideoExtractionFailure {
  const VideoExtractionFailure({
    required this.videoUrlOrId,
    required this.error,
    required this.stackTrace,
  });

  /// The input passed to [VideoExtractionCache.extract].
  final String videoUrlOrId;

  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => 'VideoExtractionFailure($videoUrlOrId: $error)';
}

/// Expiry-aware cache around a [VideoSourceExtractor].
///
/// - Returns cached results while their tokenized URL is still fresh
///   (Vimeo: ~15 min via the `exp=` token; a [safetyMargin] is subtracted,
///   driven by the actual token instead of a guessed constant TTL).
/// - Coalesces concurrent extractions of the same video (a feed building
///   five cards for one video performs ONE request).
/// - Failed extractions still throw at the call site AND are emitted on
///   [failures], so one listener can report them app-wide.
class VideoExtractionCache {
  VideoExtractionCache(this._extractor,
      {this.safetyMargin = const Duration(minutes: 2)});

  final VideoSourceExtractor _extractor;
  final Duration safetyMargin;

  final Map<String, ExtractedVideo> _cache = {};
  final Map<String, Future<ExtractedVideo>> _inFlight = {};
  final StreamController<VideoExtractionFailure> _failures =
      StreamController<VideoExtractionFailure>.broadcast();

  /// Fires whenever an extraction fails (the [extract] future still
  /// completes with the same error). Listen once, e.g. to log to your
  /// crash reporter or show a "video unavailable" state:
  ///
  /// ```dart
  /// cache.failures.listen((f) => log.warning('extract failed', f.error));
  /// ```
  Stream<VideoExtractionFailure> get failures => _failures.stream;

  /// Cached-or-fresh extraction for [videoUrlOrId].
  Future<ExtractedVideo> extract(String videoUrlOrId) {
    final key = videoUrlOrId.trim();
    final cached = _cache[key];
    if (cached != null && cached.isFresh(margin: safetyMargin)) {
      return Future.value(cached);
    }
    return _inFlight.putIfAbsent(key, () async {
      try {
        final result = await _extractor.extract(key);
        _cache[key] = result;
        return result;
      } catch (e, s) {
        if (!_failures.isClosed) {
          _failures.add(VideoExtractionFailure(
            videoUrlOrId: key,
            error: e,
            stackTrace: s,
          ));
        }
        rethrow;
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  /// Time until [videoUrlOrId]'s cached URL expires (minus margin), or null
  /// when unknown. Use to schedule a proactive refresh for the PLAYING video
  /// so playback never hits a dead URL.
  Duration? timeToRefresh(String videoUrlOrId) {
    final exp = _cache[videoUrlOrId.trim()]?.expiresAt;
    if (exp == null) return null;
    final remaining = exp.difference(DateTime.now()) - safetyMargin;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void evict(String videoUrlOrId) => _cache.remove(videoUrlOrId.trim());

  void clear() => _cache.clear();

  /// Closes the [failures] stream. Call when the cache outlives its use
  /// (app-singleton caches don't need this).
  void dispose() {
    unawaited(_failures.close());
  }
}

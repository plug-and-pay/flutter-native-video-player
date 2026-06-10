import 'dart:async';

import 'extracted_video.dart';
import 'extractor.dart';

/// Expiry-aware cache around a [VideoSourceExtractor].
///
/// - Returns cached results while their tokenized URL is still fresh
///   (Vimeo: ~15 min via the `exp=` token; a [safetyMargin] is subtracted —
///   the same idea as Huddle's 12-of-15-minute TTL, but driven by the
///   actual token instead of a guessed constant).
/// - Coalesces concurrent extractions of the same video (a feed building
///   five cards for one video performs ONE request).
class VideoExtractionCache {
  VideoExtractionCache(this._extractor, {this.safetyMargin = const Duration(minutes: 2)});

  final VideoSourceExtractor _extractor;
  final Duration safetyMargin;

  final Map<String, ExtractedVideo> _cache = {};
  final Map<String, Future<ExtractedVideo>> _inFlight = {};

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
      } finally {
        unawaited(_inFlight.remove(key) == null ? null : null);
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
}

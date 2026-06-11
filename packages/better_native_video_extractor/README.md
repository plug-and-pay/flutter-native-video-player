# better_native_video_extractor

WebView-free extraction of playable streams from hosted video platforms.
Companion module for `better_native_video_player`; usable with any player.

```dart
final extractor = VimeoExtractor(referer: 'https://yourdomain.com');
final cache = VideoExtractionCache(extractor);

final video = await cache.extract('https://vimeo.com/76979871');
// video.playbackUrl  -> tokenized HLS URL (video.expiresAt = exp= deadline)
// video.bestThumbnail.url, video.duration, video.title
```

- **Vimeo**: fetches `player.vimeo.com/video/{id}/config` (plain JSON) with
  your Referer/auth headers — required for domain-locked videos; falls back
  to the inline `window.playerConfig` in the player page HTML. Supports
  private-link hashes (`vimeo.com/{id}/{hash}` or `?h=`).
- **YouTube**: metadata + muxed stream via `youtube_explode_dart`. Using
  extracted YouTube streams is a product/legal decision for your app.
- **VideoExtractionCache**: expiry-aware (parses the URL token deadline),
  coalesces concurrent extractions, and exposes `timeToRefresh()` so the
  playing video's URL can be refreshed BEFORE it dies.

## Failure events

Every failed extraction still throws a `VideoExtractionException` at the
call site, and is ALSO emitted on `cache.failures` — listen once to report
all extraction problems app-wide (crash reporter, analytics, "video
unavailable" UI):

```dart
cache.failures.listen((f) {
  // f.videoUrlOrId, f.error (VideoExtractionException), f.stackTrace
  bugsnag.notify(f.error, f.stackTrace);
});
```

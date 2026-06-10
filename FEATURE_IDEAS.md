# Feature proposals — better_native_video_player

Candidate features people ask video players for (sourced from this repo's
issue themes, better_player/video_player issue trackers, and Huddle's
usage), ranked by expected value for Huddle-style feed apps. Nothing here
is implemented; each item lists effort and the native surface it touches.

## High value / moderate effort

1. **Prefetch API** (`precache(url)` — roadmap Tier 3b). Warm the next feed
   items' manifests/first segments so scrolling to them starts instantly.
   Android: Media3 `CacheDataSource`/`PreloadMediaSource`; iOS: AVAsset
   preheating (MP4) or manifest-only warmup (HLS). Pairs with Huddle's
   feed and the Vimeo HTTP extraction (resolve + prefetch together).
2. **Playback analytics events** — a single `analyticsStream` emitting
   structured events (startup time, first-frame, stall start/end + count,
   bitrate/variant switches, watched-duration heartbeats, completion).
   Both platforms already observe everything needed (KVO / Player.Listener);
   this exposes it. Huddle gets engagement/QoE metrics nearly for free.
3. **Resume-position convenience** — `load(..., startAt: Duration)` plus an
   optional `onPositionCheckpoint` callback (every N seconds, last value on
   dispose). Huddle implements this app-side today; plugin-level support
   removes the racy seek-after-load dance.
4. **Scrubbing thumbnail previews** — accept a storyboard source (WebVTT
   storyboard / sprite sheet / BIF) and expose `thumbnailAt(Duration)` for
   overlay scrub bars. Vimeo's config even ships storyboard URLs. Pure
   Dart + one image fetch path; no native work.

## High value / higher effort

5. **Chromecast support** — the most-requested capability gap vs
   better_player ecosystems. Android: Media3 `CastPlayer` integration
   behind the same controller API; iOS: google_cast SDK. Big, stateful,
   needs real devices; consider a separate companion package.
6. **Offline downloads** — Media3 `DownloadManager` + `AVAssetDownloadTask`
   behind a `downloads` API (queue, progress, license persistence for
   DRM). Large; only worth it with a concrete product need.

## Nice-to-have / small

7. **A-B loop / clip range** — `setPlaybackRange(start, end, loop:)`.
   Trivial on both platforms (boundary timer + seek).
8. **Background audio-only toggle** — keep audio when backgrounded without
   PiP (iOS `audiovisualBackgroundPlaybackPolicy` is already set;
   Android needs the media session flag we already hold). Mostly plumbing
   + docs.
9. **Per-source HTTP header refresh / DRM token renewal callback** — lets
   apps hand the plugin a `Future<String> Function()` token provider so
   401s on segment/license requests trigger a refresh instead of an error.
   Valuable for tenant-auth'd streams like Huddle's.
10. **Playlist/queue API** — `loadPlaylist([...])` with auto-advance and a
    `currentIndexStream`. Medium effort; interacts with the shared-player
    lifecycle, design carefully.

## Explicitly not recommended

- iOS-native sidecar subtitle injection (no sane AVPlayer API; already
  solved via the Flutter overlay + Android sideload).
- In-plugin Vimeo/YouTube extractors — site extraction churns and belongs
  app-side or server-side (see HUDDLE_FINDINGS.md for the Vimeo HTTP
  approach), not in a player plugin.

# Feature proposals — better_native_video_player

Candidate features people ask video players for (sourced from this repo's
issue themes, better_player/video_player issue trackers, and feed apps'
usage), ranked by expected value for feed-style apps.

**Status update (2026-06-11, `feat/extractor-and-player-features`):**
implemented — #2 analytics (`PlaybackAnalytics`), #3 startAt + checkpoints
(`load(startAt:)` native on both platforms + `PositionCheckpoints`),
#4 storyboards (`StoryboardThumbnails`: VTT + uniform sprite grids),
#7 A-B loop (`setPlaybackRange`/`clearPlaybackRange`), #8 background
toggle (`BackgroundPlaybackGuard`), #10 playlist
(`NativeVideoPlayerPlaylist`). Extraction shipped as the separate
`packages/better_native_video_extractor` package (Vimeo incl. referer,
thumbnails, storyboard, expiry cache; YouTube) — the "app-side" placement
argued for below, just maintained in-repo. Deliberately NOT implemented:
#1 prefetch (perf Tier 3b, needs device A/B), #5 in-plugin Chromecast
(app-level guidance: receiver
subtitle tracks + native-controls routing), #6 offline downloads,
#9 DRM token refresh (device/SDK-dependent, not verifiable here).

## High value / moderate effort

1. **Prefetch API** (`precache(url)` — roadmap Tier 3b). Warm the next feed
   items' manifests/first segments so scrolling to them starts instantly.
   Android: Media3 `CacheDataSource`/`PreloadMediaSource`; iOS: AVAsset
   preheating (MP4) or manifest-only warmup (HLS). Pairs with a feed's
   feed and the Vimeo HTTP extraction (resolve + prefetch together).
2. **Playback analytics events** — a single `analyticsStream` emitting
   structured events (startup time, first-frame, stall start/end + count,
   bitrate/variant switches, watched-duration heartbeats, completion).
   Both platforms already observe everything needed (KVO / Player.Listener);
   this exposes it. Apps get engagement/QoE metrics nearly for free.
3. **Resume-position convenience** — `load(..., startAt: Duration)` plus an
   optional `onPositionCheckpoint` callback (every N seconds, last value on
   dispose). Apps typically implement this app-side; plugin-level support
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
   Valuable for tenant-authenticated streams.
10. **Playlist/queue API** — `loadPlaylist([...])` with auto-advance and a
    `currentIndexStream`. Medium effort; interacts with the shared-player
    lifecycle, design carefully.

## Explicitly not recommended

- iOS-native sidecar subtitle injection (no sane AVPlayer API; already
  solved via the Flutter overlay + Android sideload).
- In-plugin Vimeo/YouTube extractors — site extraction churns and belongs
  app-side or server-side (Vimeo HTTP
  approach), not in a player plugin.

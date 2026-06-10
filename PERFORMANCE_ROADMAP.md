# Performance roadmap — beyond the lifecycle branch

Where the remaining performance lives, what each step buys, and what it
costs. Feasibility of every native API named here was verified against the
exact dependencies we ship (Media3 1.5.0 jars in the Gradle cache, iOS
deployment target 12.0) or against reference-plugin source in the pub cache.

After the current branch, the remaining cost of a multi-video feed has three
sources, in this order:

1. **Decode + network work scales with stream quality, not tile size.** Each
   feed tile decodes whatever ABR picks for a full-screen viewport — six
   ~360pt tiles can each be decoding 1080p. This is now the dominant
   multiplier.
2. **Per-view native UI weight.** Every inline tile carries a full
   `AVPlayerViewController` (controls UI, gesture recognizers, internal
   observation) on iOS and a Media3 `PlayerView` (inflated controller
   layout) on Android — even though Huddle always uses `overlayBuilder`, so
   the native controls are permanently hidden.
3. **Platform-view composition.** Inherent to UiKitView/hybrid-composition;
   only a texture-mode rearchitecture removes it.

## Tier 1 — viewport-aware quality capping (highest impact / low risk)

Cap each player's stream selection to what its on-screen size can show.
Verified APIs:

- **Android (Media3 1.5.0, confirmed via javap on the cached jar)**:
  `TrackSelectionParameters.Builder.setViewportSize(w, h, mayChange)`,
  `setMaxVideoSize(w, h)`, `setMaxVideoBitrate(int)`. Apply per player via
  `player.trackSelectionParameters`. Today the default viewport is the
  physical display size — every tile selects full-screen quality.
- **iOS**: `AVPlayerItem.preferredMaximumResolution` (iOS 11+) and
  `preferredPeakBitRate` (iOS 8+) — both within our 12.0 target.

Design (additive, like the existing config):
- `NativeVideoPlayerConfig.qualityForViewportSize: bool` (default false).
  The platform view reports its layout size (creation params + resize
  callback already flow through the channel); native sets the viewport /
  preferredMaximumResolution accordingly. Fullscreen entry clears the cap
  (we already get fullscreen transitions on both platforms).
- Escape hatches: per-controller `maxVideoHeight` / `maxBitrate` for apps
  that want manual control. Manual quality selection (existing API) always
  overrides the cap.

Expected effect: with 4-6 visible tiles, decode work and network drop by the
ratio of selected resolutions (1080p→360p is ~6-9× fewer pixels per stream).
This attacks the N=6 jank the current branch could not move (simulator CPU
saturation from N full-quality software decodes), and on devices it directly
relieves the hardware decode session pressure. Effort: ~1-2 days both
platforms incl. tests. Risk: low — pure ABR constraint, no lifecycle change.
Caveat: only helps HLS/adaptive sources; a single-file MP4 has nothing to
down-select (document this; Huddle's content is HLS).

## Tier 2 — lighter native views when controls are hidden (iOS first)

- **iOS**: when `showNativeControls == false` (always true for Huddle), host
  a plain `UIView` + `AVPlayerLayer` instead of a dedicated
  `AVPlayerViewController` per inline tile. PiP keeps working:
  `AVPictureInPictureController(playerLayer:)` (iOS 9+) supports
  `canStartPictureInPictureAutomaticallyFromInline` (14.2+), and the code
  already has a custom-`pipController` path (`VideoPlayerView.pipController`)
  that does exactly this for manual PiP. Native fullscreen already creates
  its own `AVPlayerViewController` on demand, so it is unaffected.
  Expected: noticeably cheaper view creation/teardown in scroll feeds and
  less per-view UIKit machinery alive per tile. Effort: ~2-3 days (the PiP
  ownership handoff between layer-PiP and AVPlayerViewController-PiP is the
  careful part). Risk: medium — PiP edge cases need real-device passes.
- **Android**: when controls are hidden, skip `PlayerView` (it inflates the
  full Media3 controller UI) and use `SurfaceView` inside an
  `AspectRatioFrameLayout`. Less per-tile inflation and view hierarchy.
  Effort: ~1-2 days. Risk: low-medium (resize/aspect handling moves to us).

## Tier 3 — playing-priority + smarter loading

- **Android `PriorityTaskManager`** (present in media3-common 1.5.0): give
  the most-recently-played player `PRIORITY_PLAYBACK` and demote the rest,
  so N players stop competing equally for bandwidth/IO. Pairs naturally with
  the existing `PlaybackCoordinator` MRU order. Effort: ~1 day. Risk: low.
- **Prepare-ahead / cache** (pattern: better_player's
  `CacheDataSource`/`SimpleCache`, `cached_video_player`): optional disk
  cache so revisited feed items skip the network, plus an opt-in
  `precache(url)` API for the next items in a feed. Android is
  straightforward (`CacheDataSource` wraps HLS too); iOS HLS caching is NOT
  practical inline (AVAssetDownloadTask is an offline-download API), so iOS
  would be MP4-only or skipped. Effort: ~3-4 days Android-led. Risk: medium
  (cache eviction, key correctness with DRM — must bypass cache for DRM).
- **ExoPlayer instance pooling**: reuse released player instances on
  dispose→create churn during fast scrolling. Smaller win than it sounds
  (codecs still re-init per source); only worth it after measuring creation
  cost on a real device. Effort: ~1-2 days. Risk: medium (lifecycle bugs —
  the exact class of bug this branch just fixed; needs the stress harness).

## Tier 4 — opt-in texture rendering (the architectural step)

The official `video_player_android` 2.9.5 ships BOTH render paths side by
side (`texture/` via `TextureRegistry.createSurfaceProducer()` — Impeller
compatible — and `platformview/`), so a dual-mode plugin is a proven shape.

- **Android texture mode**: near capability-neutral — PiP is activity-level
  (the `floating` package PiPs the whole activity, rendering mode
  irrelevant), media notifications unaffected, and Huddle never shows native
  controls inline. Removes hybrid-composition cost per tile entirely; feed
  tiles become ordinary Flutter textures (RepaintBoundary, raster cache,
  cheap clipping/transforms all work).
- **iOS texture mode**: loses inline PiP (PiP requires an on-screen
  `AVPlayerLayer`; that's why `video_player_avfoundation` added a
  platform-view mode specifically to support PiP). Realistic shape: texture
  mode for feed tiles, automatic switch to the platform view (same shared
  AVPlayer, same controller ID — the SharedPlayerManager reattachment we
  already have) for detail/fullscreen/PiP surfaces. The switch is the risky
  part (one black-frame-free handoff).

Effort: ~1-2 weeks Android, more for iOS with mode switching. Risk: high.
Recommendation: do Android texture mode first — it's where platform-view
composition hurts most (feeds on mid-range devices) and where nothing is
lost. Decide on iOS only after Tier 1/2 numbers come in; viewport capping +
AVPlayerLayer tiles may already be enough.

## Sequencing and measurement gate

1. **First: release-mode baseline on real devices** (Android device required
   — the emulator on this Mac cannot boot; iPhone available). The simulator
   numbers bound Dart-side wins but misrepresent decode (software vs
   hardware). Reuse the existing harness; add `adb shell dumpsys gfxinfo`
   for release-mode frame stats.
2. Tier 1 (viewport capping) — measure N=4/6 feed CPU/decode and network.
3. Tier 3a (PriorityTaskManager) — cheap, pairs with the coordinator.
4. Tier 2 (light views) — measure scroll-feed jank + view create/teardown.
5. Reassess: if feed jank on low-end Android still misses 60fps, green-light
   Tier 4 Android texture mode. Tier 3b caching is product-driven (TTFF on
   revisits) rather than jank-driven.

Every step lands behind `NativeVideoPlayerConfig` flags defaulting to
current behavior, keeps the API additive, and reruns the harness scenarios
(stress feed, scroll, nav loop, lifecycle stress, cap semantics) plus the
PiP/AirPlay/Now Playing device checklist before merging.

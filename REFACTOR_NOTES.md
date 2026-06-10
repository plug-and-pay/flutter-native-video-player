# Branch notes — fix/lifecycle-and-multi-video-performance

Working notes for the lifecycle + multi-video performance branch. (The
package CHANGELOG.md is intentionally untouched; it gets written at release.)

## Root cause: the MissingPluginException (GitHub issue #31)

`NativeVideoPlayerController`'s constructor subscribed to
`EventChannel('native_video_player_controller_$id')` immediately
(`native_video_player_controller.dart`), but the native StreamHandler for
that channel:

- **Android**: was NEVER registered (`teardownControllerEventChannel` was an
  explicit no-op; no `native_video_player_controller_*` registration existed
  anywhere) → the exception fired on every controller construction;
- **iOS**: was registered only inside platform-view creation
  (`VideoPlayerView` init → `setupControllerEventChannel`), which always runs
  AFTER the constructor → the exception fired on the first construction per
  controller ID. Teardown also never called `setStreamHandler(nil)`, leaving
  stale engine registrations that masked the bug on same-ID recreates while
  leaking handlers.

The EventChannel's internal `listen` invocation fails with
MissingPluginException and the services library reports it straight to
`FlutterError.onError` — the subscription's own `onError` never sees it,
which is why it looked "uncatchable".

Measured on master (iOS simulator, example app + stress harness): 3
exceptions at app startup (one per sample-card controller), 1 per mounted
feed tile, and exactly 2 per construct/dispose cycle (one `listen`, one
`cancel`) — 40 exceptions for 20 stress cycles, 75 in one session.

### Fix (ordering pattern from the official video_player plugin)

1. New `setupControllerEventChannel` method on the shared plugin
   MethodChannel registers the native handler BEFORE Dart listens; Dart
   awaits the ack (with brief retries for cold-start/hot-restart) and only
   then subscribes. Safety-net retry in `onPlatformViewCreated`.
2. Android got a real `ControllerEventChannelHandler` + sink registry in its
   `SharedPlayerManager` (parity with iOS).
3. Teardown is real on both platforms (`setStreamHandler(nil/null)`),
   awaited in `dispose()`, ordered: cancel subscription → teardown → native
   player disposal.
4. `dispose()` after `releaseResources()` now releases the native player via
   a new `disposeController` route (previously leaked).
5. `releaseResources()` untouched: the controller channel and native player
   still survive view disposal (PiP/AirPlay continuity).

## Changelog (branch)

- fix: MissingPluginException on controller construction/disposal (#31) —
  native handler registered before Dart listens, real teardown, ordered
  disposal (Dart + Swift + Kotlin)
- fix: native player leak when `dispose()` followed `releaseResources()`
- fix(ios): platform views were strongly retained forever by two static
  maps; `deinit` (the only disposal hook on iOS) never ran, leaking KVO
  observers, periodic time observers and route detectors per view unmount
- feat: `preventFullscreenSwipeDismiss` (default ON — approved default
  change) preventing the AVPlayerViewController swipe-dismiss black screen
  (community PR #32 by @anirudhrao-github)
- fix(ios): `isFullScreenStream` now fires for native-button fullscreen
  entry (community PR #34 by @AleSpero)
- feat: `NativeVideoPlayerConfig` (additive, defaults = old behavior):
  `maxConcurrentPlayingPlayers` (LRU pause, PiP/AirPlay exempt),
  `timeUpdateInterval`, `androidBufferConfig` / `iosBufferConfig` with
  `.feed()` presets
- perf(ios): all 411 `print()` calls gated behind DEBUG (`npLog`,
  @autoclosure); Now Playing XPC writes throttled from 2/s to ~1/5s with
  state-change-driven immediate updates; redundant `setupNowPlayingInfo`
  rebuilds short-circuited; one app-wide AVRouteDetector instead of one per
  view (+1 global)
- perf(android): `Log.*` gated on the app's debuggable flag (`NpLog`);
  the 500ms timeUpdate ticker now runs only while playing (one final update
  on pause/seek); per-event Handler allocation removed
- cleanup: dead MainActivity PiP listener removed; main-thread assertions
  documenting the iOS SharedPlayerManager threading contract; example app
  perf/stress harness (Marionette-drivable)

## Patterns borrowed from reference packages

- **Register-native-handler-before-Dart-listens**: official `video_player` —
  `video_player_avfoundation-2.9.7/darwin/.../VideoPlayerPlugin.swift`
  (create → `configurePlayer` → `FVPEventBridge` sets the stream handler
  before `create` returns; `FVPEventBridge.m:41-44`, teardown at `:107`) and
  `video_player_android-2.9.5/.../VideoPlayerPlugin.java:85-99` +
  `VideoPlayerEventCallbacks.java:18-32`. We adopted the ordering; their
  QueuingEventSink pre-listen buffer was not needed (argued in the dart
  commit message: controller events require a live player, which only exists
  after view creation).
- **Android buffer configuration surface**: `better_player` —
  `lib/src/configuration/better_player_buffering_configuration.dart` +
  `android/.../BetterPlayer.kt:101` (`setBufferDurationsMs`). Our
  `NativeVideoPlayerAndroidBufferConfig` mirrors the four parameters; unlike
  better_player we keep ExoPlayer defaults unless opted in.
- **Weak platform-view registry**: extended this repo's own
  `WeakVideoPlayerViewWrapper` pattern (SharedPlayerManager) to the plugin's
  static view registry.

## Baseline vs after (iOS simulator, iPhone 17 Pro Max, debug, ~21s windows)

| Scenario | Metric | master | branch |
|---|---|---|---|
| App startup (3 controllers) | MissingPluginExceptions | 3 | **0** |
| Lifecycle stress ×20 (construct/dispose) | MissingPluginExceptions | 40 (2/cycle) | **0** |
| Full cycle ×10 (mount/load/releaseResources/recreate-same-id/dispose) | MissingPluginExceptions | 1 + stale-handler leaks | **0** |
| Whole session | MissingPluginExceptions | 75 | **0** |
| Feed N=2 | total frame avg/p90 ms; jank>16ms; mem | 4.44/7.12; 4.2%; 327-336M | 3.68/6.42; 2.6%; **264-273M** |
| Feed N=4 | same | 7.82/19.19; 32%; 389-398M | 6.40/19.06; 26%; **366-377M** |
| Feed N=6 | mem; playing | 491-495M | **441-453M**; all 6 playing |
| Fast scroll (30-tile lazy feed) | total avg; jank>16ms | 8.36ms; **40%** | 5.83ms; **24%** |
| Nav loop ×10 (shared controller ID) | position monotonic; black frames | yes; none | yes; none |
| Cap=2 on N=4 feed (live) | playing count | n/a (no cap) | **2**, LRU paused at exact position |

Frame counts per window also dropped sharply (e.g. N=4: 541 → 309 frames
built) — fewer per-tick UI rebuilds. N=6 jank ratio is noisy on the
simulator (6 software-decoded streams saturate the host CPU); memory and CPU
are the reliable signals there. TTFF unchanged within noise (HLS ~120-210ms,
MP4 ~200-360ms).

## Verification status

- `flutter analyze`: zero issues (package + example); `dart format .`: no diff
- Dart tests: 47/47 passing (previously 11/31 — the old suite timed out
  because `initialize()` waits for platform-view creation that never happened
  in tests)
- iOS simulator (Marionette-driven): see baseline-vs-after table in the PR
  description / final report
- iOS device (PiP / Now Playing / AirPlay): guided manual checks
- **Android emulator: NOT verified on this machine** — the emulator
  (36.3.10, macOS 26.2) hangs at Vulkan init with every GPU mode; Android
  verification needs a physical device (see manual checklist). Android
  changes are covered by compile + unit tests + cross-platform symmetry.

## Manual test checklist (what automation can't cover here)

- [ ] Android physical device: example app boot, stress feed N=4, MPE
      counter stays 0, media notification persists across list↔detail
      (`adb shell dumpsys media_session`), PiP enter/exit via fullscreen
- [ ] iOS device: inline PiP, automatic PiP on home-press, restore without
      black frame; PiP'd player never auto-paused with cap=1 active
- [ ] iOS device: lock-screen / Control Center Now Playing through
      list→detail→back — no flicker, no metadata reset, no duplicate item
- [ ] iOS device + AirPlay target: session survives list↔detail navigation;
      device-name stream; cap exemption; disconnect restores local playback
- [ ] Low-end Android device feel with the `.feed()` presets + cap=2/3
- [ ] Release-mode smoke test on both platforms (logging is now silent in
      release — confirm nothing depended on it)

## Testing pattern: injecting native events in widget tests

`test/player_features_test.dart` drives the controller with fake native
events (`setMockStreamHandler` + `MockStreamHandlerEventSink.success`). Two
rules keep that deterministic, learned the hard way:

1. **Register the mock stream handlers AND construct the controller inside
   the test body, never in `setUp`.** `setUp` runs outside `testWidgets`'
   fake-async zone, and flutter_test pins handlers to the zone that
   registered them — events injected through a setUp-registered handler are
   delivered on the real event loop, where the fake-async test never (or
   only flakily) observes them. The sink looks fine — `onListen` still
   fires — which makes this miserable to debug. A `setMockMethodCallHandler`
   in `setUp` is fine: method calls originate from the fake zone.
2. **Fresh controller/view ids per test.** Same ids = same EventChannel
   names; a previous test's late async `cancel` can clear the message
   handler the current test just registered. (The on-device analogue is why
   the stress harness uses fresh ids per visit.)

Corollary: a fake-zone-constructed controller must be disposed in-body or
with a timeout in `tearDown` — `dispose()` awaits futures that can never
complete once the fake zone is gone.

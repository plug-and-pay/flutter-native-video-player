# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`better_native_video_player` — a Flutter plugin published to pub.dev that wraps native video players: **AVPlayerViewController** (iOS, Swift) and **ExoPlayer/Media3** (Android, Kotlin). Supports HLS with quality/subtitle selection, DRM (FairPlay/Widevine/AES-128/ClearKey), Picture-in-Picture, AirPlay, fullscreen, and background playback.

## Commands

```bash
flutter pub get                 # install dependencies
flutter analyze                 # lint (flutter_lints, see analysis_options.yaml)
flutter test                    # run all Dart tests
flutter test test/native_video_player_test.dart   # run a single test file
dart format .                   # format (run before committing)

cd example && flutter run       # run the example app (needs an iOS/Android device)
```

Tests live in `test/` and mock the `native_video_player` MethodChannel with `setMockMethodCallHandler` — there are no integration tests against real players; verifying native behavior requires running the example app on a device.

**Releasing:** bump `version` in `pubspec.yaml`, add a matching entry to `CHANGELOG.md`.

### Verifying changes with Marionette

The example app embeds [Marionette](https://github.com/leancodepl/marionette_mcp) (`MarionetteBinding.ensureInitialized()` in `example/lib/main.dart`), and the `marionette` MCP server is registered in `.mcp.json`, so you can drive the running app yourself instead of asking the user to test:

1. `cd example && flutter run` on a device/simulator (debug mode only — Marionette needs the VM service).
2. Copy the VM Service URI from the run output (`ws://127.0.0.1:<port>/<token>/ws`).
3. Call the `marionette` MCP `connect` tool with that URI, then use its screenshot/tap/scroll/enter-text tools to verify behavior.

Native player rendering (the platform view itself) is invisible to widget inspection — use screenshots to verify actual video output.

## Architecture

### Channel topology (the key concept)

There are two distinct IDs that must not be confused:

- **Controller ID** (`NativeVideoPlayerController(id: ...)`) — chosen by the app, identifies a logical player. The same controller ID can back multiple platform views (e.g. list thumbnail + detail screen) sharing one native player.
- **Platform view ID** (`viewId`) — assigned by Flutter per `NativeVideoPlayer` widget instance.

Channels:
- `native_video_player` — single shared **MethodChannel** for all commands (Dart → native). Every call passes `viewId`; native resolves it to the shared player. Wrapped by `lib/src/platform/video_player_method_channel.dart`.
- `native_video_player_$viewId` — per-view **EventChannel** (native → Dart) for playback events.
- `native_video_player_controller_$id` — per-controller **EventChannel** for events that must survive view disposal (PiP, AirPlay).

### Shared player management

Both platforms have a `SharedPlayerManager` (singleton) that keeps native players alive keyed by controller ID, independent of platform view lifecycle. Each view gets its own surface (`PlayerView` / view layer) but attaches to the shared player. One view per controller is the "primary" view (receives PiP, surface reconnection). This is what makes `releaseResources()` (keep native player, drop Flutter resources) vs `dispose()` (destroy everything) meaningful — see README "Lifecycle Management".

### Layout

- `lib/src/controllers/native_video_player_controller.dart` — the core (~2500 lines): state, event routing, listener APIs, property streams, fullscreen orchestration, PiP/AirPlay coordination.
- `lib/src/native_video_player_widget.dart` — `NativeVideoPlayer` widget; creates the platform view (viewType `native_video_player`) and the optional `overlayBuilder` custom controls.
- `lib/src/fullscreen/` — Dart-side fullscreen: `FullscreenManager` (orientation save/restore) and `FullscreenVideoPlayer` (route using `dismissible_page` for swipe-to-dismiss).
- `lib/src/services/airplay_state_manager.dart` — global app-wide AirPlay detection singleton (iOS).
- `lib/src/platform/platform_utils*.dart` — conditional imports (`_io` / `_stub`) keeping the package WASM-compatible; don't import `dart:io` directly in new code outside `platform_utils_io.dart`.
- `ios/Classes/` and `android/src/main/kotlin/.../` mirror each other: `VideoPlayerView` (platform view), `handlers/` (method, event, quality, notification/now-playing, observer, DRM), `manager/SharedPlayerManager`.
- `lib/better_native_video_player.dart` — public API surface; export new public types here.

### Platform-specific behavior to keep in mind

- **Android PiP** is implemented via the `floating` package and only works in Dart fullscreen mode (custom overlay controls); iOS PiP works inline via `AVPictureInPictureController`. The controller registers an app lifecycle observer on Android to hide overlays before automatic PiP.
- **Android background playback** uses `VideoPlayerMediaSessionService` (Media3 MediaSessionService); the plugin's own manifest declares the service and permissions.
- Method channel wrappers swallow most platform errors with `debugPrint` and return defaults — failures are intentionally non-throwing for playback commands.

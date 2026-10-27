# better_native_video_player

[![pub package](https://img.shields.io/pub/v/better_native_video_player.svg)](https://pub.dev/packages/better_native_video_player)
[![likes](https://img.shields.io/pub/likes/better_native_video_player)](https://pub.dev/packages/better_native_video_player/score)
[![platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android-8B5CF6)](#platform-support)
[![license: MIT](https://img.shields.io/badge/license-MIT-EC4899)](LICENSE)

**The real native players — AVPlayer on iOS, ExoPlayer (Media3) on Android — with Flutter controls on top.**

You get everything the platform players are good at (HLS, DRM, Picture-in-Picture, AirPlay, background audio, lock-screen controls) and you draw the UI in Flutter, exactly how your app looks.

![Four screens of the showcase app: captions, a poster with a preview animation, a live stream, a video feed](https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/banner.webp)

<table>
  <tr>
    <td align="center" width="50%"><img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/poster.webp" alt="A poster that turns into a highlights preview, then plays"><br><sub><b>Poster → preview → play</b><br>a thumbnail, then highlights, then the video</sub></td>
    <td align="center" width="50%"><img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/scrub.webp" alt="Scrubbing with thumbnail previews"><br><sub><b>Scrub previews</b><br>storyboard thumbnails while you drag</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/chapters.webp" alt="Scrubbing a seek bar split into chapters, snapping to a chapter start"><br><sub><b>Seek bar &amp; chapters</b><br>YouTube-style chapters that snap while you drag</sub></td>
    <td align="center"><img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/live.webp" alt="Scrubbing back in a live stream and jumping to live"><br><sub><b>Live with DVR</b><br>scrub back, tap LIVE to catch up</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/fullscreen.webp" width="300" alt="Fullscreen flies out of the page, swipe down to close"><br><sub><b>Fullscreen that flies</b><br>out of the page, swipe down to close</sub></td>
    <td align="center"><img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/pip.webp" width="300" alt="Picture-in-Picture over the home screen"><br><sub><b>Picture-in-Picture</b><br>keeps playing over other apps</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/cast.webp" width="300" alt="Finding and casting to a Chromecast"><br><sub><b>Chromecast</b><br>no Cast SDK, pure Dart</sub></td>
    <td align="center"><img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/airplay.webp" width="300" alt="Sending the video to an Apple TV with AirPlay"><br><sub><b>AirPlay</b><br>to Apple TV and AirPlay speakers</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/screenshots/captions.webp" width="300" alt="Styled sidecar captions over the video"><br><sub><b>Captions</b><br>embedded tracks and styleable VTT/SRT</sub></td>
    <td align="center"><img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/screenshots/lock_screen.webp" width="300" alt="Now Playing on the iOS lock screen with artwork and controls"><br><sub><b>Lock screen & background</b><br>artwork, title and controls, keeps playing</sub></td>
  </tr>
  <tr>
    <td align="center" colspan="2"><img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/screenshots/feed.webp" width="300" alt="A feed of videos with posters and duration badges"><br><sub><b>Built for feeds</b><br>posters, badges, offline downloads</sub></td>
  </tr>
</table>

All of this is one file: [`example/lib/main.dart`](example/lib/main.dart). Run it with `cd example && flutter run`.

## Contents

- [Why this player](#why-this-player)
- [Getting started](#getting-started)
- [Playing video](#playing-video) — sources, headers, resume positions, controls, looping
- [Your own controls](#your-own-controls) — overlays, posters, scrub previews, seek bar & chapters
- [Fullscreen](#fullscreen)
- [Picture-in-Picture](#picture-in-picture)
- [AirPlay](#airplay-ios) · [Chromecast](#chromecast)
- [Background playback & lock screen](#background-playback--lock-screen)
- [Live streams](#live-streams)
- [Quality, captions & audio tracks](#quality-captions--audio-tracks)
- [Playlists, A-B loops & analytics](#playlists-a-b-loops--analytics)
- [Offline downloads](#offline-downloads)
- [DRM](#drm)
- [Feeds & performance](#feeds--performance)
- [Lifecycle & sharing a player between screens](#lifecycle--sharing-a-player-between-screens)
- [Events & state](#events--state)
- [API reference](#api-reference)
- [Troubleshooting](#troubleshooting)

## Why this player

| | |
|---|---|
| 🎬 **Truly native** | AVPlayer and ExoPlayer do the decoding, buffering and adaptive streaming. Flutter only draws the controls. |
| 🎨 **Your UI** | Custom controls with `overlayBuilder`, posters with animated previews, scrub thumbnails, styleable captions. |
| 📺 **Everywhere** | Picture-in-Picture, AirPlay, Chromecast, fullscreen with a hero animation, background audio, lock-screen controls. |
| 📡 **Every stream** | HLS (VOD and live, with DVR), MP4 and local files. FairPlay, Widevine, AES-128 and ClearKey DRM. |
| 🧰 **The extras you'd build anyway** | Playlists, resume positions, A-B loops, offline downloads, playback analytics, Bunny Stream helpers. |
| 🚀 **Built for feeds** | Concurrency caps, viewport-sized quality, disk cache, precaching and texture rendering for smooth scrolling. |

## Getting started

### Install

```bash
flutter pub add better_native_video_player
```

### Platform support

| Platform | Minimum |
|----------|---------|
| iOS | 12.0 (CocoaPods, or Swift Package Manager on Flutter 3.44+) |
| Android | API 24 (Android 7.0) |

The package is WASM-compatible, so it doesn't break web builds of your app. Playback itself is iOS and Android only.

### iOS setup

Add to `ios/Runner/Info.plist`:

```xml
<!-- Background audio, Picture-in-Picture and AirPlay -->
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>picture-in-picture</string>
</array>

<!-- Only if you use Chromecast discovery. The first scan asks for
     Local Network permission. -->
<key>NSLocalNetworkUsageDescription</key>
<string>Used to find Cast devices on your network.</string>
<key>NSBonjourServices</key>
<array>
    <string>_googlecast._tcp</string>
</array>
```

Prefer Xcode? *Target → Signing & Capabilities → + Capability → Background Modes →* tick **Audio, AirPlay, and Picture in Picture**.

Playing plain `http://` URLs also needs `NSAppTransportSecurity` exceptions; HTTPS works out of the box.

### Android setup

Nothing to do. The plugin's manifest brings the internet permission, the media-session service for background playback and Picture-in-Picture support.

### Your first player

```dart
import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

class VideoPage extends StatefulWidget {
  const VideoPage({super.key});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  final _controller = NativeVideoPlayerController(id: 1, autoPlay: true);

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await _controller.initialize(); // waits for the native view
    await _controller.load(
      url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: NativeVideoPlayer(controller: _controller),
    );
  }
}
```

That's a fully working player with the platform's own controls. Everything below is optional.

## Playing video

### Sources

```dart
// HLS (adaptive, with quality/caption/audio track selection)
await controller.load(url: 'https://example.com/master.m3u8');

// MP4 and other progressive files
await controller.load(url: 'https://example.com/video.mp4');

// Files on the device
await controller.loadFile(path: '${dir.path}/video.mp4');
await controller.load(url: 'file:///path/to/video.mp4'); // same thing

// Another URL replaces the video; the same URL again is skipped while
// the video is still `loaded`, unless you force it
await controller.load(url: nextUrl);
await controller.load(url: sameUrl, force: true);
```

`loadUrl(...)` is an alias of `load(...)` for remote URLs. Formats are whatever the platform player supports: HLS, MP4, MOV, M4V on iOS; HLS, MP4, WebM, MKV on Android.

### Headers

Send auth tokens or a referer with every request, including segments:

```dart
await controller.load(
  url: 'https://example.com/video.m3u8',
  headers: {'Authorization': 'Bearer $token', 'Referer': 'https://example.com'},
);
```

### Resume where the viewer left off

`startAt` is applied natively **before the first frame**, so there's no visible jump:

```dart
await controller.load(url: url, startAt: const Duration(minutes: 12, seconds: 30));
```

To remember positions, `PositionCheckpoints` reports the position at most once per interval, plus a final one when disposed:

```dart
final checkpoints = PositionCheckpoints(
  controller,
  interval: const Duration(seconds: 5),
  onCheckpoint: (position) => storage.save(videoId, position),
);
// later, together with the player:
checkpoints.dispose(); // flushes the last position
```

### Playback controls

```dart
await controller.play();
await controller.pause();
await controller.seekTo(const Duration(seconds: 30));
await controller.setVolume(0.8);         // 0.0 – 1.0
await controller.setSpeed(1.5);          // 0.25× – 2.0×
await controller.setLooping(true);       // seamless native loop
```

`enableLooping: true` on the controller loops from the start. It uses ExoPlayer's `REPEAT_MODE_ONE` and a gapless replay on iOS, so there's no stutter.

## Your own controls

### Custom overlay

Pass `overlayBuilder` and the native controls step aside for yours:

```dart
NativeVideoPlayer(
  controller: controller,
  overlayBuilder: (context, controller) => MyControls(controller: controller),
)
```

The player takes care of the behavior around it:

- a tap shows the overlay, a tap on empty space hides it
- it fades out after 3 seconds (`overlayFadeDuration` sets the fade)
- buttons and sliders in it work as usual
- it comes along into fullscreen

Keep it on screen with `controller.lockOverlay()` (handy for live TV) and release it with `unlockOverlay()`.

A minimal overlay reads the controller and rebuilds on its events:

```dart
class MyControls extends StatefulWidget {
  const MyControls({super.key, required this.controller});
  final NativeVideoPlayerController controller;

  @override
  State<MyControls> createState() => _MyControlsState();
}

class _MyControlsState extends State<MyControls> {
  NativeVideoPlayerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addActivityListener(_refresh);
    c.addControlListener(_refresh);
  }

  void _refresh(Object _) {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeActivityListener(_refresh);
    c.removeControlListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playing = c.activityState.isPlaying;
    final total = c.duration.inMilliseconds.toDouble();
    return Stack(children: [
      Center(
        child: IconButton(
          iconSize: 56,
          color: Colors.white,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          onPressed: playing ? c.pause : c.play,
        ),
      ),
      Positioned(
        left: 12, right: 12, bottom: 8,
        child: Slider(
          max: total > 0 ? total : 1,
          value: c.currentPosition.inMilliseconds.toDouble().clamp(0.0, total),
          secondaryTrackValue: c.bufferedPosition.inMilliseconds.toDouble().clamp(0.0, total),
          onChanged: (ms) => c.seekTo(Duration(milliseconds: ms.round())),
        ),
      ),
    ]);
  }
}
```

The showcase's `CinemaControls` adds skip buttons, a buffering spinner, PiP and AirPlay buttons, a live pill and scrub previews in about 150 lines.

### Posters & preview animations

Show a thumbnail instead of a black box while the video loads. If the viewer lingers on a video they haven't played, fade in an animated preview of its highlights, like streaming apps do:

<img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/poster.webp" width="420" alt="Poster, preview animation, play">

```dart
NativeVideoPlayer(
  controller: controller,
  poster: NativeVideoPlayerPoster(
    image: NetworkImage('https://cdn.example.com/video/thumbnail.jpg'),
    animation: NetworkImage('https://cdn.example.com/video/preview.webp'),
    animationDelay: const Duration(seconds: 2), // still first, then the preview
    duration: const Duration(minutes: 9, seconds: 56), // badge: "9:56"
  ),
)
```

Everything about it is adjustable:

| Option | What it does | Default |
|---|---|---|
| `image` | the still thumbnail (any `ImageProvider`) | — (just `backgroundColor`) |
| `animation` | the preview: animated GIF or WebP | — |
| `animationDelay` | how long the still shows before the preview starts | 3 s |
| `animationDuration` | how long the preview plays before going back to the still | until play |
| `repeatAnimation` | with a duration: wait, play, wait, play… | `true` |
| `fit`, `alignment`, `backgroundColor` | how the images fill the player | cover, center, black |
| `fadeDuration` | the cross-fades between still, preview and video | 350 ms |
| `hideWhen` | give way on `onPlay`, or `onLoaded` to show the first frame | `onPlay` |
| `showOnCompleted` | bring the poster back when the video ends | `false` |
| `duration`, `isLive` | badge text before the player knows ("9:56", "1:02:03", "LIVE") | from the player |
| `showDurationBadge`, `badgeAlignment`, `badgeBuilder` | show, place or replace the badge | bottom right |
| `showPlayButton` | a play button when the player shows native controls | `true` |
| `overlayBuilder` | anything on top (title, spinner…), gets the poster state | — |

Bunny Stream users get it in one line. It uses the video's `thumbnail.jpg` and `preview.webp` (or `.gif`):

```dart
poster: NativeVideoPlayerPoster.bunny('https://vz-abc123.b-cdn.net/$videoId'),
```

A protected pull zone? Pass `headers:` and both images are requested with them. For any other host, give `image` a `NetworkImage(url, headers: {...})`.

> Why no MP4/WebM preview? A muted second native player would still take over the audio session and pause the user's music, and iOS can't play WebM. Use GIF or animated WebP, or draw your own preview in `overlayBuilder`.

### Scrub previews

Show thumbnails while the viewer drags the seek bar. This works with WebVTT storyboards (Vimeo, Mux, JW Player) and with uniform sprite grids (Vimeo `thumb_preview`, Bunny Stream):

<img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/scrub.webp" width="420" alt="Scrub preview thumbnails">

```dart
// A WebVTT storyboard ("sprite.jpg#xywh=x,y,w,h" cues)
final board = await StoryboardThumbnails.fromUrl('https://cdn.example.com/storyboard.vtt');

// A uniform sprite grid
final board = StoryboardThumbnails.fromUniformGrid(
  spriteUrls: ['https://cdn.example.com/sprites.webp'],
  frameInterval: const Duration(seconds: 5),
  columns: 10, frameWidth: 426, frameHeight: 240, framesPerSprite: 120,
);

// Bunny Stream: seek/_0.jpg, _1.jpg … (6×6 grids, a frame every 2 s)
final board = StoryboardThumbnails.bunny(
  videoBaseUrl: 'https://vz-abc123.b-cdn.net/$videoId',
  duration: videoLength,
);

// …or straight from the HLS URL you play. A signed URL keeps its token.
// Without aspectRatio the frame shape is measured from the sprite, so
// portrait videos work too.
final board = StoryboardThumbnails.bunnyFromPlaylistUrl(playlistUrl, duration: videoLength);

final thumb = board.thumbnailAt(dragPosition);
// thumb.url + thumb.region: crop that rectangle out of the sprite sheet
```

Behind a CDN that checks the `Referer`? Pass headers: `StoryboardThumbnails.fromUrl(url, headers: {...})` for the VTT, and `storyboardHeaders:` on the seek bar below for the images.

Hand the storyboard to [`NativeVideoPlayerProgressBar`](#seek-bar--chapters) and it does the rest. If you draw your own bar, `NativeVideoPlayerScrubPreview` is the bubble on its own.

### Seek bar & chapters

<img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/chapters.webp" width="420" alt="Scrubbing a seek bar split into chapters, with the chapter title in the preview">

`NativeVideoPlayerProgressBar` is a seek bar for your overlay. It shows the buffered range and a scrub preview, and splits into chapters like YouTube:

- The bar is split into one segment per chapter, with a small gap where each chapter starts. The segment under your finger grows a little.
- While you drag, the bubble above the bar shows the storyboard frame, the chapter title and the time.
- **Snapping:** when the drag comes within 8 px of a chapter start, it jumps to that start, with a light haptic tick. Let go and it seeks there. So landing exactly on "Part two" is easy.

```dart
// Chapters, from a description...
final chapters = NativeVideoPlayerChapters.parseText('''
0:00 Intro
1:23 Setting up
12:05 Outro
''');
// ...or from a WebVTT chapters track
final chapters = await NativeVideoPlayerChapters.fromVttUrl('https://cdn.example.com/chapters.vtt');

await controller.load(url: url, chapters: chapters); // or controller.setChapters(chapters)

// In your overlay
NativeVideoPlayerProgressBar(
  controller: controller,
  storyboard: board, // optional scrub thumbnails
)
```

The controller knows which chapter is playing: `controller.currentChapter` (and `currentChapterIndex`) with `currentChapterStream`, for a "Setting up ›" label anywhere in your overlay. Control listeners get it too, as `PlayerControlState.chapterChanged` (and `chaptersChanged` when the list changes), so an overlay that already rebuilds on `addControlListener` needs nothing extra. `seekToNextChapter()` / `seekToPreviousChapter()` skip around. Previous restarts the current chapter when you're more than 3 s in, like a music player. A chapter runs until the next one starts. Chapters are ignored for live streams, and loading a different video clears them.

**Make it look like your app.** Every size, color and animation is in two style objects:

```dart
NativeVideoPlayerProgressBar(
  controller: controller,
  storyboard: board,
  storyboardHeaders: {'Referer': 'https://example.com'},
  showPreview: controller.isFullScreen, // no bubble on the small inline player
  snapDistance: 8,                      // px; snapToChapters: false turns it off
  style: const NativeVideoPlayerProgressBarStyle(
    height: 20,   // the bar's box and touch area; by default it fits the bar
    barHeight: 2,
    expandedBarHeight: 7, // the whole bar thickens while touched
    thumbRadius: 0,       // no thumb at rest...
    expandedThumbRadius: 10, // ...it grows in when touched
    collapseDelay: Duration(seconds: 2),
    playedColor: Colors.pink,
    bufferedColor: Colors.white,
    backgroundColor: Colors.white60,
  ),
  previewStyle: NativeVideoPlayerScrubPreviewStyle(
    backgroundColor: Colors.grey.shade900, // a tooltip bubble...
    padding: const EdgeInsets.all(8),
    borderRadius: BorderRadius.circular(4),
    arrowSize: const Size(8, 6),           // ...with an arrow
    showThumbnail: true, showChapterTitle: true, showTime: true,
    timeFormatter: (d) => myFormat(d),
  ),
)
```

While you scrub, the bar keeps the overlay from hiding (`controller.holdOverlay()`, which leaves your own `lockOverlay()` alone), and the hide timer starts over when you let go. `onScrubStart`, `onScrubUpdate` and `onScrubEnd` are there for anything else, like a time label that follows the finger.

Or replace the bubble entirely with `previewBuilder: (context, details) => ...` (you get the position, chapter, storyboard frame and whether it snapped).

**Show the scrub somewhere else.** The bar reports what the finger is on:

| Callback | When |
|---|---|
| `onScrubStart` / `onScrubUpdate` / `onScrubEnd` | the drag starts, moves (snapped position), ends (seek target) |
| `onScrubChapterChanged` | the finger moves into another chapter; `null` when the drag ends |
| `onSnap` | the drag snaps to a chapter start |
| `onPreviewChanged` | anything in the preview changes (position, chapter, frame, snapped); `null` when it goes away |

`onPreviewChanged` also fires with `showPreview: false`, so you can hide the bubble and draw the frame and title wherever you like, such as large in the middle of the video.

**Your own values and seeking.** Pass `position`, `duration`, `bufferedPosition` or `isLive` to override what the controller reports, and `onSeek` to seek another way (e.g. while casting). Pass all of them and you don't need a controller at all, so the same bar works for an audio player.

**Small players.** The bubble never sticks out of the player: it is limited to the room between the bar and the top of the player, and to the bar's width, and scaled down when it doesn't fit (left out when there is hardly any room). `previewMaxHeight` caps it further. Frames keep their own shape, so a portrait video's frame shows tall, bounded by `thumbnailWidth` (and `thumbnailMaxHeight`).

**Images.** Storyboard images load with `storyboardHeaders`, or through your own provider (`storyboardImageProvider: (url, headers) => CachedNetworkImageProvider(url, headers: headers)`). The bar keeps the sheets around the playing position (and around your finger while scrubbing) loaded, before the first play too, so the frame is there when you scrub. That's at most `storyboardPrecacheLimit` sheets (default 4), so memory stays bounded. While a sheet is still loading the bubble shows just the time; an image that fails to load is left out and tried again on a later scrub.

**Your own bar.** The math is public too: `NativeVideoPlayerChapters.segments(chapters, duration)` gives each segment's start and end as fractions of the bar, and `snapTarget(chapters, position, threshold:)` the chapter start to snap to.

## Fullscreen

```dart
await controller.enterFullScreen();
await controller.exitFullScreen();
await controller.toggleFullScreen();
```

**With a custom overlay** you get Flutter fullscreen with your controls. The video **flies out of the inline player** into fullscreen and back, and keeps playing during the flight. **Swipe down to close**, Instagram-style: the video follows your finger, shrinks and rounds its corners, then flies back into the page.

<img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/fullscreen.webp" width="300" alt="Fullscreen flight and swipe down to close">

```dart
NativeVideoPlayerController(
  id: 1,
  fullscreenFlightBorderRadius: BorderRadius.circular(20), // match your inline clip
  lockToLandscape: false, // follow the phone instead of forcing landscape
  preferredOrientations: [DeviceOrientation.portraitUp], // restored on exit
);
```

- On Android the flight needs `androidTextureMode` (see [Feeds & performance](#feeds--performance)). With platform views it falls back to a fade.
- **Without an overlay**, fullscreen is the platform's own (`AVPlayerViewController` / ExoPlayer).
- On iOS, native fullscreen is closed with its Done button. Set `preventFullscreenSwipeDismiss: false` to allow the system swipe as well.
- Orientations are saved and restored for you. `FullscreenManager.setPreferredOrientations()` changes what's restored.

## Picture-in-Picture

<img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/pip.webp" width="300" alt="Picture-in-Picture">

```dart
NativeVideoPlayerController(
  id: 1,
  allowsPictureInPicture: true,               // default
  canStartPictureInPictureAutomatically: true, // on going home (iOS 14.2+, Android 8+)
);

if (await controller.isPictureInPictureAvailable()) {
  await controller.enterPictureInPicture();   // or exitPictureInPicture / togglePictureInPicture
}
controller.isPipEnabledStream.listen((inPip) => print('in PiP: $inPip'));
```

**Back to the right screen.** The PiP window outlives the screen that opened it. When the viewer taps "back to app" (iOS) or expands the window (Android), `onPictureInPictureRestore` lets you open that screen again. On iOS the window waits for your handler and flies into the player once it's fully visible:

```dart
controller.onPictureInPictureRestore = () {
  if (controller.isPlayerFullyVisible) return; // already on screen
  router.go('/video/$id'); // start it, don't await it
};
```

Keep that controller alive while the window is open (for example in your feed's state, not in the screen's widget).

Platform notes:

- **iOS** PiP works inline and in fullscreen, through `AVPictureInPictureController`. `enableAutomaticInlinePip()` / `disableAutomaticInlinePip()` switch automatic PiP at runtime.
- **Android** PiP is built into the plugin and works from **Dart fullscreen** (custom overlay). Automatic PiP on leaving the app needs Android 12 (API 31); `enterPictureInPicture()` works from Android 8. The whole activity becomes the window, so your overlays are hidden first. No `MainActivity` changes are needed.

## AirPlay (iOS)

<img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/airplay.webp" width="300" alt="AirPlay picker">

Start the app-wide route detection once, after creating your first controller:

```dart
await controller.initialize();
await AirPlayStateManager.instance.init(); // a no-op on Android
```

Then:

```dart
if (await controller.isAirPlayAvailable()) await controller.showAirPlayPicker();
await controller.disconnectAirPlay();

controller.isAirplayAvailableStream.listen(...);   // show or hide your button
controller.isAirplayConnectedStream.listen(...);
controller.isAirplayConnectingStream.listen(...);
controller.airPlayDeviceNameStream.listen(...);    // "Living Room"

// Or listener style:
controller.addAirPlayAvailabilityListener((available) => print('AirPlay devices: $available'));
controller.addAirPlayConnectionListener((connected) => print('on AirPlay: $connected'));
```

AirPlay state is global: every controller reports the same route.

## Chromecast

<img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/cast.webp" width="300" alt="Chromecast">

Casting without the Cast SDK. The protocol (CASTV2 over TLS) is pure Dart. Discovery uses Bonjour on iOS and pure-Dart mDNS elsewhere. It has its own entrypoint, so import it with a prefix:

```dart
import 'package:better_native_video_player/cast.dart' as cast;

try {
  final devices = await cast.CastDeviceDiscovery.discover();
  final session = await cast.CastSession.connect(devices.first);

  await session.loadMedia(
    contentUrl: 'https://example.com/video.m3u8',
    contentType: 'application/x-mpegURL',
    title: 'Big Buck Bunny',
    subtitle: 'Blender Foundation',
    imageUrl: 'https://example.com/poster.jpg',
    textTracks: [
      cast.CastTextTrack(trackId: 1, url: 'https://example.com/en.vtt', language: 'en', name: 'English'),
    ],
    activeTrackIds: [1],
    startAt: controller.currentPosition, // continue where the phone was
  );
} on cast.CastDiscoveryException catch (e) {
  print(e.message); // wrong network or no Local Network permission — never a crash
}
```

Remote control, kept in sync with the TV:

```dart
await session.play();  await session.pause();  await session.stop();
await session.seek(const Duration(minutes: 2));
await session.setVolume(0.4);  await session.setMuted(true);
await session.setActiveTracks([1]);   // captions on; [] = off
session.setLooping(true);

// Changes made on the TV, Google Home or by voice show up here too:
session.statusStream.listen((s) => print('${s.playerState} ${s.position}'));
await session.close();
```

For a live stream pass `streamType: 'LIVE'` to `loadMedia`. The receiver fetches the URLs itself, so they must be public HTTPS (with CORS headers for VTT files).

## Background playback & lock screen

Videos keep playing in the background, with Control Center and the lock screen on iOS and a media notification on Android. Give them a title and artwork:

<img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/screenshots/lock_screen.webp" width="300" alt="Now Playing on the iOS lock screen">

```dart
NativeVideoPlayerController(
  id: 1,
  mediaInfo: const NativeVideoPlayerMediaInfo(
    title: 'Big Buck Bunny',
    subtitle: 'Blender Foundation',
    album: 'Open Movies',
    artworkUrl: 'https://example.com/poster.jpg',
  ),
);
```

Don't want background playback for a player? Use `BackgroundPlaybackGuard`:

```dart
final guard = BackgroundPlaybackGuard(controller); // pauses on background, resumes on return
guard.pauseInBackground = false;                   // flip it at runtime (a user setting)
guard.dispose();
```

PiP and AirPlay sessions keep playing, and a video the viewer paused stays paused.

**Other apps' audio is respected.** Music or a podcast is only interrupted while a video actually plays. If the viewer pauses the video and goes back to Spotify, Spotify keeps playing when they return to your app.

**Muted tiles and background loops** shouldn't interrupt it at all. Even a muted video takes a non-mixable audio session on iOS and audio focus on Android, which stops Spotify. Opt out per player:

```dart
NativeVideoPlayerController(
  id: 1,
  autoPlay: true,
  enableLooping: true,
  mixWithOthers: true, // other apps' audio keeps playing
);
```

A mixing player stays off the lock screen and out of the media notification, and doesn't take automatic Picture-in-Picture, so a real video playing next to it keeps those. While a player that doesn't mix plays, mixing ones leave the audio session to it.

## Live streams

<img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/media/live.webp" width="420" alt="Live stream with DVR">

Live HLS just works. For live streams the controller tells you more:

```dart
controller.isLive;            // true for a live stream
controller.isLiveStream;      // Stream<bool>
controller.duration;          // the DVR window (how far back you can go)
controller.currentPosition;   // where you are inside that window
controller.liveEdgeOffset;    // how far behind live you are
await controller.seekToLiveEdge(); // the "LIVE" button
```

`seekTo` takes a position inside the window, so a regular seek bar works as a DVR scrubber. Show a "LIVE" badge while `liveEdgeOffset` is a few seconds or less, and "-1:35" with a tap-to-catch-up otherwise. The showcase's Live tab does exactly that.

## Quality, captions & audio tracks

### Quality (HLS)

```dart
final qualities = controller.qualities; // includes "Auto"
await controller.setQuality(qualities.firstWhere((q) => q.height == 720));

controller.qualitiesStream.listen(...);     // when the list is loaded
controller.qualityChangedStream.listen(...); // adaptive or manual switches
```

### Captions

Embedded HLS tracks and your own VTT/SRT files appear in **one list**:

<img src="https://raw.githubusercontent.com/plug-and-pay/flutter-native-video-player/master/doc/screenshots/captions_sheet.webp" width="260" alt="Caption picker with embedded and sidecar tracks">

```dart
await controller.load(
  url: 'https://example.com/video.mp4',
  sidecarSubtitles: const [
    NativeVideoPlayerSidecarSubtitle.url('https://example.com/en.vtt', language: 'en', label: 'English'),
    NativeVideoPlayerSidecarSubtitle.file('/path/to/nl.srt', language: 'nl', label: 'Nederlands'),
    NativeVideoPlayerSidecarSubtitle.content('WEBVTT\n\n00:01.000 --> 00:04.000\nHello!', language: 'x', label: 'Inline'),
  ],
);
// or later: await controller.setSidecarSubtitles([...]);

final tracks = await controller.getAvailableSubtitleTracks();
// track.source is SubtitleTrackSource.embedded or .sidecar
await controller.setSubtitleTrack(tracks.first);
await controller.setSubtitleTrack(NativeVideoPlayerSubtitleTrack.off());
```

**Sidecar captions are drawn by Flutter**, so you style and place them however you like:

```dart
NativeVideoPlayer(
  controller: controller,
  subtitleStyle: const NativeVideoPlayerSubtitleStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    textColor: Colors.white,
    backgroundColor: Colors.black54,
    outlineColor: Colors.black, outlineWidth: 2,
    alignment: Alignment.bottomCenter,
    padding: EdgeInsets.fromLTRB(24, 0, 24, 48),
    fullscreenLandscapeFontSize: 24,
  ),
)
```

**Embedded captions are drawn by the platform**, which follows the user's system caption style. You can scale them, and the scale survives quality switches:

```dart
await controller.setNativeSubtitleTextScale(1.5); // 1.0 = platform default
```

Embedded tracks show up in PiP, native fullscreen and on AirPlay receivers. On Android, URL sidecars are also attached natively so they show in PiP. On iOS, sidecars render in the app only.

### Audio tracks

Switch between languages or audio descriptions:

```dart
final tracks = await controller.getAvailableAudioTracks();
await controller.setAudioTrack(tracks.firstWhere((t) => t.language == 'de'));
```

## Playlists, A-B loops & analytics

### Playlists

Play a list back to back on one controller, with per-item resume positions:

```dart
final playlist = NativeVideoPlayerPlaylist(controller, items: [
  const NativeVideoPlayerPlaylistItem(url: 'https://example.com/lesson1.mp4'),
  NativeVideoPlayerPlaylistItem(url: 'https://example.com/lesson2.mp4', startAt: savedPosition),
], loop: false);

await playlist.start();
playlist.currentIndexStream.listen((i) => print('now playing $i'));
// playlist.next() / previous() / playItemAt(i) / hasNext / hasPrevious
playlist.dispose();
```

Items take `headers`, `drmConfig` and `sidecarSubtitles` too. Auto-advance listens for the `completed` event, so leave `setLooping` off while a playlist runs.

### A-B loop / clip range

```dart
await controller.setPlaybackRange(start: a, end: b);              // loop a section
await controller.setPlaybackRange(start: a, end: b, loop: false); // play a clip once
controller.clearPlaybackRange();
controller.playbackRange; // the active range, or null
```

Loading another video clears the range.

### Playback analytics

Quality-of-experience metrics from the events the player already sends, with no extra native traffic:

```dart
final analytics = PlaybackAnalytics(controller);
analytics.events.listen((e) => metrics.track(e.type.name, e.value));
// startup (ms) · stallStarted / stallEnded (ms) · seeked · qualityChanged
// · watchedHeartbeat (watched ms) · completed
analytics.stallCount;
analytics.watchedDuration;
analytics.dispose();
```

## Offline downloads

`VideoDownloadController` downloads files with progress and keeps an index that survives restarts. You choose the folder, so the plugin doesn't need `path_provider`:

```dart
final downloads = VideoDownloadController(directoryPath: '${docs.path}/videos');

downloads.download(id: 'lesson-42', url: 'https://example.com/video.mp4', headers: {...})
    .listen((p) => print('${p.status} ${p.fraction}')); // fraction is null without Content-Length

final path = await downloads.localPathFor('lesson-42');
if (path != null) await controller.load(url: 'file://$path'); // plays offline

await downloads.listDownloads();   // List<VideoDownload>
await downloads.isDownloaded('lesson-42');
await downloads.cancel('lesson-42');
await downloads.remove('lesson-42');
```

Downloads are written to a `.part` file and renamed once complete, so an interrupted download never looks finished. Downloading an id that is already done emits `completed` right away. Starting one that is already running returns the same stream.

## DRM

Pass a `drmConfig` to `load`:

| Platform | System | Notes |
|---|---|---|
| iOS | **FairPlay** | HLS only, needs `certificateUrl` |
| Android | **Widevine** | HLS and DASH |
| Both | **AES-128** | standard HLS encryption, no license server |
| Both | **ClearKey** | for testing |

```dart
// FairPlay (iOS)
await controller.load(url: url, drmConfig: {
  'type': 'fairplay',
  'licenseUrl': 'https://license.example.com/fairplay',
  'certificateUrl': 'https://license.example.com/fairplay.der',
  'headers': {'Authorization': 'Bearer $token'},
});

// Widevine (Android)
await controller.load(url: url, drmConfig: {
  'type': 'widevine',
  'licenseUrl': 'https://license.example.com/widevine',
  'headers': {'Authorization': 'Bearer $token'},
});

// AES-128: keys come from the playlist
await controller.load(url: url, drmConfig: {'type': 'aes-128'});

// ClearKey
await controller.load(url: url, drmConfig: {'type': 'clearKey', 'licenseUrl': '...'});
```

| Key | Used for |
|---|---|
| `type` | `'fairplay'`, `'widevine'`, `'aes-128'` or `'clearKey'` |
| `licenseUrl` | license server (not for AES-128) |
| `certificateUrl` | FairPlay certificate |
| `headers` | sent with license requests |
| `certificateEncoding` | FairPlay: `'binary'` (default) or `'base64'` |
| `licenseRequestFormat` | FairPlay: `'binary'` (default) or `'base64Form'` (`spc=<base64>`) |
| `licenseResponseEncoding` | FairPlay: `'binary'` (default) or `'base64'` |

FairPlay servers don't all speak the same wire format. DoveRunner (PallyCon), for example, uses Base64 everywhere:

```dart
drmConfig: {
  'type': 'fairplay',
  'licenseUrl': 'https://license-global.pallycon.com/ri/licenseManager.do',
  'certificateUrl': 'https://license-global.pallycon.com/ri/fpsKeyManager.do?siteId=ABCD',
  'certificateEncoding': 'base64',
  'licenseRequestFormat': 'base64Form',
  'licenseResponseEncoding': 'base64',
  'headers': {'pallycon-customdata-v2': token},
}
```

DRM errors (license denied, bad certificate, network) arrive as an activity event with `state == PlayerActivityState.error` and a `message`. Test DRM on real devices; simulators are limited.

## Feeds & performance

Set `NativeVideoPlayerConfig.global` once, before creating controllers. Every option defaults to the plain behavior.

```dart
NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
  maxConcurrentPlayingPlayers: 2,     // pause the least recently played beyond this
  qualityForViewportSize: true,       // small tiles stream small renditions
  lightweightInlineViews: true,       // bare video surfaces under custom controls
  prioritizeActivePlayback: true,     // Android: the playing tile wins the network
  androidEnableDiskCache: true,       // Android: replays come from disk
  androidTextureMode: true,           // Flutter textures: smooth scrolling, fullscreen flight
  androidBufferConfig: NativeVideoPlayerAndroidBufferConfig.feed(),
  iosBufferConfig: NativeVideoPlayerIosBufferConfig.feed(),
  bufferingTimeout: Duration(seconds: 20), // endless spinner → error you can retry
);
```

| Option | What it does |
|---|---|
| `maxConcurrentPlayingPlayers` | Cap on players playing at once. The least recently played one pauses (it's never disposed). Players in PiP or on AirPlay are exempt. |
| `qualityForViewportSize` | Caps adaptive quality to the player's on-screen size. Measured −58% memory with six players on a Galaxy S21. Lifted in fullscreen and on AirPlay, and manual `setQuality` is never capped. |
| `viewportCapHeadroom` | iOS: how much larger than the tile a rendition may be (default 1.5, visually lossless; 1.0 saves the most). |
| `lightweightInlineViews` | Views with hidden native controls use a bare `AVPlayerLayer` / `SurfaceView`: cheaper to create and scroll. PiP, AirPlay, fullscreen and Now Playing keep working. |
| `prioritizeActivePlayback` | Android: playing players load before paused ones (Media3 `PriorityTaskManager`). |
| `androidEnableDiskCache`, `androidDiskCacheMaxBytes`, `androidPrecacheBytes` | Android: an LRU disk cache (100 MB by default) that also replays offline. |
| `androidTextureMode`, `iosTextureMode` | Inline tiles render as Flutter textures, so feeds scroll like normal Flutter lists (see below). |
| `iosMaxTotalPlayers` | iOS: at most this many live AVPlayers (default 6). Idle ones are released and reload on `play()`. |
| `timeUpdateInterval` | How often position events arrive (default 500 ms). |
| `loadTimeout`, `bufferingTimeout` | Turn a stuck load (30 s) or rebuffer (off by default) into an error event you can retry. |
| `androidForceSoftwareDecoders` | Android: prefer software decoders on devices with broken hardware decoders. |
| `iosAllowsVideoFrameAnalysis` | iOS 16+: allow Live Text on paused frames. Off by default, so Apple's "select text" button doesn't appear over your controls. |
| `androidBufferConfig`, `iosBufferConfig` | Buffer sizes. `.feed()` presets start fast and buffer less. |

**Warm the cache** for the next items in a feed (Android; does nothing on iOS):

```dart
await NativeVideoPlayerCache.precache('https://example.com/next.m3u8');
```

**Texture mode** (experimental). Platform views claim drag gestures that start on a video, which kills a feed's fling momentum; textures don't. The trade-off: video frames go through Flutter's raster thread, which costs more with many large tiles on mid-range Android phones. FairPlay content and tiles with automatic PiP keep using platform views, and a manual `enterPictureInPicture()` swaps a texture tile to a platform view seamlessly. See [`PERFORMANCE_ROADMAP.md`](PERFORMANCE_ROADMAP.md) for measurements.

**Several players** each get their own `id`:

```dart
final a = NativeVideoPlayerController(id: 1);
final b = NativeVideoPlayerController(id: 2);
Column(children: [
  Expanded(child: NativeVideoPlayer(controller: a)),
  Expanded(child: NativeVideoPlayer(controller: b)),
]);
```

## Lifecycle & sharing a player between screens

A controller's `id` names a native player. **Two widgets with the same controller show the same player**: a feed tile and its detail screen keep playing without a reload or a black frame.

| You want to… | Call |
|---|---|
| close the video for good | `dispose()`: stops and destroys the native player |
| leave a screen but keep the player (it's on another screen, in PiP, or you'll come back) | `releaseResources()`: drops the Flutter side, keeps the native player |

```dart
// Feed tile → detail screen with the same controller
Navigator.push(context, MaterialPageRoute(
  builder: (_) => DetailScreen(controller: tileController),
));

// In the feed tile's dispose (the detail screen may still use it):
tileController.releaseResources();
```

When the feed shows the tile again, `NativeVideoPlayer(controller: tileController)` reattaches the native surface. With automatic PiP and a shared controller, the most recently shown view gets the PiP window.

**On iOS**, `capturePosterFrame()` / `posterFrame` give a JPEG of the frame on screen, for a still while you navigate.

## Events & state

Read the state directly:

```dart
controller.activityState;   // playing, paused, buffering, …
controller.currentPosition; controller.duration; controller.bufferedPosition;
controller.speed; controller.volume; controller.isFullScreen;
controller.isPipEnabled; controller.isLive; controller.qualities; controller.url;
```

Listen to just what you need:

```dart
controller.positionStream;          controller.durationStream;
controller.bufferedPositionStream;  controller.playerStateStream;
controller.speedStream;             controller.isFullscreenStream;
controller.isPipEnabledStream;      controller.isPipAvailableStream;
controller.isLiveStream;            controller.videoSizeStream;
controller.qualitiesStream;         controller.qualityChangedStream;
controller.isAirplayAvailableStream; controller.isAirplayConnectedStream;
```

Or get every event in two groups:

```dart
controller.addActivityListener((event) {
  // playback: idle, initializing, initialized, loading, loaded,
  //           playing, paused, buffering, completed, stopped, error
  if (event.state == PlayerActivityState.error) print(event.data?['message']);
});
controller.addControlListener((event) {
  // everything else: timeUpdated, seeked, qualityChanged, speedChanged,
  // pipStarted/Stopped, fullscreenEntered/Exited, airPlayConnected/Disconnected,
  // subtitleTrackChanged, audioTrackChanged, …
});
```

The activity state means the same on iOS and Android. `loaded` is a video that hasn't started: it stays until the first play or seek, or the next load. `completed` stays until it plays again, is seeked (it then ends `paused`) or another video loads. The pauses and buffering blips the native players report on their own in between (the first buffer filling, the rewind after the end) don't reach the state or activity listeners.

Remove listeners with `removeActivityListener` / `removeControlListener` before you dispose.

## API reference

### `NativeVideoPlayerController(...)`

| Parameter | Default | |
|---|---|---|
| `id` | required | names the native player; same id = same player |
| `autoPlay` | `false` | play as soon as it's loaded |
| `enableLooping` | `false` | seamless loop |
| `mixWithOthers` | `false` | don't interrupt other apps' audio (muted tiles, background loops) |
| `mediaInfo` | — | title / artwork for the lock screen |
| `showNativeControls` | `true` | platform controls when there's no overlay (`setShowNativeControls` changes it) |
| `allowsPictureInPicture` | `true` | |
| `canStartPictureInPictureAutomatically` | `true` | PiP when the app goes to the background |
| `lockToLandscape` | `true` | fullscreen forces landscape |
| `preferredOrientations` | — | orientations restored after fullscreen |
| `preventFullscreenSwipeDismiss` | `true` | iOS native fullscreen closes with Done only |
| `fullscreenFlightBorderRadius` | square | corners the fullscreen flight starts and ends with |
| `enableHDR` | `true` | turn off if HDR content looks washed out |

### `NativeVideoPlayer(...)`

| Parameter | |
|---|---|
| `controller` | required |
| `overlayBuilder` | your controls |
| `overlayFadeDuration` | fade of the overlay (300 ms) |
| `poster` | `NativeVideoPlayerPoster` |
| `subtitleStyle` | style for sidecar captions |

### Helpers

| Class | Purpose |
|---|---|
| `NativeVideoPlayerConfig` | global tuning for feeds and devices |
| `NativeVideoPlayerPoster` | thumbnail, preview animation, badge |
| `StoryboardThumbnails` | scrub previews from VTT, sprite grids or Bunny Stream |
| `NativeVideoPlayerProgressBar` | seek bar with chapters, snapping and scrub preview |
| `NativeVideoPlayerChapters` | chapter parsing (description text, WebVTT) and seek-bar math |
| `NativeVideoPlayerPlaylist` | sequential playback with auto-advance |
| `PositionCheckpoints` | throttled resume positions |
| `PlaybackAnalytics` | startup, stalls, watched time, completion |
| `BackgroundPlaybackGuard` | pause in the background |
| `VideoDownloadController` | offline downloads |
| `NativeVideoPlayerCache` | Android precache |
| `AirPlayStateManager` | app-wide AirPlay detection |
| `FullscreenManager` | fullscreen orientation helpers |
| `cast.CastDeviceDiscovery`, `cast.CastSession` | Chromecast (from `package:better_native_video_player/cast.dart`) |

### Companion package: Vimeo & YouTube without WebViews

[`packages/better_native_video_extractor`](packages/better_native_video_extractor) resolves Vimeo (and YouTube) links to playable HLS/MP4 URLs, thumbnails, durations and storyboards over plain HTTP. It supports domain-locked Vimeo videos (Referer) and caches results until they expire:

```dart
final cache = VideoExtractionCache(VimeoExtractor(referer: 'https://yourdomain.com'));
final video = await cache.extract('https://vimeo.com/76979871');
await controller.load(url: video.playbackUrl!);
```

## Troubleshooting

<details>
<summary><b>Nothing plays / events don't arrive</b></summary>

- Call `initialize()` before `load()`. It waits until the native view exists.
- Give every simultaneous player its own `id`.
- Errors arrive as an activity event with `PlayerActivityState.error` and a `message`.
- Known-good test streams: `https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8` (HLS) and `https://media.w3.org/2010/05/sintel/trailer.mp4` (MP4).
</details>

<details>
<summary><b>iOS: PiP, background audio or AirPlay doesn't work</b></summary>

- `UIBackgroundModes` needs both `audio` and `picture-in-picture`.
- Automatic PiP needs iOS 14.2+ and a playing video.
- Some simulators don't support PiP; test on a device.
- For Now Playing, pass `mediaInfo`.
</details>

<details>
<summary><b>iOS: a "select text" button appears on a paused video</b></summary>

That's Live Text. It's off by default; check that `iosAllowsVideoFrameAnalysis` isn't `true` and that the config is set before the controller is created.
</details>

<details>
<summary><b>Android: PiP doesn't start</b></summary>

Android PiP works from Dart fullscreen: use an `overlayBuilder`, enter fullscreen, then PiP (or press home with `canStartPictureInPictureAutomatically`). Requires Android 8.0+.
</details>

<details>
<summary><b>Android: fullscreen doesn't fly, it fades</b></summary>

The flight needs `androidTextureMode: true`. With platform views it falls back to a fade.
</details>

<details>
<summary><b>Music from other apps stops</b></summary>

Starting a video interrupts other audio, as every video app does. Pausing gives it back: the audio session is only active while a video plays, is in PiP or is on AirPlay.
</details>

<details>
<summary><b>Chromecast finds nothing</b></summary>

Phone and Chromecast must be on the same network. On iOS, add `NSLocalNetworkUsageDescription` and `NSBonjourServices` and allow the Local Network prompt. `CastDiscoveryException.message` says what's wrong.
</details>

## Example app

[`example/lib/main.dart`](example/lib/main.dart) is the showcase above: one file, four tabs.

- **Watch** — a poster with a preview animation, custom controls, scrub previews, quality, captions, audio, speed, A-B loop, PiP, AirPlay, Chromecast, analytics
- **Live** — live HLS with a DVR scrubber and jump-to-live
- **Feed** — a tuned feed with posters, duration badges and offline downloads
- **Binge** — a playlist with resume positions

```bash
cd example
flutter run
```

`example/lib/dev_main.dart` is the harness the plugin is developed against: stress feeds, PiP and AirPlay repro screens (`flutter run -t lib/dev_main.dart`).

## Contributing

Issues and pull requests are welcome on [GitHub](https://github.com/plug-and-pay/flutter-native-video-player).

## License & credits

MIT — see [LICENSE](LICENSE).

Built on AVFoundation (iOS) and ExoPlayer / Media3 (Android). Showcase videos: *Big Buck Bunny*, *Sintel* and *Tears of Steel* © Blender Foundation, [CC BY](https://creativecommons.org/licenses/by/3.0/).

# better_native_video_player

[![pub package](https://img.shields.io/pub/v/better_native_video_player.svg)](https://pub.dev/packages/better_native_video_player)

A Flutter plugin for native video playback on iOS and Android with advanced features.

## Features

- ✅ Native video players: **AVPlayerViewController** on iOS and **ExoPlayer (Media3)** on Android
- ✅ **Multiple video formats**: HLS streams (.m3u8), MP4, and other common formats
- ✅ **Local file support**: Play videos from device storage using file:// URIs
- ✅ **Asset video support**: Play videos bundled in Flutter assets
- ✅ **HLS streaming** support with adaptive quality selection
- ✅ **Video looping**: Smooth native video looping without stuttering
- ✅ **Picture-in-Picture (PiP)** mode on both platforms with automatic state management
- ✅ **AirPlay** support on iOS with availability detection and connection events
- ✅ Native **fullscreen** playback with Dart-side fullscreen option
- ✅ **Custom overlay controls** - Build your own UI on top of native player
- ✅ **Now Playing** integration (Control Center on iOS, lock screen notifications on Android)
- ✅ Background playback with media notifications
- ✅ Playback controls: play, pause, seek, volume, speed (0.25x - 2.0x)
- ✅ Quality selection for HLS streams with real-time switching
- ✅ **Subtitle/Closed Caption support** for HLS streams (VOD and Live) with language selection
- ✅ **Separated event streams**: Activity events (play/pause/buffering) and Control events (quality/speed/PiP/fullscreen)
- ✅ **Individual property streams**: Dedicated streams for position, duration, speed, state, fullscreen, PiP, AirPlay, and quality
- ✅ Real-time playback position tracking with **buffered position indicator**
- ✅ Custom HTTP headers support for video requests
- ✅ **DRM (Digital Rights Management) support** for protected content (FairPlay on iOS, Widevine on Android, AES-128, ClearKey)
- ✅ Multiple controller instances support with shared player management
- ✅ **WASM compatible** - Package works with Web Assembly runtime

## Platform Support

| Platform | Minimum Version |
|----------|----------------|
| iOS      | 12.0+          |
| Android  | API 24+ (Android 7.0) |

## Supported Video Formats

The plugin supports various video formats through native platform players:

### Remote URLs
- **HLS Streams (.m3u8)**: Adaptive streaming with quality selection
- **MP4 Videos**: Direct MP4 video URLs
- **Other formats**: Any format supported by the native player (MP4, MOV, M4V on iOS; MP4, WebM, MKV on Android)

### Local Files
- **Device Storage**: Videos stored on device using `file://` URIs
- **App Bundle**: Videos bundled with your app (iOS: via `NSBundle`, Android: via assets or external storage)

### Examples

#### Remote Videos
```dart
// HLS stream with quality selection
await controller.loadUrl(url: 'https://example.com/video.m3u8');

// MP4 video
await controller.loadUrl(url: 'https://example.com/video.mp4');

// With custom headers
await controller.loadUrl(
  url: 'https://example.com/video.mp4',
  headers: {'Referer': 'https://example.com'},
);
```

#### Local Files
```dart
// Android - Load from external storage
await controller.loadFile(path: '/storage/emulated/0/DCIM/video.mp4');

// iOS - Load from app documents
await controller.loadFile(path: '/var/mobile/Media/DCIM/100APPLE/video.MOV');

// Using path_provider
import 'package:path_provider/path_provider.dart';

final directory = await getApplicationDocumentsDirectory();
await controller.loadFile(path: '${directory.path}/my_video.mp4');
```

#### Generic Method (Backward Compatible)
```dart
// The generic load() method also works with both URLs and file:// URIs
await controller.load(url: 'https://example.com/video.m3u8');
await controller.load(url: 'file:///path/to/video.mp4');
```

**Note**: Quality selection and adaptive streaming are only available for HLS streams. Other formats play at their native quality.

## DRM Support

The plugin supports Digital Rights Management (DRM) for protected content playback on both iOS and Android platforms.

### Supported DRM Types

| Platform | DRM Type | Description |
|----------|----------|-------------|
| iOS | **FairPlay Streaming** | Apple's DRM solution for HLS content |
| iOS | **AES-128** | Standard HLS encryption (no license server required) |
| Android | **Widevine** | Google's DRM solution for protected content |
| Android | **AES-128** | Standard HLS encryption (no license server required) |
| Both | **ClearKey** | Unencrypted key system for testing and development |

### DRM Configuration

DRM is configured via the `drmConfig` parameter in the `load()`, `loadUrl()`, and `loadFile()` methods:

```dart
await controller.loadUrl(
  url: 'https://example.com/protected-stream.m3u8',
  drmConfig: {
    'type': 'fairplay', // or 'widevine', 'aes-128', 'clearKey'
    'licenseUrl': 'https://license.server.com/get',
    'certificateUrl': 'https://cert.server.com/cert.der', // iOS FairPlay only
    'headers': {
      'Authorization': 'Bearer <token>',
      'X-Custom-Header': 'value',
    },
  },
);
```

### DRM Configuration Parameters

| Parameter | Type | Required | Platform | Description |
|-----------|------|----------|----------|-------------|
| `type` | `String` | Yes | Both | DRM type: `'fairplay'`, `'widevine'`, `'aes-128'`, or `'clearKey'` |
| `licenseUrl` | `String` | Yes* | Both | License server URL for key requests (*not required for AES-128) |
| `certificateUrl` | `String` | Yes (FairPlay) | iOS | Certificate URL for FairPlay DRM |
| `headers` | `Map<String, String>` | No | Both | HTTP headers for license requests (authentication, etc.) |

### Platform-Specific Examples

#### iOS - FairPlay Streaming

```dart
await controller.loadUrl(
  url: 'https://example.com/fairplay-stream.m3u8',
  drmConfig: {
    'type': 'fairplay',
    'licenseUrl': 'https://license.server.com/fairplay',
    'certificateUrl': 'https://cert.server.com/fairplay.der',
    'headers': {
      'Authorization': 'Bearer your-token-here',
    },
  },
);
```

**FairPlay Requirements:**
- Certificate URL must be provided
- Certificate is automatically fetched and used for license requests
- License server must implement FairPlay Streaming protocol
- Works with HLS streams only

#### Android - Widevine

```dart
await controller.loadUrl(
  url: 'https://example.com/widevine-stream.m3u8',
  drmConfig: {
    'type': 'widevine',
    'licenseUrl': 'https://license.server.com/widevine',
    'headers': {
      'Authorization': 'Bearer your-token-here',
      'Content-Type': 'application/octet-stream',
    },
  },
);
```

**Widevine Requirements:**
- License server URL is required
- License server must implement Widevine protocol
- Supports both HLS and DASH streams
- Works with ExoPlayer's DRM framework

#### AES-128 (Standard HLS Encryption)

AES-128 is standard HLS encryption that doesn't require a license server. The encryption keys are embedded in the HLS manifest:

```dart
await controller.loadUrl(
  url: 'https://example.com/aes128-stream.m3u8',
  drmConfig: {
    'type': 'aes-128',
    // No licenseUrl or certificateUrl needed
    // Keys are automatically extracted from the HLS manifest
  },
);
```

**AES-128 Notes:**
- No license server required
- Keys are automatically extracted from the HLS manifest
- Works on both iOS and Android
- Most common encryption for HLS streams

#### ClearKey (Testing/Development)

ClearKey is an unencrypted key system useful for testing and development:

```dart
await controller.loadUrl(
  url: 'https://example.com/clearkey-stream.m3u8',
  drmConfig: {
    'type': 'clearKey',
    'licenseUrl': 'https://license.server.com/clearkey',
  },
);
```

**ClearKey Notes:**
- Primarily for testing and development
- Not recommended for production use
- Useful for debugging DRM integration

### DRM Best Practices

1. **Secure License Requests**: Always use HTTPS for license URLs and include authentication headers
2. **Error Handling**: Implement proper error handling for DRM failures (license denied, network errors, etc.)
3. **Certificate Management**: For FairPlay, ensure your certificate URL is accessible and returns valid DER-encoded certificates
4. **Testing**: Test DRM playback on physical devices (simulators may have limitations)
5. **Platform Differences**: Be aware that FairPlay (iOS) and Widevine (Android) have different license request formats

### DRM Error Handling

DRM errors are reported through the standard player event system:

```dart
_controller.addActivityListener((event) {
  if (event.state == PlayerActivityState.error) {
    final errorMessage = event.data?['message'] as String?;
    print('DRM Error: $errorMessage');
    // Handle DRM-specific errors
  }
});
```

Common DRM errors:
- License server unavailable
- Invalid certificate (FairPlay)
- License denied by server
- Network errors during license request
- Unsupported DRM type for platform

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  better_native_video_player: ^0.3.7
```

Then run:

```bash
flutter pub get
```

### iOS Setup

This plugin supports both **CocoaPods** and **Swift Package Manager (SPM)**. Flutter will automatically use the appropriate dependency manager based on your project configuration.

Add the following to your `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>

<!-- For background audio/video playback and Picture-in-Picture -->
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

**For Picture-in-Picture support**, you can either:

**Option 1: Manual Info.plist configuration** (as shown above)
- Add both `audio` and `picture-in-picture` to `UIBackgroundModes`

**Option 2: Xcode Capabilities interface**
- Target → Signing & Capabilities → "+ Capability" → Background Modes
- Check "Audio, AirPlay, and Picture in Picture"
- This will automatically add both `audio` and `picture-in-picture` to your Info.plist

**Note:** Both `audio` and `picture-in-picture` capabilities are required for:
- Automatic Picture-in-Picture when app goes to background (iOS 14.2+)
- Background audio playback
- AirPlay functionality

### Android Setup

The plugin automatically configures the required permissions and services in its manifest.

**For Picture-in-Picture support**, Android PiP is handled by the [floating package](https://pub.dev/packages/floating). The integration is automatic - no additional setup required! The floating package provides:
- Automatic PiP when the home button is pressed (if `canStartPictureInPictureAutomatically` is enabled)
- Manual PiP entry via `controller.enterPictureInPicture()`
- Only the video surface is shown in PiP mode (all overlays are hidden)

**Important**: On Android, PiP (both manual and automatic) is **only available when the video is in Dart fullscreen mode** (i.e., when using custom overlay controls with `overlayBuilder`). This ensures only the video player is captured in PiP, not the surrounding app UI.

**Note**: PiP requires Android 8.0+ (API 26+) and `android:supportsPictureInPicture="true"` in your Activity manifest (already included by the plugin).

## Usage

### Basic Example

```dart
import 'package:flutter/material.dart';
import 'package:better_native_video_player/better_native_video_player.dart';

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late NativeVideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    // Create controller
    _controller = NativeVideoPlayerController(
      id: 1,
      autoPlay: true,
      showNativeControls: true,
    );

    // Listen to events
    _controller.addListener(_handlePlayerEvent);

    // Initialize
    await _controller.initialize();

    // Load video - Multiple options:

    // Option 1: Load remote URL (HLS stream)
    await _controller.loadUrl(
      url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    );

    // Option 2: Load remote URL (MP4 video)
    // await _controller.loadUrl(
    //   url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
    // );

    // Option 3: Load local file from device storage
    // await _controller.loadFile(
    //   path: '/storage/emulated/0/DCIM/video.mp4',
    // );

    // Option 4: Generic load method (also supported)
    // await _controller.load(
    //   url: 'https://example.com/video.m3u8',
    // );

    // Option 5: Load with DRM (protected content)
    // await _controller.loadUrl(
    //   url: 'https://example.com/protected-stream.m3u8',
    //   drmConfig: {
    //     'type': 'fairplay', // or 'widevine' for Android
    //     'licenseUrl': 'https://license.server.com/get',
    //     'certificateUrl': 'https://cert.server.com/cert.der', // iOS FairPlay only
    //     'headers': {
    //       'Authorization': 'Bearer <token>',
    //     },
    //   },
    // );
  }

  void _handlePlayerEvent(NativeVideoPlayerEvent event) {
    print('Player event: ${event.type}');
  }

  @override
  void dispose() {
    _controller.removeListener(_handlePlayerEvent);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: NativeVideoPlayer(controller: _controller),
    );
  }
}
```

### Advanced Usage

#### Custom Media Info (Now Playing)

```dart
_controller = NativeVideoPlayerController(
  id: 1,
  mediaInfo: const NativeVideoPlayerMediaInfo(
    title: 'My Video Title',
    subtitle: 'Artist or Channel Name',
    album: 'Album Name',
    artworkUrl: 'https://example.com/artwork.jpg',
  ),
);
```

#### Picture-in-Picture Configuration

**Note**: On Android, PiP requires the video to be in Dart fullscreen mode (using custom overlay controls). On iOS, PiP works in both normal and fullscreen modes.

```dart
_controller = NativeVideoPlayerController(
  id: 1,
  allowsPictureInPicture: true,
  canStartPictureInPictureAutomatically: true, // iOS 14.2+, Android 8.0+ (when in fullscreen)
);
```

#### Playback Controls

```dart
// Play/Pause
await _controller.play();
await _controller.pause();

// Seek
await _controller.seekTo(const Duration(seconds: 30));

// Volume (0.0 to 1.0)
await _controller.setVolume(0.8);

// Speed
await _controller.setSpeed(1.5); // 0.5x, 1.0x, 1.5x, 2.0x, etc.

// Fullscreen
await _controller.enterFullScreen();
await _controller.exitFullScreen();
await _controller.toggleFullScreen();
```

#### Video Looping

The plugin supports smooth native video looping on both iOS and Android:

```dart
// Enable looping at controller creation
_controller = NativeVideoPlayerController(
  id: 1,
  enableLooping: true,
);

// Or enable/disable looping dynamically during playback
await _controller.setLooping(true);  // Enable looping
await _controller.setLooping(false); // Disable looping
```

**Features:**
- Seamless looping without visible pause or stuttering
- Native implementation for optimal performance (ExoPlayer's REPEAT_MODE_ONE on Android, automatic replay on iOS)
- Can be configured at controller creation or changed dynamically during playback
- Works with all supported video formats (HLS, MP4, local files, etc.)

#### Lifecycle Management

The plugin provides two methods for managing player lifecycle:

##### dispose() - Complete Cleanup

Fully disposes of all resources including the native player. Use this when the video player is no longer needed and will not be reused.

```dart
@override
void dispose() {
  // Remove all listeners
  _controller.removeActivityListener(_handleActivityEvent);
  _controller.removeControlListener(_handleControlEvent);
  
  // Fully dispose the controller
  _controller.dispose();
  super.dispose();
}
```

**What dispose() does:**
- Pauses playback and exits fullscreen
- Cancels all event channel subscriptions
- Clears all event handlers and listeners
- Releases Flutter resources (platform view contexts, overlay builders)
- **Destroys the native player** (calls platform's dispose method)
- Clears player state and URL
- Removes player from shared player manager

##### releaseResources() - Temporary Cleanup

Releases Flutter resources but keeps the native player alive. Useful when you need to temporarily clean up Flutter-side resources while keeping the native player running (e.g., when navigating away from a screen but want to keep the player alive for later).

```dart
@override
void dispose() {
  // Release Flutter resources but keep native player alive
  _controller.releaseResources();
  super.dispose();
}
```

**What releaseResources() does:**
- Pauses playback and exits fullscreen
- Cancels all event channel subscriptions
- Clears all event handlers and listeners
- Releases Flutter resources (platform view contexts, overlay builders)
- **Keeps the native player alive** for potential reuse

**When to use each method:**

| Scenario | Method | Reason |
|----------|--------|--------|
| Leaving the app or closing video permanently | `dispose()` | Completely frees all resources including native player |
| Navigating between screens with same controller ID | `releaseResources()` | Keeps native player alive for shared player scenarios |
| Temporarily hiding video player | `releaseResources()` | Player can be quickly resumed without reloading video |
| App shutdown or logout | `dispose()` | Ensures complete cleanup |

**Example: Shared player across screens**

```dart
// List screen with thumbnail/preview
class VideoListScreen extends StatefulWidget {
  @override
  State<VideoListScreen> createState() => _VideoListScreenState();
}

class _VideoListScreenState extends State<VideoListScreen> {
  late NativeVideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    // Use a stable controller ID for sharing
    _controller = NativeVideoPlayerController(id: 100, autoPlay: false);
    _controller.initialize();
    _controller.load(url: 'https://example.com/video.m3u8');
  }

  @override
  void dispose() {
    // Release Flutter resources but keep native player for detail screen
    _controller.releaseResources();
    super.dispose();
  }

  Widget build(BuildContext context) {
    return ListTile(
      onTap: () {
        // Navigate to detail screen with same controller ID
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VideoDetailScreen(controllerId: 100),
          ),
        );
      },
      // ... list item content
    );
  }
}

// Detail screen reuses the same controller
class VideoDetailScreen extends StatefulWidget {
  final int controllerId;
  
  const VideoDetailScreen({required this.controllerId, super.key});

  @override
  State<VideoDetailScreen> createState() => _VideoDetailScreenState();
}

class _VideoDetailScreenState extends State<VideoDetailScreen> {
  late NativeVideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    // Reuse the same controller ID - native player is still alive!
    _controller = NativeVideoPlayerController(
      id: widget.controllerId,
      autoPlay: true,
    );
    _controller.initialize();
  }

  @override
  void dispose() {
    // Fully dispose when leaving detail screen permanently
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: NativeVideoPlayer(controller: _controller),
    );
  }
}
```

#### Quality Selection (HLS)

```dart
// Get available qualities
final qualities = _controller.qualities;

// Set quality
if (qualities.isNotEmpty) {
  await _controller.setQuality(qualities.first);
}
```

#### Subtitle/Closed Caption Support

The plugin supports subtitles and closed captions for HLS streams (both VOD and Live). Subtitles must be embedded in the HLS stream manifest as text tracks.

**Get Available Subtitle Tracks:**
```dart
// Get all available subtitle tracks
final subtitles = await _controller.getAvailableSubtitleTracks();

// Check available languages
for (final track in subtitles) {
  print('${track.displayName} (${track.language}) - Selected: ${track.isSelected}');
}
```

**Select a Subtitle Track:**
```dart
// Select a subtitle track by passing the track object
if (subtitles.isNotEmpty) {
  await _controller.setSubtitleTrack(subtitles.first);
}

// Disable subtitles
await _controller.setSubtitleTrack(NativeVideoPlayerSubtitleTrack.off());
```

**Using the Subtitle Picker Modal:**

A ready-to-use subtitle picker modal is included in the example app with the following features:
- Display all available subtitle tracks
- Enable/disable subtitles
- Font size control (12-32px)
- Beautiful Material Design UI

```dart
import 'package:better_native_video_player/better_native_video_player.dart';

// Show the subtitle picker modal
showSubtitlePicker(
  context: context,
  controller: _controller,
  fontSize: 16.0, // Initial font size
  onFontSizeChanged: (newSize) {
    // Handle font size changes
    setState(() {
      _subtitleFontSize = newSize;
    });
  },
);
```

**Example HLS Streams with Subtitles:**
```dart
// Apple's example stream with multiple subtitle languages
await _controller.load(
  url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
);

// After loading, get available subtitles
final subtitles = await _controller.getAvailableSubtitleTracks();
```

**Important Notes:**
- Subtitles must be embedded in the HLS stream (in the master.m3u8 manifest)
- External subtitle files (SRT, VTT) are not currently supported
- Subtitle tracks are automatically detected from the stream
- Both VOD (Video on Demand) and Live streams are supported
- Font rendering and styling are handled by the native players (AVPlayer on iOS, ExoPlayer on Android)

**Platform-Specific Behavior:**
- **iOS**: Uses AVFoundation's `AVMediaSelectionGroup` for subtitle track management
- **Android**: Uses ExoPlayer's text track selection API
- Both platforms support WebVTT and other standard subtitle formats embedded in HLS streams

See the `subtitle_example_screen.dart` in the example app for a complete implementation including a subtitle picker modal with font size controls.

#### Separated Event Handling

The plugin separates events into two categories for better control:

**Activity Events** - Playback state changes:
```dart
@override
void initState() {
  super.initState();
  _controller.addActivityListener(_handleActivityEvent);
  _controller.addControlListener(_handleControlEvent);
}

void _handleActivityEvent(PlayerActivityEvent event) {
  switch (event.state) {
    case PlayerActivityState.playing:
      print('Playing');
      break;
    case PlayerActivityState.paused:
      print('Paused');
      break;
    case PlayerActivityState.buffering:
      final buffered = event.data?['buffered'] as int?;
      print('Buffering... buffered position: $buffered ms');
      break;
    case PlayerActivityState.completed:
      print('Playback completed');
      break;
    case PlayerActivityState.error:
      print('Error: ${event.data?['message']}');
      break;
    default:
      break;
  }
}
```

**Control Events** - User interactions and settings:
```dart
void _handleControlEvent(PlayerControlEvent event) {
  switch (event.state) {
    case PlayerControlState.timeUpdated:
      final position = event.data?['position'] as int?;
      final duration = event.data?['duration'] as int?;
      final bufferedPosition = event.data?['bufferedPosition'] as int?;
      print('Position: $position ms / $duration ms (buffered: $bufferedPosition ms)');
      break;
    case PlayerControlState.qualityChanged:
      final quality = event.data?['quality'];
      print('Quality changed: $quality');
      break;
    case PlayerControlState.pipStarted:
      print('PiP mode started');
      break;
    case PlayerControlState.pipStopped:
      print('PiP mode stopped');
      break;
    case PlayerControlState.fullscreenEntered:
      print('Entered fullscreen');
      break;
    case PlayerControlState.fullscreenExited:
      print('Exited fullscreen');
      break;
    default:
      break;
  }
}

@override
void dispose() {
  _controller.removeActivityListener(_handleActivityEvent);
  _controller.removeControlListener(_handleControlEvent);
  _controller.dispose();
  super.dispose();
}
```

#### Individual Property Streams

For convenience, the controller also provides dedicated streams for individual properties. These are useful when you only need to listen to specific changes:

```dart
@override
void initState() {
  super.initState();

  // Listen to position changes
  _controller.positionStream.listen((position) {
    print('Position: ${position.inSeconds}s');
  });

  // Listen to player state changes
  _controller.playerStateStream.listen((state) {
    if (state == PlayerActivityState.playing) {
      print('Video is playing');
    }
  });

  // Listen to fullscreen state changes
  _controller.isFullscreenStream.listen((isFullscreen) {
    print('Fullscreen: $isFullscreen');
  });

  // Listen to PiP state changes
  _controller.isPipEnabledStream.listen((isPipEnabled) {
    print('PiP enabled: $isPipEnabled');
  });

  // Listen to speed changes
  _controller.speedStream.listen((speed) {
    print('Playback speed: ${speed}x');
  });

  // Listen to quality changes
  _controller.qualityChangedStream.listen((quality) {
    print('Quality: ${quality.name}');
  });
}
```

**Available streams:**
- `bufferedPositionStream` - Stream of buffered position changes
- `durationStream` - Stream of duration changes
- `playerStateStream` - Stream of player state changes (playing, paused, buffering, etc.)
- `positionStream` - Stream of playback position changes
- `speedStream` - Stream of playback speed changes
- `isPipEnabledStream` - Stream of Picture-in-Picture state changes
- `isPipAvailableStream` - Stream of Picture-in-Picture availability changes
- `isAirplayAvailableStream` - Stream of AirPlay availability changes
- `isAirplayConnectedStream` - Stream of AirPlay connection state changes
- `isFullscreenStream` - Stream of fullscreen state changes
- `qualityChangedStream` - Stream of quality changes (emits when user selects a quality)
- `qualitiesStream` - Stream of available qualities list changes (emits when quality list is loaded/updated)

**Note:** The original event listeners (`addActivityListener`, `addControlListener`) are still available and continue to work as before. Use whichever approach best fits your use case.

#### Custom HTTP Headers

```dart
await _controller.load(
  url: 'https://example.com/video.m3u8',
  headers: {
    'Referer': 'https://example.com',
    'Authorization': 'Bearer token',
  },
);
```

#### Picture-in-Picture Mode

**Note**: On Android, PiP is only available when the video is in Dart fullscreen mode (using custom overlay controls). On iOS, PiP works in both normal and fullscreen modes.

```dart
// Check if PiP is available on the device
final isPipAvailable = await _controller.isPictureInPictureAvailable();

if (isPipAvailable) {
  // Enter PiP mode
  // On Android: Requires video to be in fullscreen first
  await _controller.enterPictureInPicture();

  // Exit PiP mode
  await _controller.exitPictureInPicture();

  // Or toggle PiP mode
  await _controller.togglePictureInPicture();
}

// Listen for PiP state changes using the event listener
_controller.addControlListener((event) {
  if (event.state == PlayerControlState.pipStarted) {
    print('Entered PiP mode');
  } else if (event.state == PlayerControlState.pipStopped) {
    print('Exited PiP mode');
  }
});

// Or listen using the dedicated stream
_controller.isPipEnabledStream.listen((isPipEnabled) {
  print('PiP enabled: $isPipEnabled');
});
```

#### AirPlay (iOS Only)

AirPlay allows streaming video to Apple TV, HomePod, and other AirPlay-enabled devices.

**Global AirPlay Detection:**

The plugin now uses global AirPlay device detection that works across your entire app. Initialize AirPlay detection once at app startup:

```dart
// In your app initialization (e.g., main.dart or app startup)
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Create at least one controller first (required for initialization)
  final controller = NativeVideoPlayerController(id: 1);
  await controller.initialize();
  
  // Initialize global AirPlay detection
  await AirPlayStateManager.instance.init();
  
  runApp(MyApp());
}
```

**Using AirPlay in your app:**

```dart
@override
void initState() {
  super.initState();

  // Listen for AirPlay availability changes
  _controller.addAirPlayAvailabilityListener(_handleAirPlayAvailability);

  // Listen for AirPlay connection state
  _controller.addAirPlayConnectionListener(_handleAirPlayConnection);
}

void _handleAirPlayAvailability(bool isAvailable) {
  print('AirPlay devices available: $isAvailable');
  // Show/hide AirPlay button in your UI
}

void _handleAirPlayConnection(bool isConnected) {
  print('Connected to AirPlay: $isConnected');
  // Update UI to show AirPlay is active
}

// Check if AirPlay is available
final isAvailable = await _controller.isAirPlayAvailable();

// Show AirPlay device picker
if (isAvailable) {
  await _controller.showAirPlayPicker();
}

@override
void dispose() {
  _controller.removeAirPlayAvailabilityListener(_handleAirPlayAvailability);
  _controller.removeAirPlayConnectionListener(_handleAirPlayConnection);
  _controller.dispose();
  super.dispose();
}
```

**Benefits of Global Detection:**
- AirPlay device availability is monitored once for the entire app (more efficient)
- All video player controllers automatically receive AirPlay availability updates
- Detection starts immediately at app launch for faster device discovery
- Centralized management reduces resource usage and improves battery life

#### Custom Overlay Controls

Build your own video controls UI on top of the native player:

```dart
NativeVideoPlayer(
  controller: _controller,
  overlayBuilder: (context, controller) {
    return CustomVideoOverlay(controller: controller);
  },
)
```

Create a custom overlay widget:

```dart
class CustomVideoOverlay extends StatefulWidget {
  final NativeVideoPlayerController controller;

  const CustomVideoOverlay({required this.controller, super.key});

  @override
  State<CustomVideoOverlay> createState() => _CustomVideoOverlayState();
}

class _CustomVideoOverlayState extends State<CustomVideoOverlay> {
  Duration _currentPosition = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  PlayerActivityState _activityState = PlayerActivityState.idle;

  @override
  void initState() {
    super.initState();
    widget.controller.addActivityListener(_handleActivityEvent);
    widget.controller.addControlListener(_handleControlEvent);

    // Get initial state
    _currentPosition = widget.controller.currentPosition;
    _duration = widget.controller.duration;
    _bufferedPosition = widget.controller.bufferedPosition;
    _activityState = widget.controller.activityState;
  }

  void _handleActivityEvent(PlayerActivityEvent event) {
    if (!mounted) return;
    setState(() {
      _activityState = event.state;
    });
  }

  void _handleControlEvent(PlayerControlEvent event) {
    if (!mounted) return;

    if (event.state == PlayerControlState.timeUpdated) {
      setState(() {
        _currentPosition = widget.controller.currentPosition;
        _duration = widget.controller.duration;
        _bufferedPosition = widget.controller.bufferedPosition;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Center play/pause button
        Center(
          child: IconButton(
            icon: Icon(
              _activityState.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 48,
            ),
            onPressed: () {
              if (_activityState.isPlaying) {
                widget.controller.pause();
              } else {
                widget.controller.play();
              }
            },
          ),
        ),

        // Progress bar with buffered indicator
        Positioned(
          bottom: 20,
          left: 20,
          right: 20,
          child: Slider(
            value: _currentPosition.inMilliseconds.toDouble(),
            min: 0,
            max: _duration.inMilliseconds.toDouble(),
            // Shows buffered position
            secondaryTrackValue: _bufferedPosition.inMilliseconds.toDouble(),
            onChanged: (value) {
              widget.controller.seekTo(Duration(milliseconds: value.toInt()));
            },
          ),
        ),

        // Fullscreen button
        Positioned(
          top: 20,
          right: 20,
          child: IconButton(
            icon: Icon(
              widget.controller.isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
              color: Colors.white,
            ),
            onPressed: () {
              widget.controller.toggleFullScreen();
            },
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    widget.controller.removeActivityListener(_handleActivityEvent);
    widget.controller.removeControlListener(_handleControlEvent);
    super.dispose();
  }
}
```

Features you can add to custom overlays:
- **Playback controls**: Play, pause, skip forward/backward
- **Progress bar**: Current position with buffered position indicator
- **Speed controls**: 0.25x, 0.5x, 0.75x, 1.0x, 1.25x, 1.5x, 1.75x, 2.0x
- **Quality selector**: Switch between HLS quality variants
- **Fullscreen toggle**: Enter/exit fullscreen
- **Volume control**: Adjust playback volume
- **AirPlay button**: Show AirPlay picker (iOS only)
- **Auto-hide**: Fade out controls after inactivity
- **Loading indicators**: Show when buffering

See `example/lib/widgets/custom_video_overlay.dart` for a complete implementation.

#### Multiple Video Players

```dart
class MultiPlayerScreen extends StatefulWidget {
  @override
  State<MultiPlayerScreen> createState() => _MultiPlayerScreenState();
}

class _MultiPlayerScreenState extends State<MultiPlayerScreen> {
  late NativeVideoPlayerController _controller1;
  late NativeVideoPlayerController _controller2;

  @override
  void initState() {
    super.initState();

    // Create multiple controllers with unique IDs
    _controller1 = NativeVideoPlayerController(id: 1, autoPlay: false);
    _controller2 = NativeVideoPlayerController(id: 2, autoPlay: false);

    _initializePlayers();
  }

  Future<void> _initializePlayers() async {
    await _controller1.initialize();
    await _controller2.initialize();

    await _controller1.load(url: 'https://example.com/video1.m3u8');
    await _controller2.load(url: 'https://example.com/video2.m3u8');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: NativeVideoPlayer(controller: _controller1)),
        Expanded(child: NativeVideoPlayer(controller: _controller2)),
      ],
    );
  }

  @override
  void dispose() {
    _controller1.dispose();
    _controller2.dispose();
    super.dispose();
  }
}
```

## API Reference

### NativeVideoPlayerController

#### Constructor Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `id` | `int` | required | Unique identifier for the player instance |
| `autoPlay` | `bool` | `false` | Start playing automatically after loading |
| `enableLooping` | `bool` | `false` | Enable automatic video looping with smooth native playback |
| `mediaInfo` | `NativeVideoPlayerMediaInfo?` | `null` | Media metadata for Now Playing |
| `allowsPictureInPicture` | `bool` | `true` | Enable Picture-in-Picture |
| `canStartPictureInPictureAutomatically` | `bool` | `true` | Auto-start PiP on app background (iOS 14.2+) |
| `showNativeControls` | `bool` | `true` | Show native player controls |

### NativeVideoPlayer Widget

#### Constructor Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `controller` | `NativeVideoPlayerController` | required | The controller for the video player |
| `overlayBuilder` | `Widget Function(BuildContext, NativeVideoPlayerController)?` | `null` | Builder for custom overlay controls on top of the native player |

**Example:**
```dart
NativeVideoPlayer(
  controller: _controller,
  overlayBuilder: (context, controller) {
    return CustomVideoOverlay(controller: controller);
  },
)
```

**Overlay Interaction:**
- Tapping on the video when overlay is hidden shows the overlay
- Tapping on the overlay when visible hides it (in addition to the auto-hide timer)
- Interactive elements (buttons, sliders) in the overlay work normally
- Overlay automatically hides after 3 seconds of inactivity

### NativeVideoPlayerController

#### Methods

**Initialization:**
- `Future<void> initialize()` - Initialize the controller

**Loading Videos:**
- `Future<void> load({required String url, Map<String, String>? headers, Map<String, dynamic>? drmConfig})` - Load video URL or file (generic method, backward compatible). Supports optional DRM configuration for protected content.
- `Future<void> loadUrl({required String url, Map<String, String>? headers, Map<String, dynamic>? drmConfig})` - Load remote video URL with optional HTTP headers and DRM configuration
- `Future<void> loadFile({required String path})` - Load local video file from device storage

**DRM Configuration (`drmConfig` parameter):**
- `type` (String, required): DRM type - `'fairplay'` (iOS), `'widevine'` (Android), `'aes-128'` (both), or `'clearKey'` (both)
- `licenseUrl` (String, required*): License server URL for key requests (*not required for AES-128)
- `certificateUrl` (String, required for FairPlay): Certificate URL for FairPlay DRM (iOS only)
- `headers` (Map<String, String>, optional): HTTP headers for license requests (authentication tokens, etc.)

**Playback Control:**
- `Future<void> play()` - Start playback
- `Future<void> pause()` - Pause playback
- `Future<void> seekTo(Duration position)` - Seek to position
- `Future<void> setVolume(double volume)` - Set volume (0.0-1.0)
- `Future<void> setSpeed(double speed)` - Set playback speed
- `Future<void> setLooping(bool looping)` - Enable or disable video looping
- `Future<void> setQuality(NativeVideoPlayerQuality quality)` - Set video quality

**Display Modes:**
- `Future<bool> isPictureInPictureAvailable()` - Check if PiP is available on device
- `Future<bool> enterPictureInPicture()` - Enter Picture-in-Picture mode
- `Future<bool> exitPictureInPicture()` - Exit Picture-in-Picture mode
- `Future<bool> togglePictureInPicture()` - Toggle Picture-in-Picture mode
- `Future<void> enterFullScreen()` - Enter fullscreen
- `Future<void> exitFullScreen()` - Exit fullscreen
- `Future<void> toggleFullScreen()` - Toggle fullscreen
- `Future<bool> isAirPlayAvailable()` - Check if AirPlay devices are available (iOS only)
- `Future<void> showAirPlayPicker()` - Show AirPlay device picker (iOS only)
- `void addAirPlayAvailabilityListener(void Function(bool) listener)` - Listen for AirPlay availability changes (iOS only)
- `void removeAirPlayAvailabilityListener(void Function(bool) listener)` - Remove AirPlay availability listener (iOS only)
- `void addAirPlayConnectionListener(void Function(bool) listener)` - Listen for AirPlay connection state changes (iOS only)
- `void removeAirPlayConnectionListener(void Function(bool) listener)` - Remove AirPlay connection listener (iOS only)

**AirPlay State Manager (Global):**
- `AirPlayStateManager.instance.init()` - Initialize global AirPlay device detection at app startup (iOS only, requires at least one controller to be created first)
- `AirPlayStateManager.instance.dispose()` - Stop global AirPlay detection and clean up resources (iOS only)
- `void addActivityListener(void Function(PlayerActivityEvent) listener)` - Add activity event listener
- `void removeActivityListener(void Function(PlayerActivityEvent) listener)` - Remove activity event listener
- `void addControlListener(void Function(PlayerControlEvent) listener)` - Add control event listener
- `void removeControlListener(void Function(PlayerControlEvent) listener)` - Remove control event listener
- `Future<void> releaseResources()` - Release Flutter resources but keep native player alive (for temporary cleanup)
- `Future<void> dispose()` - Fully dispose all resources including native player (for complete cleanup)

#### Properties

- `List<NativeVideoPlayerQuality> qualities` - Available HLS quality variants
- `bool isFullScreen` - Current fullscreen state
- `Duration currentPosition` - Current playback position
- `Duration duration` - Total video duration
- `Duration bufferedPosition` - How far the video has been buffered
- `double volume` - Current volume (0.0-1.0)
- `PlayerActivityState activityState` - Current activity state
- `PlayerControlState controlState` - Current control state
- `String? url` - Current video URL

#### Streams

- `Stream<Duration> bufferedPositionStream` - Stream of buffered position changes
- `Stream<Duration> durationStream` - Stream of duration changes
- `Stream<PlayerActivityState> playerStateStream` - Stream of player state changes
- `Stream<Duration> positionStream` - Stream of playback position changes
- `Stream<double> speedStream` - Stream of playback speed changes
- `Stream<bool> isPipEnabledStream` - Stream of PiP state changes
- `Stream<bool> isPipAvailableStream` - Stream of PiP availability changes
- `Stream<bool> isAirplayAvailableStream` - Stream of AirPlay availability changes
- `Stream<bool> isFullscreenStream` - Stream of fullscreen state changes
- `Stream<NativeVideoPlayerQuality> qualityChangedStream` - Stream of quality changes

### Activity Event States

| State | Description |
|-------|-------------|
| `PlayerActivityState.idle` | Player is idle |
| `PlayerActivityState.initializing` | Player is initializing |
| `PlayerActivityState.initialized` | Player initialized |
| `PlayerActivityState.loading` | Video is loading |
| `PlayerActivityState.loaded` | Video loaded successfully |
| `PlayerActivityState.playing` | Playback is active |
| `PlayerActivityState.paused` | Playback is paused |
| `PlayerActivityState.buffering` | Video is buffering |
| `PlayerActivityState.completed` | Playback completed |
| `PlayerActivityState.stopped` | Playback stopped |
| `PlayerActivityState.error` | Error occurred |

### Control Event States

| State | Description |
|-------|-------------|
| `PlayerControlState.none` | No control event |
| `PlayerControlState.qualityChanged` | Video quality changed |
| `PlayerControlState.speedChanged` | Playback speed changed |
| `PlayerControlState.seeked` | Seek operation completed |
| `PlayerControlState.pipStarted` | PiP mode started |
| `PlayerControlState.pipStopped` | PiP mode stopped |
| `PlayerControlState.fullscreenEntered` | Fullscreen entered |
| `PlayerControlState.fullscreenExited` | Fullscreen exited |
| `PlayerControlState.timeUpdated` | Playback time updated |

## Architecture

### iOS
- Uses `AVPlayerViewController` for video playback
- Implements `FlutterPlatformView` for embedding native views
- Supports HLS streaming with native `AVPlayer`
- Picture-in-Picture via `AVPictureInPictureController`
- Now Playing info via `MPNowPlayingInfoCenter`

### Android
- Uses ExoPlayer (Media3) for video playback
- Implements `PlatformView` with `AndroidView`
- HLS support via Media3 HLS extension
- Picture-in-Picture via [floating package](https://pub.dev/packages/floating)
- Media notifications via `MediaSessionService`

## Troubleshooting

### Common Issues

**Controller not initializing:**
```dart
// Always call initialize() before load()
await _controller.initialize();
await _controller.load(url: 'https://example.com/video.m3u8');
```

**Events not firing:**
```dart
// Make sure to add listeners BEFORE calling initialize()
_controller.addActivityListener(_handleActivityEvent);
_controller.addControlListener(_handleControlEvent);
await _controller.initialize();
```

**Multiple controllers interfering:**
```dart
// Ensure each controller has a unique ID
final controller1 = NativeVideoPlayerController(id: 1);
final controller2 = NativeVideoPlayerController(id: 2);
```

**Shared controllers with automatic PiP:**
```dart
// When using the same controller ID across multiple views (e.g., list + detail screen),
// automatic PiP will be enabled on the most recently active view
final listController = NativeVideoPlayerController(
  id: 1, // Same ID
  canStartPictureInPictureAutomatically: true,
);

final detailController = NativeVideoPlayerController(
  id: 1, // Same ID - shares the player instance
  canStartPictureInPictureAutomatically: true,
);

// When navigating to detail screen, automatic PiP transfers to that view
// This works for both programmatic playback and native control playback
```

**Memory leaks:**
```dart
// Always remove listeners and dispose controllers properly
@override
void dispose() {
  // Remove all listeners first
  _controller.removeActivityListener(_handleActivityEvent);
  _controller.removeControlListener(_handleControlEvent);
  _controller.removeAirPlayAvailabilityListener(_handleAirPlayAvailability);
  _controller.removeAirPlayConnectionListener(_handleAirPlayConnection);
  
  // Choose the appropriate disposal method:
  // - Use dispose() for complete cleanup (recommended in most cases)
  // - Use releaseResources() only for shared player scenarios
  _controller.dispose();
  super.dispose();
}
```

**Note:** See the [Lifecycle Management](#lifecycle-management) section for details on when to use `dispose()` vs `releaseResources()`.

### iOS

**Video doesn't play:**
- Ensure `Info.plist` has `NSAppTransportSecurity` configured for HTTP videos
- For HTTPS with self-signed certificates, add exception domains
- For local files, ensure proper file access permissions
- Check that the video format is supported by AVPlayer (HLS, MP4, MOV)

**PiP not working:**
- **Required**: Add `picture-in-picture` to `UIBackgroundModes` in Info.plist (in addition to `audio`)
  ```xml
  <key>UIBackgroundModes</key>
  <array>
      <string>audio</string>
      <string>picture-in-picture</string>
  </array>
  ```
- OR enable via Xcode: Target → Signing & Capabilities → Background Modes → Check "Audio, AirPlay, and Picture in Picture"
- Ensure iOS version is 14.0+ (check with `await controller.isPictureInPictureAvailable()`)
- For **automatic PiP** when app goes to background, iOS 14.2+ is required and `canStartPictureInPictureAutomatically` must be `true` (default)
- PiP requires video to be playing before entering PiP mode
- Some simulators don't support PiP; test on a physical device

**Now Playing not showing:**
```dart
// Provide mediaInfo when creating the controller
_controller = NativeVideoPlayerController(
  id: 1,
  mediaInfo: const NativeVideoPlayerMediaInfo(
    title: 'Video Title',
    subtitle: 'Artist Name',
  ),
);
```

**Background audio stops:**
- Verify Background Modes are enabled in Xcode capabilities
- Ensure "Audio, AirPlay, and Picture in Picture" is checked

### Android

**Video doesn't play:**
- Check internet permissions in your app's `AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.INTERNET" />
```
- Ensure minimum SDK version is 24+ in `build.gradle`:
```gradle
minSdkVersion 24
```
- For HTTPS issues, check your network security configuration
- Verify ExoPlayer supports the video format (HLS, MP4, WebM)

**PiP not working:**
- **Required**: On Android, PiP is only available when the video is in **Dart fullscreen mode** (using custom overlay controls with `overlayBuilder`)
- Enter fullscreen first before entering PiP: `await controller.enterFullScreen();`
- PiP requires Android 8.0+ (API 26+)
- Check device support: `await controller.isPictureInPictureAvailable()`
- Android PiP is handled by the [floating package](https://pub.dev/packages/floating) - no MainActivity configuration needed
- For automatic PiP when pressing home button, set `canStartPictureInPictureAutomatically: true` (default)
- For manual PiP, call `await controller.enterPictureInPicture()`
- Only the video surface is shown in PiP mode; all overlays are automatically hidden
- The plugin automatically configures `android:supportsPictureInPicture="true"` in its manifest

**Fullscreen issues:**
- The plugin handles fullscreen natively using a Dialog on Android
- Fullscreen works automatically; no additional configuration needed
- Ensure proper activity lifecycle management
- If orientation is locked, fullscreen may not rotate automatically

**Orientation restoration:**
- The plugin automatically saves and restores orientation preferences when entering/exiting fullscreen
- To specify app orientation preferences, use the `preferredOrientations` parameter:
  ```dart
  final controller = NativeVideoPlayerController(
    id: 1,
    preferredOrientations: [DeviceOrientation.portraitUp],
  );
  ```
- Alternatively, use `FullscreenManager.setPreferredOrientations()` before entering fullscreen
- When exiting fullscreen, the plugin automatically restores your specified orientations

**Media notifications not showing:**
- The plugin automatically configures `MediaSessionService`
- Ensure foreground service permissions are granted (handled automatically)
- Media info must be provided via `mediaInfo` parameter
- Notifications appear when video is playing in background

**ExoPlayer errors:**
- Check logcat for detailed error messages
- Common issues:
  - Network timeouts: Check internet connectivity
  - Unsupported format: Verify video codec compatibility
  - DRM content: This plugin doesn't support DRM (yet)

### General Debugging

**Enable verbose logging:**
```dart
// Check player state
print('Activity State: ${_controller.activityState}');
print('Control State: ${_controller.controlState}');
print('Is Fullscreen: ${_controller.isFullScreen}');
print('Current Position: ${_controller.currentPosition}');
print('Duration: ${_controller.duration}');
```

**Test with known working URLs:**
```dart
// HLS stream (with quality selection)
const hlsUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

// MP4 video (direct playback)
const mp4Url = 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';

// Another MP4 example
const mp4Url2 = 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4';
```

**Platform-specific issues:**
```dart
import 'dart:io';

if (Platform.isIOS) {
  // iOS-specific code
} else if (Platform.isAndroid) {
  // Android-specific code
}
```

## Example App

See the `example` folder for a complete working example demonstrating:

### Features Demonstrated
- **Video List with Inline Players**: Multiple video players in a scrollable list
- **Full-Screen Video Detail Page**: Dedicated page with comprehensive controls
- **Custom Overlay Controls**: Complete example of building custom video controls
- **AirPlay Integration**: AirPlay button with availability and connection tracking (iOS)
- **Playback Controls**: Play, pause, seek (±10 seconds), volume control
- **Speed Adjustment**: 0.25x, 0.5x, 0.75x, 1.0x, 1.25x, 1.5x, 1.75x, 2.0x playback speeds
- **Quality Selection**: Automatic quality detection and manual selection for HLS streams
- **Picture-in-Picture**: Enter/exit PiP mode with state tracking
- **Fullscreen Toggle**: Both native and Dart-side fullscreen support
- **Real-time Statistics**: Current position, duration, buffered position tracking
- **Separated Event Handling**: Activity and control events with detailed logging
- **Custom Media Info**: Now Playing integration with metadata
- **Buffered Position Indicator**: Visual representation of how much video has been preloaded

### Running the Example

```bash
cd example
flutter run
```

The example includes:
- `video_list_screen_with_players.dart` - Multiple inline video players
- `video_detail_screen_full.dart` - Full-featured video player with controls
- `video_with_overlay_screen.dart` - Custom overlay controls demonstration
- `custom_video_overlay.dart` - Complete custom overlay implementation with play/pause, progress bar, speed controls, quality selection, volume, AirPlay button, and auto-hide functionality
- `video_player_card.dart` - Reusable video player widget
- `video_item.dart` - Video model with sample HLS streams

## License

MIT License - see LICENSE file for details

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Credits

Developed for the Flutter community. Based on native video player implementations using industry-standard libraries:
- iOS: AVFoundation
- Android: ExoPlayer (Media3)

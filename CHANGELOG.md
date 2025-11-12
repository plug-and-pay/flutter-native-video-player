# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.3] - 2025-11-12

### Improved
- **iOS Picture-in-Picture Multi-View Handling**: Enhanced PiP functionality when using multiple views with shared controllers
  - Added checks for active PiP across multiple views to prevent conflicts
  - Improved PiP stopping actions to work correctly even when navigating between views
  - Better error handling for cases where no active PiP is found
  - Enhanced user experience by ensuring PiP can be stopped from any active view

- **iOS Picture-in-Picture Reliability**: Major improvements to PiP start/stop mechanisms
  - Implemented retry mechanism for starting PiP with detailed logging for attempts and outcomes
  - Enhanced automatic PiP handling with improved player state detection
  - Better PiP activation and transfer logic to improve reliability during playback
  - Added comprehensive diagnostics and logging for debugging PiP transitions

- **iOS Audio Session Interruption Handling**: Added robust handling for audio session interruptions
  - Implemented observer for audio session interruptions (e.g., phone calls, alarms)
  - Automatic reactivation of audio session after interruption ends
  - Restoration of Now Playing info post-interruption
  - Enhanced logging for better tracking of audio session states during playback

- **iOS Now Playing Info Persistence**: Comprehensive improvements to media control reliability
  - Implemented foreground notification handling to restore Now Playing info when app returns from background
  - Added fallback mechanism to retrieve media info from SharedPlayerManager when local data is unavailable
  - Enhanced media info retrieval in VideoPlayerObserver for accurate Now Playing info during playback
  - Improved PiP restoration logic with proper cleanup during view disposal
  - Media info now persists correctly when PiP is active or during restoration transitions
  - Added `isPipActiveForController` method to check PiP status across all views for a controller

- **iOS Remote Command Management**: Enhanced reliability of media control registration
  - Refined remote command re-registration logic to prevent unnecessary re-registration
  - Added ownership status checks before re-registering commands
  - Introduced flag to track registration status for better management during ownership transfers
  - Force re-registration capability with immediate and delayed verification checks
  - Improved Now Playing info accuracy with better tracking of command status

- **iOS Audio Session Activation**: Enhanced audio session handling for Now Playing info
  - Activate audio session in VideoPlayerNowPlayingHandler to ensure info displays correctly
  - Added error handling for session activation to improve reliability
  - Added playback rate logging and detailed checks for audio session state
  - Comprehensive diagnostics for remote command targets and Now Playing info completeness

### Fixed
- **iOS Now Playing Controls**: Fixed media controls becoming unresponsive after various transitions
  - Fixed Now Playing info not displaying after returning from background
  - Fixed media info being lost during PiP restoration
  - Fixed remote command targets not being properly re-registered during ownership transfers
  - Prevents "Unknown" or blank media info from appearing in Control Center and lock screen

- **iOS HDR Performance**: Removed outdated HDR correction code for improved performance optimization

## [0.3.2] - 2025-11-10

### Changed
- **HDR Enabled by Default**: Changed `enableHDR` default value from `false` to `true`
  - HDR content will now display with proper HDR rendering by default
  - Set to `false` if you prefer SDR tone-mapping for HDR content

### Improved
- **iOS Media Info Persistence**: Enhanced media info handling during Picture-in-Picture transitions
  - Added media info caching in SharedPlayerManager to persist across view recreations
  - Media info now survives view disposal during PiP mode
  - Ensures Now Playing controls remain functional with correct title/subtitle during PiP
  - Prevents media info from being cleared when transitioning between views
  - Media info automatically stored when loading video and persists throughout controller lifetime

- **iOS Manual PiP vs Automatic PiP**: Added tracking to prevent conflicts between manual and automatic PiP
  - Added `controllersWithManualPiP` tracking in SharedPlayerManager
  - Prevents automatic PiP from interfering when user manually enters PiP
  - Automatic PiP re-enabling skipped when manual PiP is active
  - Improves reliability when using both PiP modes in the same app

- **iOS PiP State Tracking**: Enhanced PiP state detection and handling
  - Added `isPipCurrentlyActive` flag to VideoPlayerView for reliable PiP state tracking
  - Better synchronization between PiP controller state and view state
  - Improved cleanup logic when view is disposed while PiP is active
  - More accurate detection of PiP transitions for proper event delivery

- **Code Quality**: Code formatting improvements across Flutter controller
  - Removed unnecessary line breaks for cleaner code structure
  - Better readability with consistent formatting
  - Improved maintainability of the codebase

### Fixed
- **iOS Media Controls During PiP**: Fixed media controls becoming unresponsive during PiP transitions
  - Media info no longer cleared from SharedPlayerManager when view is disposed during PiP
  - Lock screen and Control Center controls remain functional throughout PiP lifecycle
  - Prevents "Unknown" or blank media info from appearing in system controls

## [0.3.1] - 2025-11-09

### Fixed
- **iOS Picture-in-Picture Event Delivery**: Fixed issue where PiP stop events could fail when exiting PiP with disposed views
  - Added `findAllViewsForController()` method to SharedPlayerManager to locate active views for a controller
  - Enhanced PiP stop event handling to fallback to alternative active views when primary view is disposed
  - Fixed `pictureInPictureController:restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:` to handle disposed views
  - Now attempts to find and restore UI on alternative active views with the same controller
  - Completes with false when no active view exists, allowing iOS to exit PiP gracefully
  - Added PiP state detection in `deinit` to send pipStop events before view disposal
  - Ensures pipStop events are always delivered when exiting PiP, even with disposed or inactive views
  - Prevents app crashes or inconsistent state when exiting PiP after navigating away from video view

## [0.3.0] - 2025-11-08

### Added
- **Video Looping Support**: Comprehensive video looping functionality with smooth native playback
  - Added `enableLooping` parameter to `NativeVideoPlayerController` constructor (default: false)
  - Added `setLooping(bool)` method for dynamic looping control during playback
  - Android uses ExoPlayer's `REPEAT_MODE_ONE` for seamless native looping
  - iOS implements looping via seek to beginning and automatic replay without gaps
  - Smooth looping without visible pause or stuttering across both platforms

- **Multiple Video Format Support**: Extended support beyond HLS streams
  - Added support for MP4 video URLs (remote)
  - Added support for local video files (file:// URIs)
  - Android uses `ProgressiveMediaSource` for non-HLS content
  - iOS AVPlayer natively supports multiple formats (MP4, MOV, M4V)
  - Android supports additional formats (WebM, MKV)
  - Added `isHlsUrl()` helper function for improved format detection on both platforms
  - Quality selection remains available for HLS streams

- **Convenience Loading Methods**: New explicit methods for improved API clarity
  - Added `loadUrl({required String url, Map<String, String>? headers})` for remote videos
  - Added `loadFile({required String path})` for local files (automatically constructs file:// URIs)
  - Existing `load()` method remains for backward compatibility
  - Better IDE autocomplete and discoverability

- **Asset Video Support**: Local video file playback from Flutter assets
  - Implemented new MethodChannel for resolving asset paths on both platforms
  - Assets are automatically extracted to cache directory for playback
  - Seamless integration with existing loading methods
  - Added example with local asset (ElephantsDream.mp4)

### Improved
- **iOS Media Controls**: Fixed critical issues with native media controls across multiple scenarios
  - Fixed MPRemoteCommandCenter conflicts when using multiple videos with shared controllers
  - Added `RemoteCommandManager` singleton to centralize ownership of remote commands
  - Remote command ownership now tracked by viewId instead of media title for reliability
  - Fixed media controls becoming unresponsive when entering/exiting PiP
  - Fixed lock screen controls showing incorrect media info or becoming unresponsive
  - Proper cleanup of remote command targets in deinit to prevent dangling references
  - Remote command handlers now verify ownership before processing events
  - Fixed periodic observer conflicts causing incorrect Now Playing info updates

- **Remote Command Ownership Transfer**: Automatic management between multiple views
  - Only the "owner" view can register remote command handlers and update Now Playing info
  - Ownership automatically transfers when entering/exiting PiP
  - Prevents conflicts when multiple VideoPlayerView instances exist simultaneously
  - Ensures consistent media control behavior across app lifecycle

### Fixed
- **iOS Now Playing Info Persistence**: Fixed Now Playing info disappearing or showing wrong data
  - Now Playing ownership no longer fails with duplicate titles or disposed views
  - Media controls remain functional when switching between videos
  - Lock screen and Control Center always show correct media information

- **Race Conditions**: Consolidated cleanup logic to prevent race conditions
  - Better synchronization between view lifecycle and remote command management
  - Improved timing of ownership transfers during PiP transitions

- **HLS Detection**: Improved quality switching and HLS stream detection
  - More reliable detection of HLS vs progressive video formats
  - Quality fetching only attempted for actual HLS streams
  - Better logging for source type detection and debugging

### Documentation
- Updated README with "Supported Video Formats" section
- Added examples for HLS, MP4, and local file usage
- Updated feature list to highlight multi-format support
- Added test URLs for both HLS and MP4 formats
- Updated API Reference with new convenience methods
- Added path_provider example for local file handling
- Updated example app with mixed HLS and MP4 examples

## [0.2.20] - 2025-11-06

### Improved
- **Android Auto Picture-in-Picture**: Major enhancements to automatic PiP mode when pressing home button
  - Unified PiP entry logic with single `enterPictureInPictureInternal()` method that handles both manual and automatic triggers
  - Removed `setAutoEnterEnabled(true)` which was bypassing custom PiP logic and `onUserLeaveHint` callback
  - Improved fullscreen transition before PiP entry - now enters fullscreen silently without sending intermediate events
  - Added `onStop()` lifecycle method in example MainActivity to catch auto PiP on devices where `onUserLeaveHint` isn't reliably called
  - Better source rect calculation for PiP window positioning when transitioning from fullscreen
  - Enhanced logging throughout PiP flow for better debugging
  - Auto PiP now enabled by default in example app with proper state tracking

- **Android MainActivity Configuration**: Cleaned up example app MainActivity
  - Removed `android:taskAffinity=""` from AndroidManifest which could cause activity lifecycle issues
  - Added `isInPipMode` flag to track PiP state across lifecycle methods
  - Created unified `tryEnterAutoPip()` method called from both `onUserLeaveHint` and `onStop`
  - Improved PiP state restoration with immediate event emission after exiting PiP
  - Enhanced logging with warning emojis for better visibility in logcat

### Fixed
- **Android 12+ PiP Behavior**: Fixed `setAutoEnterEnabled` causing Android to automatically enter PiP without proper custom logic
  - Android's auto-enter was bypassing the plugin's fullscreen transition and state management
  - Now uses only `setSeamlessResizeEnabled` for smooth transitions while maintaining control over PiP entry
  - Ensures proper event flow and state synchronization when entering PiP

- **Auto PiP Reliability**: Fixed auto PiP not working reliably on all Android devices
  - Added fallback to `onStop()` when `onUserLeaveHint()` isn't called (device-specific behavior)
  - Better detection of home button press across different Android versions and manufacturers
  - Prevents entering PiP when activity is finishing (back button vs home button)

## [0.2.19] - 2025-11-06

### Improved
- **Video Completion Behavior**: Enhanced video completion handling to provide better user experience
  - Video now automatically resets to the beginning when playback completes
  - Player automatically pauses after completion instead of staying in ended state
  - Applies to both iOS (AVPlayer) and Android (ExoPlayer) platforms
  - Ensures consistent behavior across platforms for replay scenarios

- **Android State Restoration After Exiting PiP**: Enhanced state synchronization when exiting Picture-in-Picture mode
  - Added `emitCurrentState()` method to re-emit all player states after PiP exit
  - Ensures UI components receive accurate position, duration, buffered position, and playback state
  - Automatically emits current timeUpdate with buffering state
  - Emits current play/pause state to synchronize UI controls
  - Prevents UI from displaying stale state after returning from PiP mode on Android

## [0.2.18] - 2025-11-05

### Fixed
- **State Restoration After Exiting PiP**: Fixed issue where player state would not be properly restored after exiting Picture-in-Picture mode
  - Added `emitCurrentState()` method on both iOS and Android to re-emit all player states after PiP exit
  - Ensures UI components receive accurate position, duration, buffered position, and playback state
  - Prevents UI from showing stale or incorrect state after returning from PiP mode
  - Applies to both platforms when user exits PiP via system gesture or button

### Improved
- **Code Quality (Flutter)**: Improved code formatting across `NativeVideoPlayerController`
  - Better line formatting and consistency throughout the codebase
  - Enhanced readability with improved code organization
  - Removed unnecessary line breaks for cleaner code structure

### Documentation
- **Android PiP Setup**: Added comprehensive documentation for required MainActivity PiP callback
  - Documented why MainActivity callback is necessary for proper PiP state restoration
  - Added complete code example for MainActivity implementation
  - Clarified consequences of not implementing the callback

## [0.2.17] - 2025-11-05

### Improved
- **Code Quality (Android)**: Enhanced import organization in VideoPlayerMethodHandler
  - Added explicit import for SharedPlayerManager
  - Simplified fully qualified class name references
  - Improved code readability and maintainability

## [0.2.16] - 2025-11-04

### Improved
- **Enhanced Initialization Handling**: Improved controller initialization with better state tracking
  - Added `_isInitialized` and `_isInitializing` flags to prevent duplicate initialization
  - Initialize completer now waits properly for existing initialization to complete
  - Early return when platform view is already created with method channel
  - Added `isInitialized` getter to check initialization status programmatically

- **Immediate State Emission for New Listeners**: Event listeners now receive current state immediately upon registration
  - New activity listeners immediately receive current activity state (playing, paused, etc.)
  - New control listeners immediately receive current position, duration, and buffer state
  - Eliminates the need to wait for the next event when adding listeners after initialization
  - Includes debug logging to track listener registration and state emission

- **Duration Persistence During AirPlay**: Fixed duration being lost during AirPlay transitions
  - Duration is now protected from being overwritten with 0 during AirPlay connection/disconnection
  - Duration controller explicitly re-emits when AirPlay connects to ensure UI stays updated
  - Prevents progress bars and time displays from temporarily showing 0:00 during transitions

- **Unified Event Name Handling**: Added support for both 'timeUpdate' and 'timeUpdated' event names
  - Native platforms can now use either naming convention
  - Improves compatibility and reduces potential event parsing issues

### Fixed
- **Duration Lost During Navigation**: Fixed issue where duration would be temporarily lost when listeners are added after player initialization
  - Controller now notifies all listeners with current state when duration becomes available
  - Ensures UI components added dynamically receive accurate state information

## [0.2.15] - 2025-10-31

### Added
- **Buffering State Debounce**: Added 400ms debounce to buffering state changes to prevent UI flicker
  - Buffering state is only emitted if it persists for more than 400ms
  - Prevents brief buffering periods from causing UI flicker
  - Automatically restores previous play/pause state when buffering completes
  - Tracks last non-buffering state for accurate restoration

### Improved
- **Code Quality**: Removed all `debugPrint` statements from the package
  - Cleaner production code without debug output
  - Better performance by avoiding unnecessary string operations
  - Error handling now uses silent catch blocks or returns appropriate defaults

### Fixed
- **Custom Overlay Not Working After Navigation**: Fixed critical issue where custom overlays would break after using `releaseResources()`
  - `_overlayBuilder` is now preserved across `releaseResources()` calls
  - Native controls properly hide/show based on overlay presence after reconnection
  - Overlay builder persists like other state (`_state`, `_url`) for quick resumption
  - Fixes issue where controls would be completely non-functional on second visit
  - Only cleared on final `dispose()`, not on temporary `releaseResources()`

## [0.2.14] - 2025-10-31

### Added
- **Continuous Buffering State Reporting**: Buffering state is now always reported in real-time
  - Added `isBuffering` boolean to `timeUpdate` events (sent every 500ms)
  - Android: Tracks `player.playbackState == Player.STATE_BUFFERING`
  - iOS: Tracks `player.timeControlStatus == .waitingToPlayAtSpecifiedRate`
  - Flutter controller automatically transitions to `PlayerActivityState.buffering` when buffering starts
  - Ensures UI always reflects accurate buffering status, even when video is in play state

### Improved
- **Qualities Persistence After Re-initialization**: Video qualities now persist across view recreations
  - Added `qualitiesCache` storage to `SharedPlayerManager` on both iOS and Android
  - Qualities are automatically cached when fetched and restored when view is recreated
  - Eliminates the need to re-fetch qualities from network after navigation
  - Ensures qualities are immediately available after calling `releaseResources()` and re-initializing

### Fixed
- **Buffering Not Visible During Playback**: Fixed issue where video would buffer while in play state without indicating buffering status
  - Buffering state is now continuously tracked and reported every 500ms
  - UI can now simultaneously show that video wants to play but is currently buffering
  - Prevents confusion when video stalls during playback

- **Missing Qualities After Navigation**: Fixed issue where video qualities would disappear after navigating away and back
  - Qualities are now stored in `SharedPlayerManager` which survives view recreation
  - `getAvailableQualities()` automatically restores from cache when view instance is empty
  - Works correctly with the release/re-init pattern used when navigating

## [0.2.13] - 2025-10-30

### Added
- **Overlay Lock Feature**: Added ability to lock custom overlay to always be visible
  - New `lockOverlay()` method to keep overlay permanently visible
  - New `unlockOverlay()` method to restore normal tap-to-hide behavior
  - New `isOverlayLocked` getter to check current lock state
  - New `isOverlayLockedStream` for reactive lock state updates
  - When locked, overlay cannot be dismissed by tapping or auto-hide timer
  - Useful for live streams, interactive content, or when constant access to controls is needed

### Fixed
- **AirPlay Connection State Updates**: Fixed issue where AirPlay connection state was not properly updating the controller state
  - Now properly updates `_state.isAirplayConnected` when receiving `airPlayConnectionChanged` events
  - Ensures `isAirplayConnectedStream` emits correctly when connection state changes
  - Provides consistent state tracking between event handlers and controller state
  
## [0.2.12] - 2025-10-30

### Added
- **Automatic Overlay Management for PiP**: Custom overlays now automatically hide when entering PiP and show when exiting PiP on Android
  - Prevents overlay from appearing in PiP window
  - Seamless user experience when transitioning to/from PiP mode
  - Only affects Android platform (iOS handles PiP differently)

### Improved
- **Enhanced Picture-in-Picture Transitions (Android)**: Major improvements to PiP mode behavior
  - Added automatic fullscreen entry before PiP for better visual transitions
  - Added `wasFullscreenBeforePip` tracking to restore correct state after PiP
  - Implemented source rect hints for more accurate PiP window positioning
  - Added seamless resize support for Android 12+ for smoother PiP transitions
  - PiP window now correctly restores to inline or fullscreen mode based on state before PiP entry
  - Improved visual consistency when entering and exiting PiP mode

- **Shared Player Surface Reconnection**: Enhanced surface handling for shared players
  - Added automatic surface reconnection after `releaseResources()` is called
  - Ensures video playback resumes correctly when returning to a video with a shared player
  - Prevents black screen issues when navigating back to previously viewed videos

- **PiP Availability Detection**: Improved activity context handling for PiP feature detection
  - Added `getActivity()` helper method to properly unwrap `ContextWrapper` instances
  - More reliable PiP availability checks across different context types
  - Better error handling when activity context is not immediately available

### Fixed
- **Custom Overlay in PiP Window**: Fixed issue where custom overlays would appear in the PiP window on Android
  - Overlay is now automatically hidden before entering PiP
  - Overlay automatically reappears when exiting PiP
  - Provides clean PiP experience with only native system controls

- **Fullscreen State After PiP**: Fixed incorrect fullscreen state restoration after exiting PiP
  - Now properly tracks fullscreen state before entering PiP
  - Restores to inline mode if video was inline before PiP
  - Maintains fullscreen mode if video was fullscreen before PiP
  - Eliminates unexpected fullscreen state changes after PiP

## [0.2.11] - 2025-10-28

### Fixed
- **Progress Bar Seek Jump**: Fixed issue where progress bar would jump back briefly after seeking
  - Added `_targetSeekPosition` to track where we're seeking to
  - Modified seek handling to ignore old position events during seek operation
  - Progress bar now stays at target position until native player confirms seek completion
  - Position updates within 200ms of target are considered successful seeks
  - Eliminates the 500ms "jump back" behavior when seeking

## [0.2.10] - 2025-10-28

### Added
- **Quality List Stream**: Added `qualitiesStream` to track changes in available video qualities
  - Stream emits `List<NativeVideoPlayerQuality>` whenever quality list changes
  - Useful for updating UI when qualities are loaded or changed
  - Follows the same pattern as other property streams
  - Example usage in `custom_video_overlay.dart` demonstrates reactive quality selector updates

- **Automatic Orientation Restoration**: Enhanced `FullscreenManager` with intelligent orientation tracking
  - Automatically saves current orientation preferences when entering fullscreen
  - Restores original orientations when exiting fullscreen (no manual setup required)
  - Added `setPreferredOrientations()` helper method as optional drop-in replacement for `SystemChrome.setPreferredOrientations()`
  - Added `preferredOrientations` parameter to `NativeVideoPlayerController` for easy orientation configuration
  - Supports per-controller orientation preferences (e.g., portrait-only apps can specify this when creating the controller)

- **Tap-to-Hide Overlay**: Enhanced custom overlay interaction
  - Tapping on visible overlay now hides it (in addition to the auto-hide timer)
  - Tapping on hidden overlay shows it (existing behavior)
  - Interactive elements (buttons, sliders) are unaffected and work normally
  - Uses `HitTestBehavior.deferToChild` for proper gesture handling

### Fixed
- **Stream Disposal Race Condition**: Fixed "Bad state: Cannot add new events after calling close" error
  - Added `_isDisposed` flag to prevent state updates after disposal
  - Added `isClosed` checks before adding events to all stream controllers
  - Improved disposal order: now cancels event subscriptions before closing stream controllers
  - Added double-disposal guard to prevent errors from multiple dispose calls
  - Affects: `bufferedPositionController`, `durationController`, `playerStateController`, `positionController`, `speedController`, `isPipEnabledController`, `isPipAvailableController`, `isAirplayAvailableController`, `isAirplayConnectedController`, `isFullscreenController`, `qualityChangedController`, and `qualitiesController`

### Changed
- **Custom Video Overlay**: Refactored to use streams instead of control events
  - Now uses `bufferedPositionStream` for reactive buffer position updates
  - Now uses `qualitiesStream` for reactive quality list updates
  - Reduced dependency on control event polling
  - Improved code organization and separation of concerns
  - Added `dart:async` import for `StreamSubscription` support

### Documentation
- Updated `NativeVideoPlayerController` documentation with `preferredOrientations` usage examples
- Updated `FullscreenManager` documentation explaining automatic orientation tracking
- Added comprehensive explanation of auto quality feature and buffer health thresholds

## [0.2.9] - 2025-10-27

### Added
- **HDR Control**: Added `enableHDR` parameter to `NativeVideoPlayerController`
  - Defaults to `false` to prevent washed-out/too-white video appearance on HDR content
  - Set to `true` to enable HDR playback when desired
  - Applies to both iOS and Android platforms
  - ExoPlayer automatically handles tone-mapping to SDR when HDR is disabled

- **AirPlay Connection State Tracking**: Enhanced AirPlay monitoring with connection state
  - Added `isAirplayConnected` property to `NativeVideoPlayerState`
  - Added `isAirplayConnected` getter to `NativeVideoPlayerController`
  - Added `isAirplayConnectedStream` for real-time connection state updates
  - New `PlayerControlState` events: `airPlayConnected` and `airPlayDisconnected`
  - Allows UI to respond to active AirPlay streaming state

- **Convenience State Getters**: Added direct property access to controller state
  - `speed` - Current playback speed
  - `isPipEnabled` - Current Picture-in-Picture state
  - `isPipAvailable` - PiP device availability
  - `isAirplayAvailable` - AirPlay device availability
  - `isAirplayConnected` - Active AirPlay connection state

### Fixed
- **Android Picture-in-Picture Media Session**: Fixed media info not displaying correctly in PiP mode
  - Media session now properly updates when entering PiP mode (manual, automatic, and exit)
  - Ensures notification and lock screen controls show correct title, subtitle, and artwork
  - Applies to all PiP entry/exit scenarios: manual start/stop and automatic transitions

### Changed
- Enhanced `NativeVideoPlayerState` model with `isAirplayConnected` property
- Updated event handling to process AirPlay connection state changes
- Improved Android PiP lifecycle to ensure media session consistency

## [0.2.8] - 2025-10-27

### Added
- **Individual Property Streams**: Added dedicated broadcast streams for convenient property monitoring
  - `bufferedPositionStream` - Stream of buffered position changes
  - `durationStream` - Stream of duration changes
  - `playerStateStream` - Stream of player state changes (playing, paused, buffering, etc.)
  - `positionStream` - Stream of playback position changes
  - `speedStream` - Stream of playback speed changes
  - `isPipEnabledStream` - Stream of Picture-in-Picture state changes
  - `isPipAvailableStream` - Stream of Picture-in-Picture availability changes
  - `isAirplayAvailableStream` - Stream of AirPlay availability changes
  - `isFullscreenStream` - Stream of fullscreen state changes
  - `qualityChangedStream` - Stream of quality changes
  - Streams only emit when values actually change (no duplicate emissions)
  - All streams are broadcast streams allowing multiple listeners

- **Toggle Picture-in-Picture**: Added `togglePictureInPicture()` method for easy PiP toggling
  - Automatically checks current PiP state and enters/exits accordingly
  - Returns `bool` indicating success/failure of the operation
  - Follows the same pattern as `toggleFullScreen()` for consistency

### Changed
- **Enhanced State Model**: Extended `NativeVideoPlayerState` with new properties
  - Added `speed` property to track playback speed
  - Added `isPipEnabled` property to track current PiP state
  - Added `isPipAvailable` property to track PiP device availability
  - Added `isAirplayAvailable` property to track AirPlay device availability
  - Updated `copyWith()`, `operator==`, and `hashCode` to include new properties

- **Improved Event Handling**: Enhanced event processing to update state properties
  - Quality changes now update state and emit to quality stream
  - Speed changes now update state and emit to speed stream
  - PiP state changes (both platform view and MainActivity events) now update state and emit to PiP streams
  - PiP availability changes now update state and emit to availability stream
  - AirPlay availability changes now update state and emit to AirPlay stream

### Documentation
- Added comprehensive documentation for individual property streams in README
- Added usage examples showing how to use streams vs event listeners
- Updated API Reference section with new streams and toggle method
- Added dedicated Streams subsection in API Reference documenting all 10 available streams
- Updated Picture-in-Picture section with `togglePictureInPicture()` usage examples

### Note
- The original event listeners (`addActivityListener`, `addControlListener`) continue to work as before
- Users can choose between using dedicated streams or event listeners based on their use case
- Stream controllers are properly disposed in the `dispose()` method to prevent memory leaks

## [0.2.7] - 2025-10-23

### Improved
- **Enhanced Player Disposal and Cleanup**: Improved SharedPlayerManager on both iOS and Android platforms
  - Added `stopAllViewsForController()` method to properly stop playback and clear player from all views when disposing
  - Enhanced iOS disposal to pause player and clear current item before removing
  - Enhanced Android disposal to stop playback and clear active views
  - Improved logging for better debugging of player lifecycle
  - Better cleanup of view references when controller is disposed

### Changed
- Code formatting improvements across the codebase to comply with Dart style guidelines
- Improved readability with better line formatting in `NativeVideoPlayerController`

## [0.2.6] - 2025-10-23

### Fixed
- **Critical Controller Disposal Bug**: Fixed incomplete resource cleanup in `NativeVideoPlayerController.dispose()` method
  - Added proper cleanup of PiP event subscription (Android global listener)
  - Added cleanup of AirPlay listeners (availability and connection handlers)
  - Added cleanup of platform view contexts map
  - Added cleanup of overlay builder and fullscreen callback references
  - Fixed memory leaks by ensuring all event handlers and subscriptions are properly cancelled

- **Android Player Reinitialization Issue**: Fixed critical bug where Android players could not be reinitialized after disposal
  - Fixed `VideoPlayerMethodHandler.handleDispose()` to properly remove player from `SharedPlayerManager`
  - Added `controllerId` parameter to `VideoPlayerMethodHandler` constructor
  - Now properly releases ExoPlayer, notification handler, and clears PiP settings on disposal
  - Android players can now be disposed and recreated just like iOS players

### Changed
- Enhanced `VideoPlayerMethodChannel` with new `dispose()` method that calls native platform disposal
- Updated Flutter controller `dispose()` to call native cleanup via method channel
- Improved disposal flow to ensure both Flutter and native resources are properly cleaned up

### Documentation
- Updated `dispose()` method documentation to reflect proper disposal of both Flutter and native platform resources

## [0.2.5] - 2025-10-23

### Improved
- **Android Media Info Management**: Refactored VideoPlayerNotificationHandler and VideoPlayerObserver for improved media information management
  - Enhanced media session and notification updates to occur consistently when playback starts
  - Improved user experience in both normal playback and Picture-in-Picture modes
  - Cleaned up code for better readability and maintainability
  - Enhanced logging for better debugging capabilities

## [0.2.4] - 2025-10-23

### Fixed
- **iOS Automatic Picture-in-Picture for Shared Controllers**: Fixed critical issue where automatic PiP would not work correctly when multiple views share the same controller (e.g., list view + detail view scenario)
  - Fixed race condition where multiple views observing the same shared player would compete for PiP control
  - Added primary view tracking to ensure only the most recently active view can trigger automatic PiP
  - Fixed automatic PiP not working for videos started with native controls (non-programmatic playback)
  - Improved SharedPlayerManager to properly handle PiP state transfers between views with the same controller ID
  - Added `isPrimaryView()` and `getPrimaryViewId()` methods to prevent observer conflicts

### Changed
- Enhanced observer logic to detect when playback starts via native controls and automatically set the view as primary
- Improved logging for debugging PiP state transitions across multiple views

## [0.2.3] - 2025-10-21

### Fixed
- Fixed Dart formatting issues in `native_video_player_controller.dart` and `fullscreen_manager.dart` to comply with pub.dev static analysis requirements

## [0.2.2] - 2025-10-21

### Added
- WASM compatibility: Package now supports Web Assembly (WASM) runtime
  - Implemented conditional imports using `dart:io` only on native platforms
  - Added `PlatformUtils` class for platform detection without direct `dart:io` dependency
  - Exported `PlatformUtils` for users who need platform-agnostic code

### Changed
- Replaced direct `Platform` checks with `PlatformUtils` in fullscreen manager and controller
- Code formatting improvements across all files

## [0.2.1] - 2025-10-21

### Fixed
- Updated iOS podspec version to match package version (0.2.1)

## [0.2.0] - 2025-10-21

### Added
- **AirPlay Support (iOS)**: Complete AirPlay integration for streaming to Apple TV and AirPlay-enabled devices
  - `isAirPlayAvailable()` method to check for available AirPlay devices
  - `showAirPlayPicker()` method to display native AirPlay device picker
  - `addAirPlayAvailabilityListener()` to monitor when AirPlay devices become available/unavailable
  - `addAirPlayConnectionListener()` to track AirPlay connection state changes
  - Automatic detection of AirPlay-enabled devices on the network
  - Support for streaming video to multiple AirPlay receivers

- **Custom Overlay Controls**: Build your own video player UI on top of the native player
  - New `overlayBuilder` parameter in `NativeVideoPlayer` widget
  - Full access to controller state for custom UI implementations
  - Allows building custom controls while maintaining native video decoding performance
  - Example implementation in `example/lib/widgets/custom_video_overlay.dart` with:
    - Play/pause control
    - Progress slider with buffered position indicator
    - Speed controls (0.25x - 2.0x)
    - Quality selector for HLS streams
    - Fullscreen toggle
    - Volume control
    - AirPlay button (iOS)
    - Auto-hide functionality

- **Dart-side Fullscreen Management**: New `FullscreenManager` class for Flutter-based fullscreen
  - `FullscreenVideoPlayer` widget for fullscreen video playback in a Flutter overlay
  - `enterFullscreen()` and `exitFullscreen()` methods
  - System UI management (hide/show status bar and navigation bar)
  - Device orientation locking options
  - Fullscreen dialog helper for easy integration
  - Works alongside native fullscreen for maximum flexibility

- **Buffered Position Tracking**: Real-time buffered position updates
  - New `bufferedPosition` property in controller
  - Included in `timeUpdated` control events
  - Enables showing how much video has been preloaded
  - Perfect for showing secondary progress indicator in custom overlays

### Improved
- Enhanced controller state management with better activity and control state tracking
- Improved fullscreen state synchronization between native and Dart layers
- Better event listener management with separate activity and control listeners
- Enhanced example app with new `video_with_overlay_screen.dart` demonstrating custom controls
- Improved documentation with comprehensive AirPlay and custom overlay usage examples
- Better error handling and state validation throughout the player lifecycle

### Documentation
- Updated README with comprehensive sections on AirPlay and custom overlays
- Added example code for all new features

## [0.1.4] - 2025-10-20

### Fixed
- Fixed Dart SDK constraint to use proper version range (>=3.9.0 <4.0.0) instead of exact version, allowing compatibility with all Dart 3.9.x and 3.x versions

## [0.1.3] - 2025-10-20

### Fixed
- Fixed fullscreen exit handling on iOS when user dismisses by swiping down or tapping Done button
- Fixed iOS playback state preservation when exiting fullscreen (video now resumes playing if it was playing before)
- Fixed Android fullscreen button icon synchronization when fullscreen is toggled from Flutter code
- Fixed fullscreen event parsing to properly distinguish between entering and exiting fullscreen states
- Fixed shared player state synchronization by sending current playback state when new views attach

### Improved
- Standardized event naming by renaming `videoLoaded` to `loaded` across all platforms for consistency
- Enhanced Android fullscreen button to detect and correct icon desynchronization
- Improved shared player initial state callback mechanism to properly communicate loaded state with duration
- Better fullscreen state event notifications on Android with proper `isFullscreen` data
- Enhanced iOS fullscreen delegate handling with playback state restoration

## [0.1.2] - 2025-01-16

### Fixed
- Fixed iOS player state tracking by observing `timeControlStatus` instead of relying only on item observers
- Fixed shared player initialization to properly handle existing players vs new players
- Fixed Android PiP event channel setup to only initialize on Android platform (prevents iOS errors)
- Fixed playback state synchronization when connecting to shared players
- Fixed unnecessary buffering/loading events for shared players during reattachment

### Improved
- Enhanced iOS player observer to distinguish between play/pause and buffering states
- Improved shared player management with better state tracking and event handling
- Enhanced Android player controls by hiding unnecessary buttons (next, previous, settings)
- Better error handling and logging throughout the player lifecycle

## [0.1.1] - 2025-10-20

### Fixed
- Fixed Android package name to match plugin name (com.huddlecommunity.better_native_video_player)
- Fixed plugin registration in Android

## [0.1.0] - 2025-10-20

### Changed
- Updated Flutter SDK constraint to 3.9.2
- Updated flutter_lints to 6.0.0

## [0.0.1] - 2025-01-16

### Added
- Initial release of native_video_player plugin
- Native video playback using AVPlayerViewController (iOS) and ExoPlayer/Media3 (Android)
- HLS streaming support with adaptive quality selection
- Picture-in-Picture (PiP) mode on both platforms
- Native fullscreen playback
- Now Playing integration (Control Center on iOS, lock screen on Android)
- Background playback with media notifications
- Comprehensive playback controls:
  - Play/pause
  - Seek to position
  - Volume control
  - Playback speed adjustment (0.5x to 2.0x)
  - Quality selection for HLS streams
- Event streaming for player state changes
- Support for custom media info (title, subtitle, album, artwork)
- Configurable PiP behavior
- Native player controls toggle
- Example app demonstrating all features
- Comprehensive documentation and API reference

### Platform Support
- iOS 12.0+
- Android API 24+ (Android 7.0+)

### Dependencies
- Flutter SDK ^3.9.2
- iOS: AVFoundation framework
- Android: androidx.media3 1.5.0 (ExoPlayer, HLS, Session)

[0.0.1]: https://github.com/DaniKemper010/native-video-player/releases/tag/v0.0.1

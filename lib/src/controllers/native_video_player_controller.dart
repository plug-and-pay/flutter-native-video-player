import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../config/native_video_player_config.dart';
import '../enums/native_video_player_event.dart';
import '../fullscreen/fullscreen_hero_transition.dart';
import '../fullscreen/fullscreen_manager.dart';
import '../fullscreen/fullscreen_video_player.dart';
import '../chapters/native_video_player_chapters.dart';
import '../models/native_video_player_audio_track.dart';
import '../models/native_video_player_chapter.dart';
import '../models/native_video_player_media_info.dart';
import '../models/native_video_player_playback_range.dart';
import '../models/native_video_player_quality.dart';
import '../models/native_video_player_sidecar_subtitle.dart';
import '../models/native_video_player_state.dart';
import '../models/native_video_player_subtitle_style.dart';
import '../models/native_video_player_subtitle_track.dart';
import '../models/native_video_player_video_size.dart';
import '../platform/native_event_subscription.dart';
import '../platform/platform_utils.dart';
import '../platform/android_picture_in_picture.dart';
import '../platform/pip_restore.dart';
import '../platform/video_player_method_channel.dart';
import '../platform/view_visibility.dart';
import '../services/airplay_state_manager.dart';
import '../services/playback_coordinator.dart';
import '../subtitles/sidecar_subtitle_engine.dart';

part 'native_video_player_controller_events.dart';

/// Controller for managing native video player via platform channels
///
/// This controller bridges Flutter and native AVPlayerViewController using
/// MethodChannel for commands and EventChannel for state updates.
///
/// **Usage:**
/// ```dart
/// final controller = NativeVideoPlayerController(
///   id: videoId,
///   autoPlay: true,
///   preferredOrientations: [DeviceOrientation.portraitUp], // Optional
/// );
/// await controller.load(url: 'https://example.com/video.m3u8');
/// ```
///
/// **Orientation Control:**
/// The `preferredOrientations` parameter allows you to specify which device
/// orientations are allowed in your app. When exiting fullscreen, the player
/// will automatically restore these orientations. If not specified, all
/// orientations are allowed by default.
///
/// **Platform Communication:**
/// - MethodChannel: Flutter → Native (play, pause, seek, etc.)
/// - EventChannel: Native → Flutter (state changes, errors, buffering)
class NativeVideoPlayerController {
  NativeVideoPlayerController({
    required this.id,
    this.autoPlay = false,
    this.mediaInfo,
    this.allowsPictureInPicture = true,
    this.canStartPictureInPictureAutomatically = true,
    this.lockToLandscape = true,
    this.enableHDR = true,
    this.enableLooping = false,
    this.mixWithOthers = false,
    this.showNativeControls = true,
    this.preventFullscreenSwipeDismiss = true,
    this.fullscreenFlightBorderRadius = BorderRadius.zero,
    List<DeviceOrientation>? preferredOrientations,
  }) {
    // Set preferred orientations if provided
    if (preferredOrientations != null) {
      FullscreenManager.setPreferredOrientations(preferredOrientations);
    }

    // Set up app lifecycle listener for Android to hide overlay before PiP
    if (!kIsWeb && Platform.isAndroid) {
      WidgetsBinding.instance.addObserver(_AppLifecycleObserver(this));
    }

    // Set up controller-level event channel for persistent events (PiP, AirPlay)
    _controllerChannelSetupFuture = _setupControllerEventChannel();

    // iOS waits for an answer before the PiP window flies back.
    PipRestore.ensureListening();
  }

  /// Initialize the controller and wait for the platform view to be created
  Future<void> initialize() async {
    if (_isInitialized) {
      return;
    }

    // If already initializing, wait for the existing initialization to complete
    if (_isInitializing && _initializeCompleter != null) {
      await _initializeCompleter!.future;
      return;
    }

    // If platform view is already created and method channel exists, mark as initialized immediately
    if (_methodChannel != null && _platformViewIds.isNotEmpty) {
      _isInitialized = true;
      _updateState(
        _state.copyWith(activityState: PlayerActivityState.initialized),
      );
      return;
    }

    // Mark as initializing
    _isInitializing = true;

    // Set state to initializing immediately
    _updateState(
      _state.copyWith(activityState: PlayerActivityState.initializing),
    );

    // Create a completer that will be completed when the platform view is created
    _initializeCompleter = Completer<void>();

    // Wait for the platform view to be created
    await _initializeCompleter!.future;

    // Mark as initialized
    _isInitialized = true;
    _isInitializing = false;

    _updateState(
      _state.copyWith(activityState: PlayerActivityState.initialized),
    );
  }

  /// Unique identifier for this video player instance
  final int id;

  /// Whether to start playing automatically when initialized
  final bool autoPlay;

  /// Whether to lock orientation to landscape in fullscreen mode
  final bool lockToLandscape;

  /// Optional media information (title, subtitle, artwork) for Now Playing display
  final NativeVideoPlayerMediaInfo? mediaInfo;

  /// Whether Picture-in-Picture mode is allowed
  final bool allowsPictureInPicture;

  /// Whether PiP can start automatically when app goes to background (iOS 14.2+)
  final bool canStartPictureInPictureAutomatically;

  /// Whether to enable HDR playback (default: false)
  /// When set to false, HDR is disabled to prevent washed-out/too-white video appearance
  final bool enableHDR;

  /// Whether to enable video looping (default: false)
  /// When set to true, the video will automatically restart from the beginning when it reaches the end
  final bool enableLooping;

  /// Whether this player's audio mixes with other apps' audio (default: false)
  ///
  /// By default playing a video interrupts music or a podcast from another
  /// app, even a muted one: iOS takes a non-mixable audio session and Android
  /// requests audio focus. Set to true for muted feed tiles and decorative
  /// background loops: on iOS the session gets `mixWithOthers`, on Android
  /// the player never requests audio focus. A mixing player stays off the
  /// lock screen, Control Center and the media notification, and doesn't
  /// take automatic Picture-in-Picture. While a player that doesn't mix
  /// plays, a mixing one leaves the session to it.
  final bool mixWithOthers;

  /// Whether to show native player controls (default: true)
  /// When set to false, native controls are hidden. Custom overlays automatically hide native controls regardless of this setting.
  final bool showNativeControls;

  /// Whether swipe/pinch gestures are disabled in native iOS fullscreen
  /// (default: true)
  ///
  /// AVPlayerViewController's internal swipe-to-dismiss gesture can leave the
  /// inline player with a black screen; with this enabled, fullscreen can only
  /// be exited via the Done button. Set to false to restore the system swipe
  /// gesture. Has no effect on Android or on Dart-side (custom overlay)
  /// fullscreen.
  final bool preventFullscreenSwipeDismiss;

  /// Corners of the inline player the video flies from into Dart fullscreen
  /// and back into: the flight rounds them from this to square at full
  /// screen. Match it to the clip around your inline player (e.g. a card
  /// with rounded corners). Defaults to square.
  final BorderRadius fullscreenFlightBorderRadius;

  /// The view Dart fullscreen opens from, flies out of and lands back in:
  /// the one the user is looking at. With one controller on two screens (a
  /// feed tile and the post it opens) the earlier screen's view is still
  /// mounted under the page on top, so a view on the top route wins, then
  /// the most recently attached one. The fullscreen host itself never counts.
  BuildContext? get _fullscreenContext {
    final List<BuildContext> candidates = <BuildContext>[
      for (final int viewId in _platformViewIds.toList().reversed)
        if (!_fullscreenViewIds.contains(viewId))
          if (_platformViewContexts[viewId] case final BuildContext ctx?
              when ctx.mounted)
            ctx,
    ];
    for (final BuildContext ctx in candidates) {
      if (ViewVisibility.isOnTopRoute(ctx)) return ctx;
    }
    return candidates.isEmpty ? null : candidates.first;
  }

  /// The view [enterFullScreen] would use for Dart fullscreen and its flight.
  @visibleForTesting
  BuildContext? get debugFullscreenContext => _fullscreenContext;

  /// Map of platform view IDs to their contexts
  final Map<int, BuildContext> _platformViewContexts = <int, BuildContext>{};

  /// Per view: a snapshot of the Flutter layers it draws over the video
  /// (poster, controls), flown into fullscreen while there is no video frame.
  final Map<int, Future<Uint8List?> Function()> _viewSnapshots =
      <int, Future<Uint8List?> Function()>{};

  /// Internal: [NativeVideoPlayer] hands over how to snapshot its layers.
  void registerViewSnapshot(
    int platformViewId,
    Future<Uint8List?> Function() snapshot,
  ) {
    _viewSnapshots[platformViewId] = snapshot;
  }

  /// Whether the player has a video frame to fly: something was loaded and
  /// got past loading. An app that loads only on the first play has none
  /// before that, and the black video would fly as a black box.
  bool get _hasVideoFrame {
    final PlayerActivityState state = _state.activityState;
    return _url != null &&
        !state.isIdle &&
        !state.isInitializing &&
        !state.isInitialized &&
        !state.isLoading &&
        !state.hasError;
  }

  /// Internal: whether the player has a video frame to show (see
  /// [_hasVideoFrame]); without one, Dart fullscreen keeps the overlay (an
  /// app's thumbnail often lives there) while a swipe drags the page.
  bool get hasVideoFrame => _hasVideoFrame;

  /// Overlay builder to use in fullscreen mode
  /// This is passed from NativeVideoPlayer widget
  Widget Function(BuildContext, NativeVideoPlayerController)? _overlayBuilder;

  /// Sidecar subtitle style to use in fullscreen mode
  /// This is passed from the NativeVideoPlayer widget so the Dart fullscreen
  /// host renders captions identically to the inline player.
  NativeVideoPlayerSubtitleStyle? _subtitleStyle;

  /// Text-size scale for embedded (native-rendered) subtitle tracks.
  /// Cached so it can be re-applied when the native view is recreated
  /// (list→detail→back) or a new item is loaded. Issue #43.
  double _embeddedTextScale = 1.0;

  /// The subtitle track last requested via [setSubtitleTrack] for the current
  /// source (null = never chosen since load). Re-sent to the native side when
  /// a new platform view attaches (Dart fullscreen host, second inline view)
  /// so the app's choice — including "off" — survives the view's own
  /// attach-time media selection.
  NativeVideoPlayerSubtitleTrack? _lastSubtitleTrack;

  /// Callback to close the Dart fullscreen dialog
  /// Set by FullscreenVideoPlayer when it's created
  VoidCallback? _dartFullscreenCloseCallback;

  /// Whether the overlay visibility is locked (cannot be dismissed)
  bool _isOverlayLocked = false;

  /// Whether the overlay should be hidden during PiP transition
  /// This is set when Android requests fullscreen for PiP preparation
  bool _hideOverlayForPip = false;

  /// Whether we have a custom overlay (determines if we use Dart fullscreen and hide native controls)
  bool get _hasCustomOverlay => _overlayBuilder != null && !_hideOverlayForPip;

  /// Returns whether the overlay is currently locked (always visible), by
  /// [lockOverlay] or a [holdOverlay] that has not been released.
  bool get isOverlayLocked => _isOverlayLocked || _overlayHolds > 0;

  /// Open [holdOverlay]s.
  int _overlayHolds = 0;

  /// Emits [isOverlayLocked] when it changed from [wasLocked].
  void _emitOverlayLock(bool wasLocked) {
    final locked = isOverlayLocked;
    if (locked != wasLocked && !_isOverlayLockedController.isClosed) {
      _isOverlayLockedController.add(locked);
    }
  }

  /// Keeps the custom overlay visible (no auto-hide, no tap-to-hide) until
  /// the returned callback is called; the hide timer then starts over.
  ///
  /// Unlike [lockOverlay] this is counted and leaves your own lock alone,
  /// so a widget can hold the overlay for as long as it is being used.
  /// [NativeVideoPlayerProgressBar] does this while the viewer scrubs.
  /// Calling the release more than once does nothing.
  VoidCallback holdOverlay() {
    final wasLocked = isOverlayLocked;
    _overlayHolds++;
    _emitOverlayLock(wasLocked);
    var released = false;
    return () {
      if (released || _isDisposed) return;
      released = true;
      final wasLocked = isOverlayLocked;
      _overlayHolds--;
      _emitOverlayLock(wasLocked);
    };
  }

  /// Stream controller for overlay lock state changes
  final StreamController<bool> _isOverlayLockedController =
      StreamController<bool>.broadcast();

  /// Stream of overlay lock state changes
  Stream<bool> get isOverlayLockedStream => _isOverlayLockedController.stream;

  /// Current state of the video player
  NativeVideoPlayerState _state = const NativeVideoPlayerState();

  /// Video URL set when load() is called
  String? _url;

  /// Set when the native side evicted this controller's player under the iOS
  /// total-player LRU cap ([NativeVideoPlayerConfig.iosMaxTotalPlayers]). The
  /// next [play] transparently re-loads the last source at
  /// [_evictionResumePosition] instead of no-oping against the torn-down
  /// player (see [_reloadEvictedSource]).
  bool _needsReloadAfterEviction = false;

  /// Playback position captured natively just before eviction; restored by
  /// the eviction re-load.
  Duration _evictionResumePosition = Duration.zero;

  /// Headers and DRM config of the last [load] call, retained so an eviction
  /// re-load can replay the same request.
  Map<String, String>? _lastLoadHeaders;
  Map<String, dynamic>? _lastLoadDrmConfig;

  /// Method channel wrapper for platform communication
  VideoPlayerMethodChannel? _methodChannel;

  /// Android picture-in-picture (app-wide: the activity is the window)
  final AndroidPictureInPicture _androidPip = AndroidPictureInPicture.instance;

  /// Set of platform view IDs that are using this controller
  final Set<int> _platformViewIds = <int>{};

  /// Primary platform view ID (most recent one registered)
  int? _primaryPlatformViewId;

  /// Updates the method channel to use the specified platform view ID
  void _updateMethodChannel(int platformViewId) {
    // Unregister old method channel from AirPlay manager
    if (_methodChannel != null) {
      AirPlayStateManager.instance.unregisterMethodChannel(_methodChannel!);
    }

    _primaryPlatformViewId = platformViewId;
    _methodChannel = VideoPlayerMethodChannel(
      primaryPlatformViewId: platformViewId,
      controllerId: id,
    );

    // Register new method channel with AirPlay manager
    AirPlayStateManager.instance.registerMethodChannel(_methodChannel!);
  }

  /// Completer to wait for initialization to complete
  Completer<void>? _initializeCompleter;

  /// Flag to track if the controller has been initialized
  bool _isInitialized = false;

  /// Flag to track if initialization is currently in progress
  bool _isInitializing = false;

  /// Flag to track if the controller has been disposed
  bool _isDisposed = false;

  /// Event channel subscriptions for each platform view
  final Map<int, NativeEventSubscription> _eventSubscriptions =
      <int, NativeEventSubscription>{};

  /// MainActivity PiP event channel subscription (Android only).
  ///
  /// Always null: the native `native_video_player_pip_events` channel was
  /// never implemented and its dead Dart-side listener has been removed. The
  /// field and getter are kept only because the getter is public API.
  StreamSubscription<dynamic>? _pipEventSubscription;

  /// MainActivity PiP event channel subscription (Android only)
  StreamSubscription<dynamic>? get pipEventSubscription =>
      _pipEventSubscription;

  /// Controller-level event channel (persistent, independent of platform
  /// views; PiP, AirPlay and eviction events), shared with every other live
  /// controller that has the same [id].
  _SharedControllerEventChannel? _sharedControllerEventChannel;

  /// The shared plugin method channel, available from plugin registration
  /// (before any platform view exists). Used for controller-scoped calls
  /// that don't go through a per-view method channel.
  static const MethodChannel _pluginMethodChannel = MethodChannel(
    'native_video_player',
  );

  /// Delays between retries when asking the native side to register the
  /// controller event channel handler. The plugin may not be attached yet
  /// during a cold start or right after a hot restart.
  @visibleForTesting
  static List<Duration> controllerChannelRetryDelays = const [
    Duration(milliseconds: 50),
    Duration(milliseconds: 200),
    Duration(seconds: 1),
  ];

  /// Completes when the constructor's controller-channel setup attempt has
  /// finished (whether or not it succeeded).
  Future<void>? _controllerChannelSetupFuture;

  /// The in-flight controller-channel setup, exposed for tests.
  @visibleForTesting
  Future<void>? get debugControllerChannelSetup =>
      _controllerChannelSetupFuture;

  /// Adapter through which the [PlaybackCoordinator] sees this controller
  /// (cap enforcement for [NativeVideoPlayerConfig.maxConcurrentPlayingPlayers]).
  late final PlayableHandle _playableHandle = _ControllerPlayableHandle(this);

  /// Engine for sidecar (external VTT/SRT) subtitles: loads, parses and
  /// time-syncs cues for the Flutter subtitle overlay. Survives
  /// releaseResources() (sources/cues persist for reattachment); disposed
  /// with the controller.
  final SidecarSubtitleEngine _sidecarSubtitles = SidecarSubtitleEngine();

  /// Active sidecar subtitle cue lines at the current playback position.
  /// The [NativeVideoPlayer] widget's subtitle overlay listens to this;
  /// custom overlays can too.
  ValueListenable<List<String>> get activeSidecarCueLines =>
      _sidecarSubtitles.activeCueLines;

  /// Whether a sidecar subtitle track is currently selected.
  bool get hasSidecarSubtitleSelected =>
      _sidecarSubtitles.selectedSource != null;

  /// Timer for buffering state debounce (400ms)
  Timer? _bufferingDebounceTimer;

  /// Watchdog bounding how long the player may sit in a load-pipeline state
  /// (initializing/loading). A stalled native pipeline emits no event at all
  /// — Android's ExoPlayer listener only reports STATE_READY ('loaded') or
  /// onPlayerError ('error') — so without this the Dart state stays loading
  /// forever and the UI shows an infinite spinner. Configured via
  /// [NativeVideoPlayerConfig.loadTimeout]; on expiry the stall is surfaced
  /// as a regular error event (see [_onWatchdogExpired]).
  Timer? _loadWatchdogTimer;

  /// Watchdog bounding how long the player may stay buffering. Opt-in via
  /// [NativeVideoPlayerConfig.bufferingTimeout] (null = disabled, the
  /// default); same expiry behavior as [_loadWatchdogTimer].
  Timer? _bufferingWatchdogTimer;

  /// Polls Android PiP state while fullscreen. Android has no native PiP
  /// enter/exit callback to plugins (unlike iOS), so we poll the cheap
  /// one-shot status to keep [isPipEnabled] accurate.
  Timer? _androidPipPollTimer;

  /// Track if we're currently in a buffering state (from native)
  bool _isCurrentlyBuffering = false;

  /// Track the last non-buffering activity state to restore after buffering
  PlayerActivityState? _lastNonBufferingState;

  /// Whether native reported `play` since the current [load] started, so
  /// [load] does not overwrite an autoplay `playing` with `loaded`.
  bool _playReportedDuringLoad = false;

  /// Activity event handlers (play, pause, buffering, etc.)
  final List<void Function(PlayerActivityEvent)> _activityEventHandlers =
      <void Function(PlayerActivityEvent)>[];

  /// Control event handlers (quality, speed, pip, fullscreen, etc.)
  final List<void Function(PlayerControlEvent)> _controlEventHandlers =
      <void Function(PlayerControlEvent)>[];

  /// Stream controllers for individual property streams
  final StreamController<Duration> _bufferedPositionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<PlayerActivityState> _playerStateController =
      StreamController<PlayerActivityState>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<double> _speedController =
      StreamController<double>.broadcast();
  final StreamController<bool> _isPipEnabledController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _isPipAvailableController =
      StreamController<bool>.broadcast();

  /// Latest native video dimensions (texture-rendered views report these so
  /// the widget can letterbox the texture; platform views handle aspect
  /// natively and may never emit one).
  NativeVideoPlayerVideoSize? _videoSize;
  final StreamController<NativeVideoPlayerVideoSize> _videoSizeController =
      StreamController<NativeVideoPlayerVideoSize>.broadcast();

  /// Platform-view IDs that are actually texture-rendered backends (no
  /// Android/iOS view exists for them). Drives the Dart-fullscreen fallback.
  final Set<int> _textureViewIds = <int>{};

  /// Platform-view IDs hosted by the Dart fullscreen route.
  final Set<int> _fullscreenViewIds = <int>{};

  /// Completes once the last Dart fullscreen view is disposed, for
  /// [_waitForClosingFullscreenViews].
  Completer<void>? _fullscreenViewsDisposed;

  /// Whether the active fullscreen session went through the Dart path (so
  /// exit uses the matching path even without a custom overlay).
  bool _usedDartFullscreen = false;

  /// Internal: asks the mounted widget to swap a texture-rendered tile to a
  /// platform view (iOS manual-PiP path — PiP needs an on-screen
  /// AVPlayerLayer). The widget completes the completer once the platform
  /// view took over and the texture half is disposed.
  final StreamController<Completer<bool>> _surfaceSwapRequests =
      StreamController<Completer<bool>>.broadcast();

  /// Internal: listened to by [NativeVideoPlayer] widgets in texture mode.
  Stream<Completer<bool>> get surfaceSwapRequests =>
      _surfaceSwapRequests.stream;

  Future<bool> _requestSurfaceSwap() async {
    if (!_surfaceSwapRequests.hasListener) {
      debugPrint('Surface swap requested but no widget is listening');
      return false;
    }
    final completer = Completer<bool>();
    _surfaceSwapRequests.add(completer);
    try {
      return await completer.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      debugPrint('Surface swap timed out');
      return false;
    }
  }

  final StreamController<bool> _isFullscreenController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _isLiveController =
      StreamController<bool>.broadcast();
  final StreamController<NativeVideoPlayerQuality> _qualityChangedController =
      StreamController<NativeVideoPlayerQuality>.broadcast();
  final StreamController<List<NativeVideoPlayerQuality>> _qualitiesController =
      StreamController<List<NativeVideoPlayerQuality>>.broadcast();
  final StreamController<List<NativeVideoPlayerChapter>> _chaptersController =
      StreamController<List<NativeVideoPlayerChapter>>.broadcast();
  final StreamController<NativeVideoPlayerChapter?> _currentChapterController =
      StreamController<NativeVideoPlayerChapter?>.broadcast();

  /// Updates the internal state
  void _updateState(NativeVideoPlayerState newState) {
    final oldState = _state;
    _state = newState;

    // Don't emit events if the controller is disposed
    if (_isDisposed) {
      return;
    }

    // Emit to individual streams when values change
    if (oldState.bufferedPosition != newState.bufferedPosition) {
      if (!_bufferedPositionController.isClosed) {
        _bufferedPositionController.add(newState.bufferedPosition);
      }
    }
    if (oldState.duration != newState.duration) {
      if (!_durationController.isClosed) {
        _durationController.add(newState.duration);
      }

      // When duration changes from 0 to non-zero, notify all listeners with current state
      // This ensures listeners added before duration was available receive the state
      if (oldState.duration == Duration.zero &&
          newState.duration != Duration.zero) {
        // Notify all control listeners with time update event
        if (_controlEventHandlers.isNotEmpty) {
          final currentControlEvent = PlayerControlEvent(
            state: PlayerControlState.timeUpdated,
            data: {
              'position': newState.currentPosition.inMilliseconds,
              'duration': newState.duration.inMilliseconds,
              'bufferedPosition': newState.bufferedPosition.inMilliseconds,
              'isBuffering':
                  newState.activityState == PlayerActivityState.buffering,
            },
          );
          for (final handler in _controlEventHandlers) {
            handler(currentControlEvent);
          }
        }

        // Also notify activity listeners
        if (_activityEventHandlers.isNotEmpty) {
          final currentActivityEvent = PlayerActivityEvent(
            state: newState.activityState,
            data: null,
          );
          for (final handler in _activityEventHandlers) {
            handler(currentActivityEvent);
          }
        }
      }
    }
    if (oldState.activityState != newState.activityState) {
      if (!_playerStateController.isClosed) {
        _playerStateController.add(newState.activityState);
      }

      // Report playing-state TRANSITIONS to the playback coordinator (cap
      // enforcement). Transitions — not play() calls — also catch playback
      // started natively (native controls, remote commands, autoplay).
      final bool wasPlaying =
          oldState.activityState == PlayerActivityState.playing;
      final bool isPlaying =
          newState.activityState == PlayerActivityState.playing;
      if (!wasPlaying && isPlaying) {
        PlaybackCoordinator.instance.onPlaying(_playableHandle);
      } else if (wasPlaying && !isPlaying) {
        PlaybackCoordinator.instance.onStoppedPlaying(_playableHandle);
      }
      if (wasPlaying != isPlaying) {
        _sidecarSubtitles.onPlayingChanged(isPlaying);
      }

      // Re-evaluate the stalled-playback watchdogs on every activity-state
      // transition: arm while spinning up / buffering, disarm on any state
      // that proves the pipeline made progress.
      _updateWatchdogs(newState.activityState);
    }
    // Hand sidecar caption rendering to the native SubtitleView while the
    // Flutter overlay is invisible (Android PiP / native fullscreen) and
    // take it back when inline again.
    if (oldState.isPipEnabled != newState.isPipEnabled ||
        oldState.isFullScreen != newState.isFullScreen) {
      _syncNativeSidecarCaptions(newState);
    }
    if (oldState.isFullScreen != newState.isFullScreen) {
      // Start/stop polling Android PiP state (PiP is only reachable from
      // fullscreen on Android).
      _updateAndroidPipPolling(newState);
    }
    if (oldState.currentPosition != newState.currentPosition) {
      if (!_positionController.isClosed) {
        _positionController.add(newState.currentPosition);
      }
      // Re-anchor the sidecar subtitle engine's cue timing.
      _sidecarSubtitles.onPosition(newState.currentPosition);
      _enforcePlaybackRange(newState.currentPosition);
    }
    if (oldState.speed != newState.speed) {
      if (!_speedController.isClosed) {
        _speedController.add(newState.speed);
      }
      _sidecarSubtitles.onSpeedChanged(newState.speed);
    }
    if (oldState.isPipEnabled != newState.isPipEnabled) {
      // Suppress oversized native captions while in Android PiP; restore on exit.
      _suppressSubtitlesForPip(newState.isPipEnabled);
      if (!_isPipEnabledController.isClosed) {
        _isPipEnabledController.add(newState.isPipEnabled);
      }
    }
    if (oldState.isPipAvailable != newState.isPipAvailable) {
      if (!_isPipAvailableController.isClosed) {
        _isPipAvailableController.add(newState.isPipAvailable);
      }
    }
    // Note: AirPlay state changes are now handled by the global AirPlayStateManager
    // The streams are provided by the manager, not by individual controllers
    if (oldState.isFullScreen != newState.isFullScreen) {
      if (!_isFullscreenController.isClosed) {
        _isFullscreenController.add(newState.isFullScreen);
      }
    }
    if (oldState.qualities != newState.qualities) {
      if (!_qualitiesController.isClosed) {
        _qualitiesController.add(newState.qualities);
      }
    }
    if (oldState.isLive != newState.isLive) {
      if (!_isLiveController.isClosed) {
        _isLiveController.add(newState.isLive);
      }
      // Chapters are hidden for live streams.
      if (_chapters.isNotEmpty) _emitChapters();
    }
    if (oldState.currentPosition != newState.currentPosition ||
        oldState.isLive != newState.isLive) {
      _updateCurrentChapter();
    }
  }

  /// Handles buffering state changes with 400ms debounce
  ///
  /// Only emits buffering state if it persists for more than 400ms.
  /// This prevents flickering for brief buffering periods.
  void _handleBufferingStateChange(bool isBuffering) {
    // Track the native buffering state
    _isCurrentlyBuffering = isBuffering;

    if (isBuffering) {
      // Store the current non-buffering state before transitioning to buffering
      if (_state.activityState != PlayerActivityState.buffering) {
        _lastNonBufferingState = _state.activityState;
      }

      // Cancel any existing timer
      _bufferingDebounceTimer?.cancel();

      // Start a 400ms timer - only emit buffering state if still buffering after 400ms
      _bufferingDebounceTimer = Timer(const Duration(milliseconds: 400), () {
        // A seek on a playing video holds this too (see _seekHoldTimer): it
        // applies once the hold runs out without the video playing on.
        if (_isCurrentlyBuffering && _seekHoldTimer != null) {
          _heldSeekEvent ??= <String, Object?>{'event': 'buffering'};
          return;
        }
        // Check if we're still buffering after 400ms
        if (_isCurrentlyBuffering &&
            _state.activityState != PlayerActivityState.buffering &&
            !_keepsCurrentState(PlayerActivityState.buffering)) {
          // Update to buffering state
          _updateState(
            _state.copyWith(activityState: PlayerActivityState.buffering),
          );
        }
      });
    } else {
      // Buffering stopped - cancel the timer and restore previous state
      _bufferingDebounceTimer?.cancel();
      if (_heldSeekEvent?['event'] == 'buffering') _heldSeekEvent = null;

      // If we were showing buffering state, restore the previous state
      if (_state.activityState == PlayerActivityState.buffering) {
        // Restore the last non-buffering state
        final restoredState =
            _lastNonBufferingState ?? PlayerActivityState.playing;
        _updateState(_state.copyWith(activityState: restoredState));
      }
    }
  }

  /// Arms/disarms the stalled-playback watchdogs for [state].
  ///
  /// Called on every activity-state transition:
  /// - The load watchdog is (re-)armed while the pipeline is spinning up
  ///   (initializing/loading) and cancelled on every other state — reaching
  ///   initialized/loaded/playing/paused/buffering/completed/stopped, a real
  ///   native error, or idle all prove the pipeline responded.
  /// - The buffering watchdog is armed on buffering (only when
  ///   [NativeVideoPlayerConfig.bufferingTimeout] is set) and cancelled on
  ///   any other state.
  ///
  /// Re-entering an armed state restarts its timer, so each stage of a
  /// multi-step spin-up (initializing → loading) gets a fresh budget.
  void _updateWatchdogs(PlayerActivityState state) {
    _loadWatchdogTimer?.cancel();
    _loadWatchdogTimer = null;
    final Duration? loadTimeout = NativeVideoPlayerConfig.global.loadTimeout;
    if (loadTimeout != null &&
        (state == PlayerActivityState.initializing ||
            state == PlayerActivityState.loading)) {
      _loadWatchdogTimer = Timer(
        loadTimeout,
        () => _onWatchdogExpired(loadTimeout, isBufferingWatchdog: false),
      );
    }

    _bufferingWatchdogTimer?.cancel();
    _bufferingWatchdogTimer = null;
    final Duration? bufferingTimeout =
        NativeVideoPlayerConfig.global.bufferingTimeout;
    if (bufferingTimeout != null && state == PlayerActivityState.buffering) {
      _bufferingWatchdogTimer = Timer(
        bufferingTimeout,
        () => _onWatchdogExpired(bufferingTimeout, isBufferingWatchdog: true),
      );
    }
  }

  /// Cancels both stalled-playback watchdogs (release/dispose paths).
  void _cancelWatchdogs() {
    _loadWatchdogTimer?.cancel();
    _loadWatchdogTimer = null;
    _bufferingWatchdogTimer?.cancel();
    _bufferingWatchdogTimer = null;
  }

  /// Fires when a stalled-playback watchdog expires: surfaces the stall as a
  /// regular player error.
  ///
  /// Synthesizes the exact event shape a real native error produces — the
  /// native sides emit `{'event': 'error', 'message': ...}` which the event
  /// channel listener turns into a [PlayerActivityEvent] with
  /// [PlayerActivityState.error], updates the state, and hands to the
  /// activity listeners — so app listeners can't tell a timeout apart from
  /// any other playback failure. Afterwards the pipeline is best-effort
  /// paused to stop a wedged decoder/network stack from spinning.
  void _onWatchdogExpired(
    Duration timeout, {
    required bool isBufferingWatchdog,
  }) {
    if (_isDisposed) {
      return;
    }

    // A state transition would have cancelled the timer, but guard against
    // a fire that raced the cancel.
    final PlayerActivityState current = _state.activityState;
    final bool stillStalled = isBufferingWatchdog
        ? current == PlayerActivityState.buffering
        : current == PlayerActivityState.initializing ||
              current == PlayerActivityState.loading;
    if (!stillStalled) {
      return;
    }

    final String timeoutLabel = timeout.inSeconds >= 1
        ? '${timeout.inSeconds}s'
        : '${timeout.inMilliseconds}ms';
    final String message = isBufferingWatchdog
        ? 'Buffering timed out after $timeoutLabel'
        : 'Load timed out after $timeoutLabel';
    debugPrint('Stalled-playback watchdog fired for controller $id: $message');

    // Same wire shape as a native error event, parsed by the same factory.
    final activityEvent = PlayerActivityEvent.fromMap(<dynamic, dynamic>{
      'event': 'error',
      'message': message,
    });

    _updateState(_state.copyWith(activityState: activityEvent.state));

    for (final handler in _activityEventHandlers) {
      handler(activityEvent);
    }

    // Best-effort quiesce; no-ops when no platform view provides a method
    // channel yet (e.g. a stall during initialize()).
    unawaited(
      pause().catchError((Object e) {
        debugPrint('Watchdog pause failed for controller $id: $e');
      }),
    );
  }

  /// Emits the current state to all streams
  ///
  /// This is useful when reconnecting after releaseResources() to ensure
  /// new listeners receive the current state even though it hasn't changed.
  void _emitCurrentState() {
    if (_isDisposed) {
      return;
    }

    if (!_bufferedPositionController.isClosed) {
      _bufferedPositionController.add(_state.bufferedPosition);
    }
    if (!_durationController.isClosed) {
      _durationController.add(_state.duration);
    }
    if (!_playerStateController.isClosed) {
      _playerStateController.add(_state.activityState);
    }
    if (!_positionController.isClosed) {
      _positionController.add(_state.currentPosition);
    }
    if (!_speedController.isClosed) {
      _speedController.add(_state.speed);
    }
    if (!_isPipEnabledController.isClosed) {
      _isPipEnabledController.add(_state.isPipEnabled);
    }
    if (!_isPipAvailableController.isClosed) {
      _isPipAvailableController.add(_state.isPipAvailable);
    }
    // Note: AirPlay state is now managed globally by AirPlayStateManager
    if (!_isFullscreenController.isClosed) {
      _isFullscreenController.add(_state.isFullScreen);
    }
    if (!_qualitiesController.isClosed && _state.qualities.isNotEmpty) {
      _qualitiesController.add(_state.qualities);
    }
    if (!_isLiveController.isClosed) {
      _isLiveController.add(_state.isLive);
    }
  }

  /// Emits the current state to all listeners
  ///
  /// This method broadcasts the current player state to all registered listeners:
  /// - All stream controllers (position, duration, buffered position, etc.)
  /// - Activity event handlers
  /// - Control event handlers
  /// - AirPlay availability handlers
  /// - AirPlay connection handlers
  /// - Overlay lock state listeners
  ///
  /// This is useful when you need to ensure all listeners are updated with
  /// the current state, for example after dynamically adding new listeners
  /// or when synchronizing external UI components.
  ///
  /// **Usage:**
  /// ```dart
  /// // Ensure all listeners receive the current state
  /// controller.emitCurrentStateToAllListeners();
  /// ```
  void emitCurrentStateToAllListeners() {
    if (_isDisposed) {
      return;
    }

    // Emit to all stream controllers
    _emitCurrentState();

    // Emit to activity event handlers
    if (_activityEventHandlers.isNotEmpty) {
      final activityEvent = PlayerActivityEvent(
        state: _state.activityState,
        data: null,
      );
      for (final handler in _activityEventHandlers) {
        handler(activityEvent);
      }
    }

    // Emit to control event handlers with time update event
    if (_controlEventHandlers.isNotEmpty) {
      final controlEvent = PlayerControlEvent(
        state: PlayerControlState.timeUpdated,
        data: {
          'position': _state.currentPosition.inMilliseconds,
          'duration': _state.duration.inMilliseconds,
          'bufferedPosition': _state.bufferedPosition.inMilliseconds,
          'isBuffering': _state.activityState == PlayerActivityState.buffering,
        },
      );
      for (final handler in _controlEventHandlers) {
        handler(controlEvent);
      }

      // Also emit quality information if available
      if (_state.qualities.isNotEmpty) {
        final qualityEvent = PlayerControlEvent(
          state: PlayerControlState.qualityChanged,
          data: {
            'qualities': _state.qualities.map((q) => q.toMap()).toList(),
            'quality': _state.qualities.first.toMap(),
          },
        );
        for (final handler in _controlEventHandlers) {
          handler(qualityEvent);
        }
      }

      // Emit current control state if not none
      if (_state.controlState != PlayerControlState.none) {
        final currentStateEvent = PlayerControlEvent(
          state: _state.controlState,
          data: null,
        );
        for (final handler in _controlEventHandlers) {
          handler(currentStateEvent);
        }
      }
    }

    // Emit to AirPlay availability handlers
    for (final handler in _airPlayAvailabilityHandlers) {
      handler(_state.isAirplayAvailable);
    }

    // Emit to AirPlay connection handlers
    for (final handler in _airPlayConnectionHandlers) {
      handler(_state.isAirplayConnected);
    }

    // Emit to overlay lock state listeners
    if (!_isOverlayLockedController.isClosed) {
      _isOverlayLockedController.add(isOverlayLocked);
    }
  }

  /// Refreshes availability flags and qualities from the native player
  ///
  /// Called when reconnecting after releaseResources() to ensure
  /// flags like PiP available, AirPlay available, and qualities are up to date
  Future<void> _refreshAvailabilityFlags() async {
    if (_methodChannel == null || _isDisposed) {
      return;
    }

    try {
      // Re-fetch PiP availability
      // isPictureInPictureAvailable() handles both Android and iOS
      final isPipAvailable = await isPictureInPictureAvailable();
      _state = _state.copyWith(isPipAvailable: isPipAvailable);
      if (!_isPipAvailableController.isClosed) {
        _isPipAvailableController.add(isPipAvailable);
      }

      // Re-fetch AirPlay availability (iOS only)
      final isAirplayAvailable = await _methodChannel!.isAirPlayAvailable();
      _state = _state.copyWith(isAirplayAvailable: isAirplayAvailable);
      // Update global AirPlay state manager
      AirPlayStateManager.instance.updateAvailability(isAirplayAvailable);

      // Re-fetch available qualities if video was loaded before
      // Even if current state isn't "loaded", we may have qualities cached from before
      if (_state.qualities.isNotEmpty) {
        // Emit cached qualities immediately
        if (!_qualitiesController.isClosed) {
          _qualitiesController.add(_state.qualities);
        }
      }

      // Also try to fetch fresh qualities from native side
      try {
        final qualities = await _methodChannel!.getAvailableQualities();
        if (qualities.isNotEmpty) {
          _state = _state.copyWith(qualities: qualities);
          if (!_qualitiesController.isClosed) {
            _qualitiesController.add(qualities);
          }
        }
      } catch (e) {
        // Silently handle errors
      }
    } catch (e) {
      // Silently handle errors
    }
  }

  /// Adds a listener for activity events (play, pause, buffering, etc.)
  void addActivityListener(void Function(PlayerActivityEvent) listener) {
    if (!_activityEventHandlers.contains(listener)) {
      _activityEventHandlers.add(listener);

      // Immediately notify the new listener of the current state
      // This ensures listeners added after initialization receive the current state
      // We check if we have valid state rather than just _isInitialized
      if (!_isDisposed && _state.duration != Duration.zero) {
        final currentActivityEvent = PlayerActivityEvent(
          state: _state.activityState,
          data: null,
        );
        listener(currentActivityEvent);
      }
    }
  }

  /// Removes a listener for activity events
  void removeActivityListener(void Function(PlayerActivityEvent) listener) =>
      _activityEventHandlers.remove(listener);

  /// Adds a listener for control events (quality, speed, pip, fullscreen, etc.)
  void addControlListener(void Function(PlayerControlEvent) listener) {
    if (!_controlEventHandlers.contains(listener)) {
      _controlEventHandlers.add(listener);

      // Immediately notify the new listener with a time update event containing current state
      // This ensures listeners added after initialization receive the current state
      // We check if we have valid state data (duration > 0) rather than just _isInitialized
      // because _isInitialized may be false temporarily during reconnection
      if (!_isDisposed && _state.duration != Duration.zero) {
        final currentControlEvent = PlayerControlEvent(
          state: PlayerControlState.timeUpdated,
          data: {
            'position': _state.currentPosition.inMilliseconds,
            'duration': _state.duration.inMilliseconds,
            'bufferedPosition': _state.bufferedPosition.inMilliseconds,
            'isBuffering':
                _state.activityState == PlayerActivityState.buffering,
          },
        );
        listener(currentControlEvent);

        // Also notify about qualities if available
        if (_state.qualities.isNotEmpty) {
          final qualityEvent = PlayerControlEvent(
            state: PlayerControlState.qualityChanged,
            data: {
              'qualities': _state.qualities.map((q) => q.toMap()).toList(),
              'quality': _state.qualities.first.toMap(),
            },
          );
          listener(qualityEvent);
        }
      }
    }
  }

  /// Removes a listener for control events
  void removeControlListener(void Function(PlayerControlEvent) listener) =>
      _controlEventHandlers.remove(listener);

  /// Video URL to play (supports HLS .m3u8 and direct video URLs)
  /// Returns null if load() has not been called yet
  String? get url => _url;

  /// Re-loads the last source after the native player was evicted by the iOS
  /// total-player LRU cap, restoring the pre-eviction position: a forced
  /// [load] of the retained source. The flag stays set on failure so the
  /// next [play] retries.
  Future<void> _reloadEvictedSource() async {
    final source = _url;
    if (source == null) {
      // Nothing was ever loaded, so there is nothing to restore.
      _needsReloadAfterEviction = false;
      return;
    }

    if (_isDisposed || _methodChannel == null) {
      return;
    }

    try {
      // A successful load clears _needsReloadAfterEviction itself.
      await load(
        url: source,
        headers: _lastLoadHeaders,
        drmConfig: _lastLoadDrmConfig,
        startAt: _evictionResumePosition,
        force: true,
      );
    } catch (e) {
      debugPrint('Post-eviction re-load failed: $e');
    }
  }

  /// Available video qualities (HLS variants)
  List<NativeVideoPlayerQuality> get qualities => _state.qualities;

  /// Returns whether the controller has been initialized
  bool get isInitialized => _isInitialized;

  /// Returns whether the video is currently in fullscreen mode
  bool get isFullScreen => _state.isFullScreen;

  /// Returns the current playback position as a Duration
  Duration get currentPosition => _state.currentPosition;

  /// Returns the total video duration as a Duration
  Duration get duration => _state.duration;

  /// Returns the buffered position as a Duration (how far the video has been buffered)
  Duration get bufferedPosition => _state.bufferedPosition;

  /// Returns the current volume (0.0 to 1.0)
  double get volume => _state.volume;

  /// Returns the current activity state (playing, paused, buffering, etc.)
  PlayerActivityState get activityState => _state.activityState;

  /// Returns the current control state (quality change, pip, fullscreen, etc.)
  PlayerControlState get controlState => _state.controlState;

  /// Current player state
  NativeVideoPlayerState get state => _state;

  /// Returns the current playback speed
  double get speed => _state.speed;

  /// Returns whether Picture-in-Picture mode is currently active
  bool get isPipEnabled => _state.isPipEnabled;

  /// Returns whether Picture-in-Picture is available on the device
  bool get isPipAvailable => _state.isPipAvailable;

  /// Returns whether AirPlay is available on the device
  ///
  /// This is a global state - if AirPlay is available, it's available for all controllers
  bool get isAirplayAvailable =>
      AirPlayStateManager.instance.isAirPlayAvailable;

  /// Returns whether the video is currently connected to an AirPlay/Cast device
  ///
  /// This is a global state - when the app is connected to AirPlay, all controllers are connected
  bool get isAirplayConnected =>
      AirPlayStateManager.instance.isAirPlayConnected;

  /// Returns whether the video is currently connecting to an AirPlay device
  ///
  /// This is a global state - indicates a connection attempt is in progress
  bool get isAirplayConnecting =>
      AirPlayStateManager.instance.isAirPlayConnecting;

  /// Returns the name of the currently connected AirPlay device
  ///
  /// Returns null if not connected to any AirPlay device
  String? get airPlayDeviceName =>
      AirPlayStateManager.instance.airPlayDeviceName;

  /// Stream of buffered position changes
  Stream<Duration> get bufferedPositionStream =>
      _bufferedPositionController.stream;

  /// Stream of duration changes
  Stream<Duration> get durationStream => _durationController.stream;

  /// Stream of player state changes (playing, paused, buffering, etc.)
  Stream<PlayerActivityState> get playerStateStream =>
      _playerStateController.stream;

  /// Stream of position changes
  Stream<Duration> get positionStream => _positionController.stream;

  /// Stream of playback speed changes
  Stream<double> get speedStream => _speedController.stream;

  /// Stream of Picture-in-Picture enabled state changes
  Stream<bool> get isPipEnabledStream => _isPipEnabledController.stream;

  /// Stream of Picture-in-Picture availability changes
  Stream<bool> get isPipAvailableStream => _isPipAvailableController.stream;

  /// Stream of AirPlay availability changes
  ///
  /// This is a global stream - all controllers receive the same AirPlay availability state
  Stream<bool> get isAirplayAvailableStream =>
      AirPlayStateManager.instance.isAirPlayAvailableStream;

  /// Stream of AirPlay connection state changes
  ///
  /// This is a global stream - all controllers receive the same AirPlay connection state
  Stream<bool> get isAirplayConnectedStream =>
      AirPlayStateManager.instance.isAirPlayConnectedStream;

  /// Stream of AirPlay connecting state changes
  ///
  /// This is a global stream - emits true when connecting to AirPlay, false when connection completes or fails
  Stream<bool> get isAirplayConnectingStream =>
      AirPlayStateManager.instance.isAirPlayConnectingStream;

  /// Stream of AirPlay device name changes
  ///
  /// Emits the device name when connected to an AirPlay device, or null when disconnected
  Stream<String?> get airPlayDeviceNameStream =>
      AirPlayStateManager.instance.airPlayDeviceNameStream;

  /// Stream of fullscreen state changes
  Stream<bool> get isFullscreenStream => _isFullscreenController.stream;

  /// Whether the loaded source is a live stream (HLS without an end).
  ///
  /// Known from the first time update after the stream starts. For a live
  /// stream [duration] is the seekable (DVR) window, [currentPosition] is
  /// measured from its start and [seekTo] takes a position in that window,
  /// so a regular scrubber works as a DVR scrubber. See [liveEdgeOffset]
  /// and [seekToLiveEdge].
  bool get isLive => _state.isLive;

  /// Stream of [isLive] changes.
  Stream<bool> get isLiveStream => _isLiveController.stream;

  /// How far playback is behind the live edge (zero for VOD). Stays a few
  /// seconds above zero even at the edge, because players keep a small
  /// distance to it.
  Duration get liveEdgeOffset {
    if (!_state.isLive) return Duration.zero;
    final offset = _state.duration - _state.currentPosition;
    return offset.isNegative ? Duration.zero : offset;
  }

  /// Latest native video dimensions (reported by texture-rendered views;
  /// null until the first frame's size is known).
  NativeVideoPlayerVideoSize? get videoSize => _videoSize;

  /// Stream of native video dimension changes (texture-rendered views).
  Stream<NativeVideoPlayerVideoSize> get videoSizeStream =>
      _videoSizeController.stream;

  /// Marks [platformViewId] as texture-rendered. Called by the widget right
  /// before [onPlatformViewCreated] for texture backends — these have no
  /// native view, so fullscreen falls back to the Dart path.
  void registerTextureView(int platformViewId) {
    _textureViewIds.add(platformViewId);
  }

  /// Engine texture ids of this controller's texture views, oldest first.
  final Map<int, int> _textureIdsByView = <int, int>{};

  /// The texture the player renders into now: the newest texture view's
  /// (Android: a new texture backend takes the player's output over, and an
  /// older one gets it back when the newer one goes). Null without one.
  ValueListenable<int?> get activeTextureId => _activeTextureId;
  final ValueNotifier<int?> _activeTextureId = ValueNotifier<int?>(null);

  /// Called by the widget once a texture view's engine texture exists.
  void registerTextureId(int platformViewId, int textureId) {
    _textureIdsByView.remove(platformViewId);
    _textureIdsByView[platformViewId] = textureId;
    _activeTextureId.value = textureId;
  }

  /// Internal: called by [NativeVideoPlayer] before [onPlatformViewCreated]
  /// for the view inside the Dart fullscreen route.
  void registerFullscreenView(int platformViewId) {
    _fullscreenViewIds.add(platformViewId);
  }

  /// Latest still frame of this player (JPEG), captured by
  /// [capturePosterFrame]. Painted where the platform view cannot be shown:
  /// under a route sliding over it, and in the fullscreen flight. Null until
  /// one is captured, and again after [load] switches the video.
  Uint8List? get posterFrame => _posterFrame;
  Uint8List? _posterFrame;

  /// Bumped by [load], so a capture of the previous video that lands after
  /// it is dropped.
  int _posterGeneration = 0;

  /// Captures the frame [platformViewId] shows now into [posterFrame], at
  /// most [maxWidth] pixels wide. iOS only (elsewhere a no-op). Returns
  /// [posterFrame], which stays the last good one when the capture fails.
  Future<Uint8List?> capturePosterFrame(
    int platformViewId, {
    int? maxWidth,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return _posterFrame;
    }
    final int generation = _posterGeneration;
    final Uint8List? frame = await VideoPlayerMethodChannel.captureFrame(
      platformViewId,
      maxWidth: maxWidth,
    );
    if (frame != null && generation == _posterGeneration) {
      _posterFrame = frame;
    }
    return _posterFrame;
  }

  /// Where the video is in a Dart fullscreen flight (iOS). The fullscreen
  /// route is see-through then (a swipe-down shows the page underneath) and
  /// doesn't drive the inline page's route animations, so the inline view
  /// follows this instead: hidden with an empty slot while the video is out,
  /// the poster under the landing video on the way back.
  ValueListenable<FullscreenFlightPhase> get fullscreenFlightPhase =>
      _fullscreenFlightPhase;
  final ValueNotifier<FullscreenFlightPhase> _fullscreenFlightPhase =
      ValueNotifier<FullscreenFlightPhase>(FullscreenFlightPhase.none);

  /// Whether the primary view is a texture-rendered backend.
  bool get _primaryViewIsTexture =>
      _primaryPlatformViewId != null &&
      _textureViewIds.contains(_primaryPlatformViewId);

  /// Stream of quality changes
  Stream<NativeVideoPlayerQuality> get qualityChangedStream =>
      _qualityChangedController.stream;

  /// Stream of available qualities list changes
  Stream<List<NativeVideoPlayerQuality>> get qualitiesStream =>
      _qualitiesController.stream;

  /// Parameters passed to native side when creating the platform view
  /// Includes controller ID, autoPlay, PiP settings, media info, and fullscreen state
  Map<String, dynamic> get creationParams => <String, dynamic>{
    'controllerId': id,
    'autoPlay': autoPlay,
    'allowsPictureInPicture': allowsPictureInPicture,
    'canStartPictureInPictureAutomatically':
        canStartPictureInPictureAutomatically,
    'showNativeControls': _hasCustomOverlay
        ? false
        : showNativeControls, // Hide native controls if we have custom overlay, otherwise use parameter
    'isFullScreen': _state.isFullScreen,
    'enableHDR': enableHDR,
    'enableLooping': enableLooping,
    'mixWithOthers': mixWithOthers,
    'preventFullscreenSwipeDismiss': preventFullscreenSwipeDismiss,
    'timeUpdateIntervalMs':
        NativeVideoPlayerConfig.global.timeUpdateInterval.inMilliseconds,
    'qualityForViewport': NativeVideoPlayerConfig.global.qualityForViewportSize,
    'viewportCapHeadroom': NativeVideoPlayerConfig.global.viewportCapHeadroom,
    'prioritizeActivePlayback':
        NativeVideoPlayerConfig.global.prioritizeActivePlayback,
    'lightweightInlineViews':
        NativeVideoPlayerConfig.global.lightweightInlineViews,
    'androidEnableDiskCache':
        NativeVideoPlayerConfig.global.androidEnableDiskCache,
    'androidDiskCacheMaxBytes':
        NativeVideoPlayerConfig.global.androidDiskCacheMaxBytes,
    'androidForceSoftwareDecoders':
        NativeVideoPlayerConfig.global.androidForceSoftwareDecoders,
    'iosMaxTotalPlayers': NativeVideoPlayerConfig.global.iosMaxTotalPlayers,
    'iosAllowsVideoFrameAnalysis':
        NativeVideoPlayerConfig.global.iosAllowsVideoFrameAnalysis,
    if (NativeVideoPlayerConfig.global.androidBufferConfig != null)
      'androidBufferConfig': NativeVideoPlayerConfig.global.androidBufferConfig!
          .toMap(),
    if (NativeVideoPlayerConfig.global.iosBufferConfig != null)
      'iosBufferConfig': NativeVideoPlayerConfig.global.iosBufferConfig!
          .toMap(),
    if (mediaInfo != null) 'mediaInfo': mediaInfo!.toMap(),
  };

  /// Sets the overlay builder for fullscreen mode
  ///
  /// This is typically called by NativeVideoPlayer widget to pass the overlay builder.
  /// When an overlay is set, native controls are automatically hidden and Dart fullscreen is used.
  void setOverlayBuilder(
    Widget Function(BuildContext, NativeVideoPlayerController)? builder,
  ) {
    _overlayBuilder = builder;

    // If we have a method channel, hide native controls when overlay is set
    if (_hasCustomOverlay && _methodChannel != null) {
      setShowNativeControls(false);
    }
  }

  /// Sets the sidecar subtitle style for fullscreen mode
  ///
  /// Typically called by the NativeVideoPlayer widget so the Dart fullscreen
  /// host (which builds its own NativeVideoPlayer) renders captions with the
  /// same style as the inline player.
  ///
  /// [NativeVideoPlayerSubtitleStyle.embeddedTextScale] is additionally
  /// pushed to the platform caption renderer (fire-and-forget) when it
  /// changed since the last call.
  void setSubtitleStyle(NativeVideoPlayerSubtitleStyle style) {
    _subtitleStyle = style;

    if (style.embeddedTextScale != _embeddedTextScale) {
      _embeddedTextScale = style.embeddedTextScale;
      unawaited(_methodChannel?.setEmbeddedTextScale(style.embeddedTextScale));
    }
  }

  /// Internal: the corner radius the Dart fullscreen host's swipe gives the
  /// video, read by the fullscreen [NativeVideoPlayer] to clip the video.
  ValueListenable<double>? get fullscreenVideoCornerRadius =>
      _fullscreenVideoCornerRadius;
  ValueListenable<double>? _fullscreenVideoCornerRadius;

  /// Internal: set by the Dart fullscreen host.
  void setFullscreenVideoCornerRadius(ValueListenable<double> radius) {
    _fullscreenVideoCornerRadius = radius;
  }

  /// Internal: cleared by the Dart fullscreen host that set [radius].
  void clearFullscreenVideoCornerRadius(ValueListenable<double> radius) {
    if (identical(_fullscreenVideoCornerRadius, radius)) {
      _fullscreenVideoCornerRadius = null;
    }
  }

  /// Sets the callback for closing Dart fullscreen
  /// This is called by FullscreenVideoPlayer to register itself
  void setDartFullscreenCloseCallback(VoidCallback? callback) {
    _dartFullscreenCloseCallback = callback;
  }

  /// Called when a native platform view is created
  ///
  /// Multiple platform views can register with the same controller.
  /// Each platform view gets its own event channel listener to receive events.
  /// The first platform view becomes the primary view that handles method channel communication.
  ///
  /// **Parameters:**
  /// - platformViewId: The unique ID assigned by Flutter to the platform view
  Future<void> onPlatformViewCreated(
    int platformViewId,
    BuildContext context,
  ) async {
    // Check if we're reconnecting BEFORE adding the new view ID
    final bool wasDisconnected = _platformViewIds.isEmpty;

    _platformViewIds.add(platformViewId);

    // Store context for Dart fullscreen
    _platformViewContexts[platformViewId] = context;

    // Always update to use the most recent platform view
    // This ensures commands go to the active view
    _updateMethodChannel(platformViewId);

    // A freshly attached view runs the platform's own media selection; put
    // the app's subtitle choice back (the native side re-applies it too, this
    // keeps the contract explicit on both platforms). Sidecar tracks render in
    // Dart, so for those the native track must stay off.
    final NativeVideoPlayerSubtitleTrack? lastSubtitleTrack =
        _lastSubtitleTrack;
    if (lastSubtitleTrack != null && _methodChannel != null) {
      await _methodChannel!.setSubtitleTrack(
        lastSubtitleTrack.source == SubtitleTrackSource.sidecar
            ? NativeVideoPlayerSubtitleTrack.off()
            : lastSubtitleTrack,
      );
    }

    // If we're reconnecting after all platform views were disposed, refresh availability flags
    if (wasDisconnected) {
      // Ask native to reconnect surface for this view (Android reconnects ExoPlayer surface;
      // iOS no-ops). Ensures video shows when returning from detail to inline (list→detail→back).
      if (_methodChannel != null) {
        await _methodChannel!.ensureSurfaceConnected();
      }

      // Re-apply the embedded caption text scale — the recreated native view
      // builds its SubtitleView with the platform default size.
      if (_embeddedTextScale != 1.0 && _methodChannel != null) {
        await _methodChannel!.setEmbeddedTextScale(_embeddedTextScale);
      }

      // Re-fetch availability flags from native side FIRST (wait for it to complete)
      // This ensures the state is up-to-date before we emit it
      await _refreshAvailabilityFlags();

      // Ensure native controls are hidden if we have a custom overlay
      // This is critical when rapidly navigating - the overlay builder persists
      // but native controls might not have been hidden during the reconnection
      if (_hasCustomOverlay && _methodChannel != null) {
        await setShowNativeControls(false);
      }

      // Enable automatic PiP on Android if configured
      await _enableAutomaticPiP();
    }

    _emitCurrentState();

    // ALWAYS notify all event handler listeners about the current state
    // This ensures listeners added via add*Listener methods receive the current state

    // Notify AirPlay availability listeners
    for (final handler in _airPlayAvailabilityHandlers) {
      handler(_state.isAirplayAvailable);
    }

    // Notify AirPlay connection listeners
    for (final handler in _airPlayConnectionHandlers) {
      handler(_state.isAirplayConnected);
    }

    // Notify activity event listeners with the current activity state
    if (_activityEventHandlers.isNotEmpty) {
      final currentActivityEvent = PlayerActivityEvent(
        state: _state.activityState,
        data: null,
      );
      for (final handler in _activityEventHandlers) {
        handler(currentActivityEvent);
      }
    }

    // Notify control event listeners if there's a current control state
    if (_controlEventHandlers.isNotEmpty &&
        _state.controlState != PlayerControlState.none) {
      final currentControlEvent = PlayerControlEvent(
        state: _state.controlState,
        data: null,
      );
      for (final handler in _controlEventHandlers) {
        handler(currentControlEvent);
      }
    }

    // Safety net: if the constructor's controller-channel setup failed (e.g.
    // plugin not attached yet), retry now — a platform view existing proves
    // the plugin is attached.
    unawaited(_ensureControllerEventChannel());

    // IMPORTANT: Set up event channel for EVERY platform view
    // This ensures that both the original and fullscreen widgets receive events
    // Use retry logic to handle race condition where native side hasn't finished initializing
    unawaited(_subscribeToEventChannelWithRetry(platformViewId));
  }

  /// Callback for AirPlay availability changes
  final List<void Function(bool isAvailable)> _airPlayAvailabilityHandlers =
      <void Function(bool)>[];

  /// Callback for AirPlay connection changes
  final List<void Function(bool isConnected)> _airPlayConnectionHandlers =
      <void Function(bool)>[];

  /// Adds a listener for AirPlay availability changes
  void addAirPlayAvailabilityListener(void Function(bool) listener) {
    if (!_airPlayAvailabilityHandlers.contains(listener)) {
      _airPlayAvailabilityHandlers.add(listener);

      // Immediately notify the new listener of the current state
      // This ensures listeners added after initialization receive the current state
      if (_isInitialized && !_isDisposed) {
        listener(_state.isAirplayAvailable);
      }
    }
  }

  /// Removes a listener for AirPlay availability changes
  void removeAirPlayAvailabilityListener(void Function(bool) listener) =>
      _airPlayAvailabilityHandlers.remove(listener);

  /// Adds a listener for AirPlay connection changes (when video connects/disconnects to AirPlay)
  void addAirPlayConnectionListener(void Function(bool) listener) {
    if (!_airPlayConnectionHandlers.contains(listener)) {
      _airPlayConnectionHandlers.add(listener);

      // Immediately notify the new listener of the current state
      // This ensures listeners added after initialization receive the current state
      if (_isInitialized && !_isDisposed) {
        listener(_state.isAirplayConnected);
      }
    }
  }

  /// Removes a listener for AirPlay connection changes
  void removeAirPlayConnectionListener(void Function(bool) listener) =>
      _airPlayConnectionHandlers.remove(listener);

  /// Safely cancels a stream subscription, handling MissingPluginException gracefully
  ///
  /// When the native side has already disposed the EventChannel StreamHandler,
  /// cancelling the subscription will throw a MissingPluginException. This is harmless
  /// and indicates the native side has already cleaned up, so we ignore it.
  ///
  /// **Parameters:**
  /// - subscription: The subscription to cancel, may be null
  ///
  /// **Returns:**
  /// A Future that completes when the cancellation is attempted (or immediately if subscription is null)
  Future<void> _safeCancelSubscription(
    StreamSubscription<dynamic>? subscription,
  ) async {
    if (subscription == null) {
      return;
    }
    try {
      await subscription.cancel();
    } on MissingPluginException {
      // Native side has already disposed the EventChannel StreamHandler
      // This is harmless and safe to ignore
    } catch (e) {
      // Log other exceptions in debug mode for debugging purposes
      if (kDebugMode) {
        debugPrint('Error cancelling subscription: $e');
      }
    }
  }

  /// Called when a platform view is disposed
  ///
  /// Unregisters the platform view from this controller.
  /// If it was the primary view, promotes another view to primary.
  ///
  /// **Parameters:**
  /// - platformViewId: The ID of the platform view being disposed
  void onPlatformViewDisposed(int platformViewId) {
    _platformViewIds.remove(platformViewId);
    _platformViewContexts.remove(platformViewId);
    _viewSnapshots.remove(platformViewId);
    _textureViewIds.remove(platformViewId);
    if (_textureIdsByView.remove(platformViewId) != null) {
      _activeTextureId.value = _textureIdsByView.isEmpty
          ? null
          : _textureIdsByView.values.last;
    }

    // Cancel the event channel subscription first, then release the native
    // per-view channel handlers: on iOS the EventChannel handler strongly
    // retains the platform view, so its deinit is unreachable until the
    // handler is deregistered.
    final NativeEventSubscription? subscription = _eventSubscriptions.remove(
      platformViewId,
    );
    unawaited(
      (subscription?.cancel() ?? Future<void>.value()).then(
        (_) => VideoPlayerMethodChannel.notifyViewDisposed(platformViewId),
      ),
    );

    // If the disposed view was the primary view, switch to another active view
    if (_primaryPlatformViewId == platformViewId &&
        _platformViewIds.isNotEmpty) {
      // Use the most recent remaining view
      final newPrimaryViewId = _platformViewIds.last;
      _updateMethodChannel(newPrimaryViewId);
    }

    // AirPlay commands are routed to the channel's view. A controller that
    // outlives its last view (PiP, AirPlay, an app holding it) would answer
    // them with "no view" while other controllers have one. It registers
    // again when a view attaches (see _updateMethodChannel).
    if (_platformViewIds.isEmpty && _methodChannel != null) {
      AirPlayStateManager.instance.unregisterMethodChannel(_methodChannel!);
    }

    if (_fullscreenViewIds.remove(platformViewId) &&
        _fullscreenViewIds.isEmpty) {
      _completeFullscreenViewsDisposed();
    }
  }

  /// Waits for a closing Dart fullscreen route to dispose its platform view.
  ///
  /// [exitFullScreen] only starts the route's pop. Until its fade-out ends,
  /// the fullscreen view stays the primary view, so iOS PiP requested right
  /// after leaving fullscreen started on that view's layer and ended when the
  /// view was disposed: the first tap only closed fullscreen.
  Future<void> _waitForClosingFullscreenViews() async {
    if (_state.isFullScreen || _fullscreenViewIds.isEmpty) {
      return;
    }

    final completer = _fullscreenViewsDisposed ??= Completer<void>();
    await completer.future.timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );
  }

  void _completeFullscreenViewsDisposed() {
    final completer = _fullscreenViewsDisposed;
    _fullscreenViewsDisposed = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// Loads a video URL or local file into the already initialized player
  ///
  /// Must be called after the platform view is created and channels are set up.
  /// This method loads the video URL on the native side and fetches available qualities.
  /// If multiple platform views are using this controller, they will all sync to the same video.
  ///
  /// **Parameters:**
  /// - url: Video URL to play (supports HLS, MP4, and local file:// URIs)
  /// - headers: Optional HTTP headers to include with the video request (e.g., {"Referer": "domain"})
  /// - drmConfig: Optional DRM configuration for protected content
  ///   - type: DRM type ('widevine', 'fairplay', 'clearKey', or 'aes-128')
  ///   - licenseUrl: License server URL
  ///   - certificateUrl: Certificate URL (iOS FairPlay only)
  ///   - headers: HTTP headers for license requests
  ///
  /// **Returns:**
  /// A Future that completes when the video is loaded
  ///
  /// **Note:** For better clarity, consider using [loadUrl] for remote videos or [loadFile] for local files.
  ///
  /// Pass [startAt] to begin playback at a stored resume position — the
  /// position is applied natively before the first frame, so there is no
  /// visible seek after playback starts.
  ///
  /// [chapters] sets the video's chapters (see [setChapters]). Without it,
  /// chapters set earlier are kept for the same URL and cleared for a
  /// different one.
  ///
  /// Loading the same [url] again while the state is `loaded` does nothing
  /// (the guard that prevents accidental double-loads); [force] loads it
  /// anyway. A different URL always loads.
  Future<void> load({
    required String url,
    Map<String, String>? headers,
    Map<String, dynamic>? drmConfig,
    List<NativeVideoPlayerSidecarSubtitle>? sidecarSubtitles,
    Duration? startAt,
    List<NativeVideoPlayerChapter>? chapters,
    bool force = false,
  }) async {
    if (!force && _state.activityState.isLoaded && url == _url) {
      if (chapters != null) setChapters(chapters);
      return;
    }

    _posterGeneration++;
    _posterFrame = null;

    // Check if initialized - if method channel exists and platform view is created,
    // consider it initialized even if _isInitialized flag hasn't been set yet
    if (!_isInitialized &&
        (_methodChannel == null || _platformViewIds.isEmpty)) {
      throw Exception('Controller not initialized. Call initialize() first.');
    }

    if (_methodChannel == null) {
      throw Exception(
        'Method channel not initialized. Platform view not created.',
      );
    }

    final previousUrl = _url;
    _url = url;

    // Chapters belong to a video: replace them with the ones passed, or
    // drop them when a different video loads.
    if (chapters != null) {
      setChapters(chapters);
    } else if (previousUrl != null && previousUrl != url) {
      setChapters(const []);
    }

    // Retained for the eviction re-load (see _reloadEvictedSource).
    _lastLoadHeaders = headers;
    _lastLoadDrmConfig = drmConfig;

    // An A-B range only makes sense for the video it was set on.
    _playbackRange = null;
    _pendingSeekTarget = null;
    _endSeekHold();
    // Until the viewer plays or seeks, the new video stays loaded.
    _completedUntilAction = false;
    _loadedUntilAction = true;

    // The new source reports whether it is live with its first time update.
    if (_state.isLive) _updateState(_state.copyWith(isLive: false));

    // Track indices belong to the previous source.
    _lastSubtitleTrack = null;

    if (sidecarSubtitles != null) {
      _sidecarSubtitles.setSources(sidecarSubtitles);
    }

    _playReportedDuringLoad = false;

    try {
      await _methodChannel!.load(
        url: url,
        autoPlay: autoPlay,
        headers: headers,
        mediaInfo: mediaInfo?.toMap(),
        drmConfig: drmConfig,
        // Android attaches URL sources natively (MediaItem.SubtitleConfiguration)
        // so captions can also render in PiP/native fullscreen; iOS and
        // non-URL sources render through the Flutter overlay only.
        sidecarSubtitles: _androidSidecarMaps(sidecarSubtitles),
        startAtMs: startAt?.inMilliseconds,
      );

      // Re-apply the embedded caption text scale to the fresh player item.
      if (_embeddedTextScale != 1.0) {
        await _methodChannel!.setEmbeddedTextScale(_embeddedTextScale);
      }

      // The native load (re)created the player, so any pending eviction
      // re-load is satisfied.
      _needsReloadAfterEviction = false;

      // Fetch available qualities after loading
      final qualities = await _methodChannel!.getAvailableQualities();

      // With autoplay (or a play() racing the load) native has already
      // reported `play` by now. Android sends no further play event, so
      // writing `loaded` here would leave the state stale while it plays.
      final bool isAlreadyPlaying =
          _playReportedDuringLoad &&
          _state.activityState == PlayerActivityState.playing;
      _updateState(
        _state.copyWith(
          qualities: qualities,
          activityState: isAlreadyPlaying
              ? PlayerActivityState.playing
              : PlayerActivityState.loaded,
        ),
      );

      // Notify control listeners about available qualities
      if (qualities.isNotEmpty) {
        final qualityEvent = PlayerControlEvent(
          state: PlayerControlState.qualityChanged,
          data: {
            'qualities': qualities.map((q) => q.toMap()).toList(),
            if (qualities.isNotEmpty) 'quality': qualities.first.toMap(),
          },
        );

        for (final handler in _controlEventHandlers) {
          handler(qualityEvent);
        }
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Loads a remote video URL into the player
  ///
  /// This is a convenience method that explicitly loads a remote video URL.
  /// Supports HLS streams (.m3u8), MP4, and other formats supported by the native player.
  ///
  /// **Parameters:**
  /// - url: Remote video URL (e.g., "https://example.com/video.mp4")
  /// - headers: Optional HTTP headers to include with the video request
  /// - drmConfig: Optional DRM configuration for protected content
  ///   - type: DRM type ('widevine', 'fairplay', 'clearKey', or 'aes-128')
  ///   - licenseUrl: License server URL
  ///   - certificateUrl: Certificate URL (iOS FairPlay only)
  ///   - headers: HTTP headers for license requests
  ///
  /// **Example:**
  /// ```dart
  /// // Load HLS stream
  /// await controller.loadUrl(
  ///   url: 'https://example.com/video.m3u8',
  /// );
  ///
  /// // Load MP4 with custom headers
  /// await controller.loadUrl(
  ///   url: 'https://example.com/video.mp4',
  ///   headers: {'Referer': 'https://example.com'},
  /// );
  ///
  /// // Load with DRM (FairPlay on iOS)
  /// await controller.loadUrl(
  ///   url: 'https://example.com/stream.m3u8',
  ///   drmConfig: {
  ///     'type': 'fairplay',
  ///     'licenseUrl': 'https://license.server.com/get',
  ///     'certificateUrl': 'https://cert.server.com/cert.der',
  ///     'headers': {
  ///       'Authorization': 'Bearer <token>'
  ///     }
  ///   }
  /// );
  /// ```
  Future<void> loadUrl({
    required String url,
    Map<String, String>? headers,
    Map<String, dynamic>? drmConfig,
    Duration? startAt,
    List<NativeVideoPlayerChapter>? chapters,
    bool force = false,
  }) async {
    return load(
      url: url,
      headers: headers,
      drmConfig: drmConfig,
      startAt: startAt,
      chapters: chapters,
      force: force,
    );
  }

  /// Loads a local video file into the player
  ///
  /// This is a convenience method for loading videos from device storage.
  /// Automatically handles the file:// URI scheme construction.
  ///
  /// **Parameters:**
  /// - path: Absolute path to the local video file
  ///
  /// **Example:**
  /// ```dart
  /// // Android
  /// await controller.loadFile(
  ///   path: '/storage/emulated/0/DCIM/video.mp4',
  /// );
  ///
  /// // iOS
  /// await controller.loadFile(
  ///   path: '/var/mobile/Media/DCIM/100APPLE/video.MOV',
  /// );
  /// ```
  ///
  /// **Note:** The path should be an absolute path to the file.
  /// For accessing app documents or bundle resources, use the appropriate
  /// path_provider methods to get the correct paths.
  Future<void> loadFile({required String path}) async {
    // Construct file:// URI if not already provided
    final fileUrl = path.startsWith('file://') ? path : 'file://$path';
    return load(url: fileUrl);
  }

  /// Starts or resumes video playback
  ///
  /// If the native player was torn down by the iOS total-player LRU cap
  /// (see [NativeVideoPlayerConfig.iosMaxTotalPlayers]), the last source is
  /// transparently re-loaded at the pre-eviction position first.
  Future<void> play() async {
    if (_needsReloadAfterEviction) {
      await _reloadEvictedSource();
    }

    // Starting (or replaying) a video: its buffering shows again.
    _endStateHolds();
    await _methodChannel?.play();
  }

  /// Pauses video playback
  Future<void> pause() async {
    _endSeekHold();
    final bool pausedWithoutView = await _methodChannel?.pause() ?? false;
    // Without a view no native pause event reaches Dart, so report it here.
    if (pausedWithoutView &&
        !_isDisposed &&
        _state.activityState != PlayerActivityState.paused) {
      _handlePlatformViewEvent(<String, Object?>{'event': 'pause'});
    }
  }

  /// Seeks to a specific position
  ///
  /// For a live stream the position is within the seekable (DVR) window,
  /// the way [currentPosition] reports it.
  Future<void> seekTo(Duration position) async {
    final Duration target = position.isNegative ? Duration.zero : position;
    _pendingSeekTarget = target;
    _pendingSeekSince = DateTime.now();
    // A seek leaves loaded and completed: the video ends paused.
    _endStateHolds();
    final PlayerActivityState state = _state.activityState;
    if (_seekHoldTimer == null) _seekHoldsPause = state.isPlaying;
    if (state.isPlaying ||
        state.isPaused ||
        state.isLoaded ||
        state.isCompleted ||
        _seekHoldTimer != null) {
      _startSeekHold();
    }
    // Show the target right away; the native side confirms it shortly.
    _updateState(_state.copyWith(currentPosition: target));
    _lastSeekCall = DateTime.now();
    _seeksInFlight++;
    try {
      await _methodChannel?.seekTo(position);
    } finally {
      _seeksInFlight--;
    }
    // The hold window counts from the native seek, not from this call: a
    // busy platform thread can run it hundreds of ms later (seen on an
    // Android phone right after a load), and the blips come after that.
    if (_seekHoldTimer != null && !_isDisposed) _startSeekHold();
  }

  /// Where the last [seekTo] is heading while position updates sent before
  /// it can still arrive: those are dropped until one lands near the target
  /// or [_seekSettleTimeout] passes, so a seek bar doesn't jump back first.
  Duration? _pendingSeekTarget;
  DateTime? _pendingSeekSince;
  static const Duration _seekSettleTimeout = Duration(seconds: 2);
  static const Duration _seekSettleTolerance = Duration(milliseconds: 1500);

  /// Whether a reported [position] is a leftover from before the last seek.
  bool _isStaleAfterSeek(Duration position) {
    final Duration? target = _pendingSeekTarget;
    final DateTime? since = _pendingSeekSince;
    if (target == null || since == null) return false;
    if (DateTime.now().difference(since) > _seekSettleTimeout ||
        (position - target).abs() <= _seekSettleTolerance) {
      _pendingSeekTarget = null;
      _pendingSeekSince = null;
      return false;
    }
    return true;
  }

  /// While a seek runs on a playing video, the native player reports a
  /// pause, loading or buffering for a moment before it plays on (iOS: the
  /// buffer refilling, Android: ExoPlayer buffering). Those are held back
  /// for up to [_seekHoldWindow], so a play/pause button doesn't flash; the
  /// last one held still applies when the video doesn't play on in time
  /// (a real stall). Scrubbing (seek after seek) keeps the hold going.
  ///
  /// A seek on a paused (or loaded) video holds only loading and buffering
  /// (Android reports BUFFERING for a moment before READY, iOS doesn't):
  /// the pause that ends the seek applies right away.
  Timer? _seekHoldTimer;
  Map<Object?, Object?>? _heldSeekEvent;
  bool _seekHoldsPause = false;
  static const Duration _seekHoldWindow = Duration(milliseconds: 600);

  /// Native seekTo calls not answered yet: the hold waits for them (up to
  /// [_seekHoldLimit]) before its window starts (see [seekTo]).
  int _seeksInFlight = 0;
  DateTime? _lastSeekCall;
  static const Duration _seekHoldLimit = Duration(seconds: 3);

  void _startSeekHold() {
    _seekHoldTimer?.cancel();
    _seekHoldTimer = Timer(_seekHoldWindow, () {
      final DateTime? since = _lastSeekCall;
      if (_seeksInFlight > 0 &&
          since != null &&
          DateTime.now().difference(since) < _seekHoldLimit) {
        _startSeekHold();
        return;
      }
      final Map<Object?, Object?>? held = _heldSeekEvent;
      _endSeekHold();
      if (held != null && !_isDisposed) _handlePlatformViewEvent(held);
    });
  }

  void _endSeekHold() {
    _seekHoldTimer?.cancel();
    _seekHoldTimer = null;
    _heldSeekEvent = null;
  }

  /// Whether [state] is a seek blip to hold back (see [_seekHoldTimer]).
  bool _holdsDuringSeek(
    Map<Object?, Object?> event,
    PlayerActivityState state,
  ) {
    if (_seekHoldTimer == null) return false;
    if ((state.isPaused && _seekHoldsPause) ||
        state.isLoading ||
        state.isBuffering) {
      _heldSeekEvent = event;
      return true;
    }
    // Playing on (or anything final): the hold is over.
    _endSeekHold();
    return false;
  }

  /// Native players report a few states nobody asked for, right after two
  /// moments the app cares about. The controller keeps its state through
  /// them until the viewer acts:
  ///
  /// - **After `completed`**: both players rewind to the start and pause,
  ///   and report that rewind (a pause, a buffering blip; Android: READY
  ///   again). `completed` stays until playback starts, the viewer seeks or
  ///   another video loads.
  /// - **After a load**: once the first buffer fills, a never-played video
  ///   reports a pause (Android: loading finished in READY, iOS:
  ///   playbackLikelyToKeepUp). `loaded` stays until playback starts, the
  ///   viewer seeks or another video loads, so it means "not started yet"
  ///   on both platforms.
  /// - **During a load**: loading into a player that already had a video
  ///   (iOS replaces the item) reports a pause before `loaded`. `loading`
  ///   stays until the new video's `loaded`.
  ///
  /// Kept through: paused, buffering, loading and loaded. Any other state
  /// (playing, completed, error, stopped, idle) applies and ends the hold.
  ///
  /// Outside a load, a `loaded` on a playing or paused video only updates
  /// the duration: a new view on the shared player re-sends it.
  bool _completedUntilAction = false;
  bool _loadedUntilAction = false;

  /// Whether [state] arrives during a hold (see [_completedUntilAction])
  /// and keeps the current state.
  bool _keepsCurrentState(PlayerActivityState state) {
    if (state.isCompleted) {
      _completedUntilAction = true;
      _loadedUntilAction = false;
      return false;
    }
    final PlayerActivityState current = _state.activityState;
    // A view attaching to a shared player (fullscreen, list -> detail)
    // re-sends `loaded`, then its play state, for a video that is already
    // playing or paused: not a new load, so the state stays.
    if (state.isLoaded &&
        !_loadedUntilAction &&
        (current.isPlaying || current.isPaused)) {
      return true;
    }
    final bool holding =
        (_completedUntilAction && current.isCompleted) ||
        (_loadedUntilAction && current.isLoaded) ||
        // Only the new video's loaded ends a loading.
        (_loadedUntilAction && current.isLoading && !state.isLoaded);
    final bool quiet =
        state.isPaused ||
        state.isBuffering ||
        state.isLoading ||
        state.isLoaded ||
        state == PlayerActivityState.initialized;
    if (holding && quiet) return true;
    if (!quiet) {
      _completedUntilAction = false;
      _loadedUntilAction = false;
    }
    return false;
  }

  /// Ends both holds: the viewer played or seeked.
  void _endStateHolds() {
    _completedUntilAction = false;
    _loadedUntilAction = false;
  }

  /// Jumps a live stream back to its live edge, for a "Live" button after
  /// the viewer paused or scrubbed back. Does nothing for VOD.
  Future<void> seekToLiveEdge() async {
    _pendingSeekTarget = null;
    await _methodChannel?.seekToLiveEdge();
  }

  /// The video's chapters, sorted by start. Empty when none are set and
  /// while a live stream plays (chapters are hidden for live).
  List<NativeVideoPlayerChapter> get chapters =>
      _state.isLive ? const [] : _chapters;
  List<NativeVideoPlayerChapter> _chapters = const [];

  /// Emits [chapters] whenever they change.
  Stream<List<NativeVideoPlayerChapter>> get chaptersStream =>
      _chaptersController.stream;

  /// The chapter at [currentPosition], or null without chapters, before
  /// the first one starts, and for live streams.
  NativeVideoPlayerChapter? get currentChapter => _currentChapter;
  NativeVideoPlayerChapter? _currentChapter;

  /// The index of [currentChapter] in [chapters], or -1.
  int get currentChapterIndex =>
      _currentChapter == null ? -1 : chapters.indexOf(_currentChapter!);

  /// Emits [currentChapter] whenever playback crosses into another chapter
  /// (or the chapters change). Control listeners get the same moment as a
  /// [PlayerControlState.chapterChanged] event, and chapter list changes as
  /// [PlayerControlState.chaptersChanged], so an overlay built on
  /// [addControlListener] can show the chapter anywhere.
  Stream<NativeVideoPlayerChapter?> get currentChapterStream =>
      _currentChapterController.stream;

  /// Sets the chapters of the loaded video, in any order (they are sorted
  /// by start; of chapters sharing a start the first is kept). Pass an
  /// empty list to clear them. Loading a different URL clears them too;
  /// `load(chapters: ...)` sets them with the video.
  ///
  /// Parse them from a description with [NativeVideoPlayerChapters.parseText]
  /// or from a WebVTT chapters track with [NativeVideoPlayerChapters.parseVtt].
  void setChapters(List<NativeVideoPlayerChapter> chapters) {
    final normalized = NativeVideoPlayerChapters.normalize(chapters);
    if (listEquals(normalized, _chapters)) return;
    _chapters = normalized;
    if (_isDisposed) return;
    _emitChapters();
    _updateCurrentChapter();
  }

  void _emitChapters() {
    final chapters = this.chapters;
    if (!_chaptersController.isClosed) _chaptersController.add(chapters);
    _notifyControlListeners(
      PlayerControlEvent(
        state: PlayerControlState.chaptersChanged,
        data: {'count': chapters.length},
      ),
    );
  }

  void _notifyControlListeners(PlayerControlEvent event) {
    for (final handler in List.of(_controlEventHandlers)) {
      handler(event);
    }
  }

  void _updateCurrentChapter() {
    final chapter = NativeVideoPlayerChapters.chapterAt(
      chapters,
      _state.currentPosition,
    );
    if (chapter == _currentChapter) return;
    _currentChapter = chapter;
    if (_isDisposed) return;
    if (!_currentChapterController.isClosed) {
      _currentChapterController.add(chapter);
    }
    _notifyControlListeners(
      PlayerControlEvent(
        state: PlayerControlState.chapterChanged,
        data: {
          'index': chapter == null ? -1 : chapters.indexOf(chapter),
          'title': chapter?.title,
          'startMs': chapter?.start.inMilliseconds,
        },
      ),
    );
  }

  /// Seeks to the start of the next chapter. Does nothing in the last
  /// chapter or without chapters.
  Future<void> seekToNextChapter() async {
    final chapters = this.chapters;
    // A seek to a chapter start can report a position a hair before it;
    // the tolerance keeps that from "skipping" to the same chapter again.
    final index = NativeVideoPlayerChapters.indexAt(
      chapters,
      _state.currentPosition + const Duration(milliseconds: 250),
    );
    if (index + 1 >= chapters.length) return;
    await seekTo(chapters[index + 1].start);
  }

  /// Seeks to the start of the current chapter, or to the previous chapter
  /// when playback is within [restartThreshold] of the current one's start
  /// (like a music player's back button). Does nothing without chapters.
  Future<void> seekToPreviousChapter({
    Duration restartThreshold = const Duration(seconds: 3),
  }) async {
    final chapters = this.chapters;
    if (chapters.isEmpty) return;
    final position = _state.currentPosition;
    final index = NativeVideoPlayerChapters.indexAt(chapters, position);
    if (index == -1) {
      await seekTo(Duration.zero);
    } else if (position - chapters[index].start > restartThreshold ||
        index == 0) {
      await seekTo(chapters[index].start);
    } else {
      await seekTo(chapters[index - 1].start);
    }
  }

  /// The active A-B playback range, or null when playback is unrestricted.
  NativeVideoPlayerPlaybackRange? get playbackRange => _playbackRange;
  NativeVideoPlayerPlaybackRange? _playbackRange;

  /// Guards against re-triggering range handling on every position tick
  /// while the boundary seek/pause is still in flight.
  bool _rangeActionInFlight = false;

  /// Confines playback to [start]..[end] (A-B loop / clip range).
  ///
  /// With [loop] (default) the player seeks back to [start] whenever the
  /// position reaches [end]; with `loop: false` it pauses once at [end] and
  /// the range is released. If the current position is outside the range,
  /// playback seeks to [start] immediately. Enforcement runs on the
  /// existing position updates, so boundary precision follows the
  /// configured time-update interval. Cleared by [clearPlaybackRange] and
  /// by loading a new video.
  Future<void> setPlaybackRange({
    required Duration start,
    required Duration end,
    bool loop = true,
  }) async {
    final range = NativeVideoPlayerPlaybackRange(
      start: start,
      end: end,
      loop: loop,
    );
    _playbackRange = range;
    _rangeActionInFlight = false;
    if (!range.contains(_state.currentPosition)) {
      await seekTo(start);
    }
  }

  /// Removes the A-B playback range; playback continues unrestricted.
  void clearPlaybackRange() {
    _playbackRange = null;
    _rangeActionInFlight = false;
  }

  /// Enforces the A-B range on position updates (called from
  /// [_updateState] whenever the position changes).
  void _enforcePlaybackRange(Duration position) {
    final range = _playbackRange;
    if (range == null || _rangeActionInFlight || position < range.end) {
      return;
    }
    _rangeActionInFlight = true;
    if (range.loop) {
      unawaited(
        seekTo(range.start).whenComplete(() => _rangeActionInFlight = false),
      );
    } else {
      // One-shot clip range: stop at the end and release the range so the
      // user can seek/replay freely afterwards.
      _playbackRange = null;
      unawaited(pause().whenComplete(() => _rangeActionInFlight = false));
    }
  }

  /// Sets the volume
  Future<void> setVolume(double volume) async {
    await _methodChannel?.setVolume(volume);
    _updateState(_state.copyWith(volume: volume));
  }

  /// Sets the playback speed
  Future<void> setSpeed(double speed) async {
    await _methodChannel?.setSpeed(speed);
  }

  /// Scales the text size of EMBEDDED (native-rendered) subtitle tracks.
  /// 1.0 = platform default. No effect on the sidecar overlay (use
  /// [setSubtitleStyle] / `subtitleStyle.fontSize` for that). Issue #43.
  ///
  /// Takes effect live and survives item reloads and native view recreation.
  Future<void> setNativeSubtitleTextScale(double scale) async {
    _embeddedTextScale = scale;
    _subtitleStyle = (_subtitleStyle ?? const NativeVideoPlayerSubtitleStyle())
        .copyWith(embeddedTextScale: scale);
    await _methodChannel?.setEmbeddedTextScale(scale);
  }

  /// Sets whether the video should loop
  Future<void> setLooping(bool looping) async {
    await _methodChannel?.setLooping(looping);
  }

  /// Sets the video quality
  Future<void> setQuality(NativeVideoPlayerQuality quality) async {
    await _methodChannel?.setQuality(quality);
  }

  /// Gets available subtitle tracks: tracks EMBEDDED in the media plus any
  /// sidecar (external VTT/SRT) sources provided via [setSidecarSubtitles]
  /// or `load(sidecarSubtitles:)`, distinguished by
  /// [NativeVideoPlayerSubtitleTrack.source].
  Future<List<NativeVideoPlayerSubtitleTrack>>
  getAvailableSubtitleTracks() async {
    final embedded =
        await _methodChannel?.getAvailableSubtitleTracks() ??
        <NativeVideoPlayerSubtitleTrack>[];
    final int? selectedSidecar = _sidecarSubtitles.selectedSource;
    final sources = _sidecarSubtitles.sources;

    // On Android, URL sidecars are also attached natively (so captions can
    // render in PiP / native fullscreen), so they echo back in `embedded`.
    // Suppress those native echoes by language — each caption then appears
    // once, and the Dart sidecar entry below is the canonical, overlay-rendered
    // representation. On iOS nothing is sideloaded natively, so genuine
    // embedded tracks (e.g. an HLS "CC") are left untouched.
    final Set<String> nativelyAttachedLanguages =
        _androidSidecarMaps(sources) == null
        ? const <String>{}
        : sources.where((s) => s.url != null).map((s) => s.language).toSet();

    return <NativeVideoPlayerSubtitleTrack>[
      // While a sidecar track renders, embedded tracks are natively disabled,
      // so their stale isSelected flags are cleared.
      for (final track in embedded)
        if (!nativelyAttachedLanguages.contains(track.language))
          selectedSidecar != null ? track.copyWith(isSelected: false) : track,
      for (var i = 0; i < sources.length; i++)
        NativeVideoPlayerSubtitleTrack(
          index: i,
          language: sources[i].language,
          displayName: sources[i].label,
          isSelected: selectedSidecar == i,
          source: SubtitleTrackSource.sidecar,
        ),
    ];
  }

  /// Sets the subtitle track.
  ///
  /// Works for both embedded tracks and sidecar tracks (see
  /// [NativeVideoPlayerSubtitleTrack.source]). Pass a track with index -1 or
  /// use NativeVideoPlayerSubtitleTrack.off() to disable subtitles.
  Future<void> setSubtitleTrack(NativeVideoPlayerSubtitleTrack track) async {
    _lastSubtitleTrack = track;

    if (track.source == SubtitleTrackSource.sidecar) {
      try {
        await _sidecarSubtitles.select(track.index);
      } catch (e) {
        // A broken subtitle source must never break playback.
        debugPrint(
          'Failed to load sidecar subtitle "${track.displayName}": $e',
        );
        return;
      }
      // Prevent double captions: disable any embedded native track.
      await _methodChannel?.setSubtitleTrack(
        NativeVideoPlayerSubtitleTrack.off(),
      );
      _emitSubtitleChanged(track);
      return;
    }

    // Embedded track (or Off): stop sidecar rendering, delegate to native
    // (which emits its own subtitleChange event).
    _sidecarSubtitles.deselect();
    await _methodChannel?.setSubtitleTrack(track);
  }

  /// Gets the alternate audio tracks of the current media (multiple
  /// languages, audio description, commentary). Empty for single-audio
  /// content. Issues #23/#16.
  Future<List<NativeVideoPlayerAudioTrack>> getAvailableAudioTracks() async {
    return await _methodChannel?.getAvailableAudioTracks() ??
        <NativeVideoPlayerAudioTrack>[];
  }

  /// Selects an alternate audio track from [getAvailableAudioTracks].
  /// Control listeners receive a [PlayerControlState.audioTrackChanged] event.
  Future<void> setAudioTrack(NativeVideoPlayerAudioTrack track) async {
    await _methodChannel?.setAudioTrack(track);
  }

  /// Replaces the sidecar (external VTT/SRT) subtitle sources.
  ///
  /// Selection resets to off; use [setSubtitleTrack] with one of the sidecar
  /// entries from [getAvailableSubtitleTracks] to activate one. On Android,
  /// URL sources are also attached natively so captions can render in PiP
  /// and native fullscreen.
  Future<void> setSidecarSubtitles(
    List<NativeVideoPlayerSidecarSubtitle> sources,
  ) async {
    _sidecarSubtitles.setSources(sources);
    final androidMaps = _androidSidecarMaps(sources);
    if (androidMaps != null && _methodChannel != null) {
      await _methodChannel!.setSidecarSubtitles(androidMaps);
    }
  }

  /// Hands sidecar caption rendering between the Flutter overlay and
  /// Android's native SubtitleView depending on context: PiP and NATIVE
  /// fullscreen don't show Flutter UI, so the natively sideloaded track is
  /// selected there; Dart fullscreen (custom overlay) keeps the Flutter
  /// overlay. iOS has no native sideload — the overlay simply hides in PiP.
  void _syncNativeSidecarCaptions(NativeVideoPlayerState state) {
    if (kIsWeb || !Platform.isAndroid) {
      return;
    }
    final int? selected = _sidecarSubtitles.selectedSource;
    if (selected == null) {
      return;
    }
    // PiP suppresses captions entirely (see _suppressSubtitlesForPip); only
    // hand off to the native SubtitleView for non-PiP native-fullscreen
    // contexts where the Flutter overlay is not visible.
    final bool nativeContext =
        !state.isPipEnabled && state.isFullScreen && !_hasCustomOverlay;
    unawaited(
      _methodChannel?.setNativeSidecarActive(
        active: nativeContext,
        language: nativeContext
            ? _sidecarSubtitles.sources[selected].language
            : null,
      ),
    );
  }

  /// Hides all native subtitle rendering while in Android PiP and restores the
  /// prior selection on leaving it.
  ///
  /// In PiP the Flutter subtitle overlay is not part of the (tiny) PiP window,
  /// so captions are rendered by the native Media3 `SubtitleView` at the system
  /// default size — which looks oversized in the small window. Toggling the
  /// player's text track type (shared across views) suppresses every subtitle
  /// source (embedded and sidecar) with one call; the native side snapshots the
  /// pre-PiP state so the exact selection resumes on exit. Android-only — iOS
  /// has no native sideload and already hides the overlay in PiP.
  void _suppressSubtitlesForPip(bool suppressed) {
    if (kIsWeb || !Platform.isAndroid) {
      return;
    }
    unawaited(_methodChannel?.setSubtitlesSuppressedForPip(suppressed));
  }

  /// Ground-truth Picture-in-Picture status.
  ///
  /// [isPipEnabled] is event-driven on iOS but poll-derived on Android
  /// (150 ms cadence, and only while fullscreen), so it can be stale at
  /// exactly the moment the app backgrounds into PiP. On Android this
  /// queries the platform's `isInPictureInPictureMode` directly and
  /// refreshes the synchronous flag with the result; pause decisions made
  /// on lifecycle transitions (see BackgroundPlaybackGuard) must use this
  /// instead of [isPipEnabled].
  ///
  /// On iOS it asks the native views of this controller, including a view
  /// kept alive only for its open window, and replays a `pipStop` event that
  /// never reached Dart. It never reopens PiP: `pipStop` is sent before the
  /// window finishes closing, so a query in between still finds it open.
  ///
  /// Falls back to the last known flag if the platform query fails.
  Future<bool> getPictureInPictureStatus() async {
    if (kIsWeb || _isDisposed) {
      return _state.isPipEnabled;
    }

    if (Platform.isIOS) {
      final bool? isPictureInPictureActive = await _methodChannel
          ?.isPictureInPictureActive();
      if (isPictureInPictureActive == false && _state.isPipEnabled) {
        _handleControllerEvent(<String, Object>{
          'event': 'pipStop',
          'isPictureInPicture': false,
        });
      }
      return _state.isPipEnabled;
    }

    if (!Platform.isAndroid) {
      return _state.isPipEnabled;
    }

    try {
      final bool inPip = await _androidPip.isInPictureInPicture;
      if (!_isDisposed && inPip != _state.isPipEnabled) {
        _updateState(_state.copyWith(isPipEnabled: inPip));
      }
      return inPip;
    } catch (_) {
      return _state.isPipEnabled;
    }
  }

  /// Starts/stops polling Android's PiP status so [isPipEnabled] reflects the
  /// real PiP state.
  ///
  /// Unlike iOS (which emits `pipStart`/`pipStop` natively), Android surfaces
  /// no PiP enter/exit callback to the plugin. We instead poll the cheap
  /// one-shot [AndroidPictureInPicture.isInPictureInPicture] only while
  /// fullscreen — the only
  /// state from which Android PiP can be entered — and tear it down otherwise.
  /// Updating the state here lets the existing `_updateState` cascade hide the
  /// Flutter subtitle overlay, suppress native captions, and emit the stream.
  void _updateAndroidPipPolling(NativeVideoPlayerState state) {
    if (kIsWeb || !Platform.isAndroid || !allowsPictureInPicture) {
      return;
    }
    if (state.isFullScreen && _androidPipPollTimer == null) {
      Future<void> checkPipStatus() async {
        if (_isDisposed) {
          return;
        }
        final bool inPip = await _androidPip.isInPictureInPicture;
        if (!_isDisposed && inPip != _state.isPipEnabled) {
          _updateState(_state.copyWith(isPipEnabled: inPip));

          if (!inPip) {
            unawaited(_handleAndroidPipExit());
          }
        }
      }

      _androidPipPollTimer = Timer.periodic(
        const Duration(milliseconds: 150),
        (_) => unawaited(checkPipStatus()),
      );
      // First check at t=0 — waiting a full tick leaves [isPipEnabled] stale
      // exactly when lifecycle-transition pause decisions read it.
      unawaited(checkPipStatus());
    } else if (!state.isFullScreen && _androidPipPollTimer != null) {
      _androidPipPollTimer!.cancel();
      _androidPipPollTimer = null;
      // Leaving fullscreen necessarily means leaving PiP; reset the flag.
      if (_state.isPipEnabled) {
        _updateState(_state.copyWith(isPipEnabled: false));
      }
    }
  }

  /// Pauses playback when the PiP window was dismissed with its close (X)
  /// button. Dismissing stops the activity without bringing the app back to
  /// the foreground, so without this the media session keeps playing audio in
  /// the background. Expanding the PiP window back into the app also flips the
  /// PiP flag off, but the app stays visible: Flutter reports `inactive` until
  /// the window regains focus, which on some devices only happens on the next
  /// touch, so waiting for `resumed` misread an expand as a dismiss. Only a
  /// lifecycle that reports the app hidden (`hidden`/`paused`) means the
  /// window was dismissed.
  ///
  /// An expand calls [onPictureInPictureRestore] instead: the same handler
  /// an app sets for iOS, where the window outlives its screen.
  Future<void> _handleAndroidPipExit() async {
    final AndroidPipExit exit = await PipRestore.classifyAndroidPipExit(
      lifecycle: () => WidgetsBinding.instance.lifecycleState,
      isStillOutOfPip: () => !_isDisposed && !_state.isPipEnabled,
    );
    switch (exit) {
      case AndroidPipExit.dismissed:
        debugPrint('PiP window dismissed while app is backgrounded — pausing');
        await pause();
      case AndroidPipExit.expanded:
        await PipRestore.callHandler(id);
      case AndroidPipExit.undecided:
        break;
    }
  }

  /// Maps URL sources for Android's native sideloading; null on other
  /// platforms or when there is nothing to attach.
  List<Map<String, dynamic>>? _androidSidecarMaps(
    List<NativeVideoPlayerSidecarSubtitle>? sources,
  ) {
    if (kIsWeb || !Platform.isAndroid || sources == null) {
      return null;
    }
    final maps = [
      for (final s in sources)
        if (s.url != null) s.toMap(),
    ];
    return maps.isEmpty ? null : maps;
  }

  /// Notifies control listeners about a sidecar subtitle selection, matching
  /// the event shape the native side emits for embedded tracks.
  void _emitSubtitleChanged(NativeVideoPlayerSubtitleTrack track) {
    final event = PlayerControlEvent(
      state: PlayerControlState.subtitleTrackChanged,
      data: track.toMap(),
    );
    for (final handler in _controlEventHandlers) {
      handler(event);
    }
  }

  /// Returns whether Picture-in-Picture is available on this device
  /// Checks the actual device capabilities rather than just the platform
  /// PiP is available on iOS 14+ and Android 8+ (if the device supports it)
  /// For Android, also requires the video to be in fullscreen mode
  /// Respects the allowsPictureInPicture setting
  Future<bool> isPictureInPictureAvailable() async {
    // Check if PiP is allowed by controller settings
    if (!allowsPictureInPicture) {
      return false;
    }

    // Android: the plugin's activity-level PiP
    if (!kIsWeb && Platform.isAndroid) {
      // Only available when in fullscreen on Android
      if (!_state.isFullScreen) {
        return false;
      }
      return await _androidPip.isAvailable;
    }

    // Use method channel for iOS
    if (_methodChannel == null) {
      return false;
    }
    return await _methodChannel!.isPictureInPictureAvailable();
  }

  /// Calculates the aspect ratio for PiP based on video quality information
  /// Returns the video aspect ratio, or 16:9 if unavailable
  PipAspectRatio _getPiPAspectRatio() {
    // Try to get dimensions from the current quality
    if (_state.qualities.isNotEmpty) {
      // Look for quality with dimensions
      for (final quality in _state.qualities) {
        if (quality.width != null && quality.height != null) {
          final width = quality.width!;
          final height = quality.height!;
          debugPrint(
            'Using video aspect ratio for PiP: $width:$height (${width / height})',
          );
          return PipAspectRatio(width, height);
        }
      }
    }

    // Default to 16:9 if we can't determine the aspect ratio
    debugPrint('Using default 16:9 aspect ratio for PiP');
    return const PipAspectRatio(16, 9);
  }

  /// Enables automatic PiP on Android when app goes to background
  /// Only enabled when video is in fullscreen
  Future<void> _enableAutomaticPiP() async {
    if (!kIsWeb &&
        Platform.isAndroid &&
        canStartPictureInPictureAutomatically &&
        _state.isFullScreen) {
      try {
        await _androidPip.enableOnLeave(_getPiPAspectRatio());
        debugPrint('Automatic PiP enabled (fullscreen mode)');
      } catch (e) {
        debugPrint('Error enabling automatic PiP: $e');
      }
    }
  }

  /// Enters Picture-in-Picture mode immediately
  /// Only works on iOS 14+ and Android 8+
  /// For Android, only works when video is in fullscreen
  Future<bool> enterPictureInPicture() async {
    // Android: the plugin's activity-level PiP
    if (!kIsWeb && Platform.isAndroid) {
      // Only allow PiP when in fullscreen
      if (!_state.isFullScreen) {
        debugPrint('PiP requires fullscreen mode on Android');
        return false;
      }

      try {
        // Emit event to hide overlay before entering PiP
        _emitPipStartedEvent();

        // Give overlay time to hide
        await Future.delayed(const Duration(milliseconds: 200));

        final bool entered = await _androidPip.enterNow(
          _getPiPAspectRatio(),
        );
        if (entered) {
          // Reflect PiP immediately so the subtitle overlay hides without
          // waiting for the next poll tick; the poll then tracks the exit.
          _updateState(_state.copyWith(isPipEnabled: true));
        }
        return entered;
      } catch (e) {
        debugPrint('Error entering PiP: $e');
        return false;
      }
    }

    // iOS: a PiP request right after exitFullScreen must reach the inline
    // view, not the fullscreen view that is about to be disposed.
    await _waitForClosingFullscreenViews();

    // iOS: PiP needs an on-screen AVPlayerLayer. A texture-rendered tile
    // has none — swap it to a platform view first (same shared player and
    // position, visually seamless); the tile stays a platform view after.
    if (_primaryViewIsTexture) {
      final swapped = await _requestSurfaceSwap();
      if (!swapped) {
        debugPrint(
          'PiP unavailable: texture tile could not swap to a platform view',
        );
        return false;
      }
    }

    // Use method channel for iOS
    if (_methodChannel == null) {
      return false;
    }
    return await _methodChannel!.enterPictureInPicture();
  }

  /// Called when the user takes the Picture-in-Picture window back into the
  /// app, to open the screen the video belongs to (on iOS its screen may
  /// have closed while the window was open).
  ///
  /// iOS (the window's "back to app" button): the window waits while the
  /// handler runs (at most 1.5 s) and then until
  /// a player of this controller is fully visible: built, on the top route
  /// with its transition done, and not cut off by a scroll view or the
  /// screen edge (at most 1 s more). It then flies into that player; without
  /// one it closes in place and the video plays on. Start the navigation and
  /// return: don't await a push whose future completes when the route is
  /// popped. Check [isPlayerFullyVisible] first to skip navigating when the
  /// player already shows.
  ///
  /// Android (the window expanded back into the app): the whole activity was
  /// the window, so the app comes back as it was, normally still on this
  /// player's fullscreen. Called once the app is back, which on devices that
  /// only report it on the next touch takes up to 3 s; nothing waits for it.
  ///
  /// Not called when the window closes through [exitPictureInPicture] or
  /// [dispose], nor when the user closes it with its X. Controllers sharing
  /// an [id] share one window: the handler set last is used.
  FutureOr<void> Function()? get onPictureInPictureRestore =>
      _onPictureInPictureRestore;
  set onPictureInPictureRestore(FutureOr<void> Function()? handler) {
    PipRestore.clearHandler(id, _onPictureInPictureRestore);
    _onPictureInPictureRestore = handler;
    if (handler != null) {
      PipRestore.setHandler(id, handler);
    }
  }

  FutureOr<void> Function()? _onPictureInPictureRestore;

  /// Whether a player of this controller is fully visible: on the top route
  /// with its transition done, and not cut off by a scroll view, a clip or
  /// the screen edge.
  bool get isPlayerFullyVisible => ViewVisibility.isControllerFullyVisible(id);

  /// Exits Picture-in-Picture mode
  /// Only works on iOS 14+ and Android 8+
  Future<bool> exitPictureInPicture() async {
    // Android: the plugin's activity-level PiP
    if (!kIsWeb && Platform.isAndroid) {
      try {
        // Cancel automatic PiP if it was enabled
        unawaited(_androidPip.cancelOnLeave());
        // Re-enable automatic PiP if it was originally configured and still in fullscreen
        if (canStartPictureInPictureAutomatically && _state.isFullScreen) {
          await _enableAutomaticPiP();
        }
        // Android has no call to leave PiP; it ends when the activity
        // returns to the foreground
        return true;
      } catch (e) {
        debugPrint('Error exiting PiP: $e');
        return false;
      }
    }

    // Use method channel for iOS
    if (_methodChannel == null) {
      return false;
    }
    final successfully = await _methodChannel!.exitPictureInPicture();

    _emitCurrentState();

    return successfully;
  }

  /// Enables automatic inline Picture-in-Picture mode
  ///
  /// When enabled, PiP will automatically start when the app goes to background
  /// (iOS 14.2+) or when the user presses the home button (Android 8+).
  ///
  /// **Platform Support:**
  /// - iOS: Requires iOS 14.2+ and video must be playing
  /// - Android: Requires Android 8+ and video must be in fullscreen
  ///
  /// **Returns:**
  /// A Future that completes with true if automatic PiP was successfully enabled
  ///
  /// **Usage:**
  /// ```dart
  /// // Enable automatic inline PiP
  /// final success = await controller.enableAutomaticInlinePip();
  /// if (success) {
  ///   print('Automatic PiP enabled');
  /// }
  /// ```
  Future<bool> enableAutomaticInlinePip() async {
    if (_methodChannel == null) {
      return false;
    }

    try {
      // Android: arm the plugin's automatic PiP
      if (!kIsWeb && Platform.isAndroid) {
        // Only enable if in fullscreen
        if (!_state.isFullScreen) {
          debugPrint(
            'Cannot enable automatic PiP on Android: video must be in fullscreen',
          );
          return false;
        }
        await _enableAutomaticPiP();
        return true;
      }

      // iOS: enable through method channel
      return await _methodChannel!.enableAutomaticInlinePip();
    } catch (e) {
      debugPrint('Error enabling automatic inline PiP: $e');
      return false;
    }
  }

  /// Disables automatic inline Picture-in-Picture mode
  ///
  /// When disabled, PiP will NOT automatically start when the app goes to background.
  /// Manual PiP through [enterPictureInPicture] will still work.
  ///
  /// **Platform Support:**
  /// - iOS: Requires iOS 14.2+
  /// - Android: Requires Android 8+
  ///
  /// **Returns:**
  /// A Future that completes with true if automatic PiP was successfully disabled
  ///
  /// **Usage:**
  /// ```dart
  /// // Disable automatic inline PiP
  /// final success = await controller.disableAutomaticInlinePip();
  /// if (success) {
  ///   print('Automatic PiP disabled');
  /// }
  /// ```
  Future<bool> disableAutomaticInlinePip() async {
    if (_methodChannel == null) {
      return false;
    }

    try {
      // Android: disarm the plugin's automatic PiP
      if (!kIsWeb && Platform.isAndroid) {
        unawaited(_androidPip.cancelOnLeave());
        debugPrint('Automatic PiP disabled (Android)');
        return true;
      }

      // iOS: disable through method channel
      return await _methodChannel!.disableAutomaticInlinePip();
    } catch (e) {
      debugPrint('Error disabling automatic inline PiP: $e');
      return false;
    }
  }

  /// Toggles Picture-in-Picture mode
  /// Only works on iOS 14+ and Android 8+
  /// Returns true if the operation was successful
  Future<bool> togglePictureInPicture() async {
    if (_state.isPipEnabled) {
      return await exitPictureInPicture();
    } else {
      return await enterPictureInPicture();
    }
  }

  /// Enters fullscreen mode
  /// Uses Dart fullscreen if custom overlay is present, otherwise uses native fullscreen
  Future<void> enterFullScreen() async {
    if (_state.isFullScreen) {
      return;
    }

    // Nothing loaded yet: the flight carries what the player shows in
    // Flutter, taken now, before its overlay hears about fullscreen (an app
    // may restyle it for fullscreen, e.g. a back button).
    final Future<Uint8List?>? inlineLayers = _hasVideoFrame
        ? null
        : _snapshotOfView(_fullscreenContext);

    _updateState(_state.copyWith(isFullScreen: true));

    // Enable automatic PiP and refresh availability immediately after entering fullscreen on Android
    // This ensures isPipAvailable is updated before the UI rebuilds
    if (!kIsWeb && Platform.isAndroid) {
      await _enableAutomaticPiP();
      await _refreshAvailabilityFlags();
    }

    // Texture-rendered views have no native view to expand: always use the
    // Dart fullscreen route for them, overlay or not.
    if ((_hasCustomOverlay || _primaryViewIsTexture) &&
        _fullscreenContext != null) {
      _usedDartFullscreen = true;

      // Emit fullscreen entered event
      final controlEvent = PlayerControlEvent(
        state: PlayerControlState.fullscreenEntered,
        data: <String, dynamic>{'isFullscreen': true},
      );
      for (final handler in _controlEventHandlers) {
        handler(controlEvent);
      }

      // Use Dart fullscreen when we have a custom overlay
      await _enterDartFullscreen(inlineLayers: inlineLayers);
    } else {
      // Use native fullscreen when no custom overlay
      await _methodChannel?.enterFullScreen();
    }
  }

  /// Exits fullscreen mode
  /// Handles both Dart and native fullscreen exit
  Future<void> exitFullScreen() async {
    if (!_state.isFullScreen) {
      return;
    }

    _updateState(_state.copyWith(isFullScreen: false));

    // Disable automatic PiP and refresh availability immediately after exiting fullscreen on Android
    // This ensures isPipAvailable is updated before the UI rebuilds
    if (!kIsWeb && Platform.isAndroid) {
      unawaited(_androidPip.cancelOnLeave());
      debugPrint('Automatic PiP disabled (exited fullscreen)');
      await _refreshAvailabilityFlags();
    }

    if (_hasCustomOverlay || _usedDartFullscreen) {
      _usedDartFullscreen = false;

      // Dart fullscreen: use dedicated callback to close the dialog
      _dartFullscreenCloseCallback?.call();

      // Emit event for other listeners (but don't use it to close the dialog)
      final controlEvent = PlayerControlEvent(
        state: PlayerControlState.fullscreenExited,
        data: <String, dynamic>{'isFullscreen': false},
      );
      for (final handler in _controlEventHandlers) {
        handler(controlEvent);
      }
    } else {
      // Use native fullscreen
      await _methodChannel?.exitFullScreen();
    }
  }

  /// Applies a fullscreen change that the native side has *already* performed.
  ///
  /// The native platform view emits `fullscreenChange` after every toggle,
  /// including toggles it made itself (the user tapping PlayerView's
  /// fullscreen button). Routing that event through [enterFullScreen] /
  /// [exitFullScreen] sent the command straight back down the method channel,
  /// so one tap ran the native transition twice — on entry that built a second
  /// fullscreen Dialog over the first, orphaning it as an opaque black window
  /// that only the back button could dismiss.
  ///
  /// This mirrors their bookkeeping — state, Android auto-PiP arming, and
  /// closing a Dart fullscreen host — without re-issuing the platform call.
  Future<void> _syncFullScreenFromNative(bool isFullscreen) async {
    if (_state.isFullScreen == isFullscreen) {
      return;
    }

    _updateState(_state.copyWith(isFullScreen: isFullscreen));

    if (!kIsWeb && Platform.isAndroid) {
      if (isFullscreen) {
        await _enableAutomaticPiP();
      } else {
        unawaited(_androidPip.cancelOnLeave());
        debugPrint('Automatic PiP disabled (native exited fullscreen)');
      }
      await _refreshAvailabilityFlags();
    }

    // A Dart fullscreen host is Dart's to close; native cannot dismiss it.
    if (!isFullscreen && (_hasCustomOverlay || _usedDartFullscreen)) {
      _usedDartFullscreen = false;
      _dartFullscreenCloseCallback?.call();
    }

    // No control event here: the native fullscreenChange that called this
    // already reaches every control listener.
  }

  /// Enters Dart-based fullscreen mode
  Future<void> _enterDartFullscreen({Future<Uint8List?>? inlineLayers}) async {
    final context = _fullscreenContext;

    if (context == null) {
      // Fallback: reset state since we can't show fullscreen
      _updateState(_state.copyWith(isFullScreen: false));
      return;
    }

    final FullscreenHeroFlight? heroFlight = await _fullscreenHeroFlight(
      context,
      inlineLayers: inlineLayers,
    );
    if (!context.mounted) {
      _updateState(_state.copyWith(isFullScreen: false));
      return;
    }

    if (heroFlight != null) {
      _fullscreenFlightPhase.value = FullscreenFlightPhase.out;
    }
    await FullscreenManager.showFullscreenDialog(
      context: context,
      builder: (dialogContext) {
        return FullscreenVideoPlayer(
          controller: this,
          overlayBuilder: _overlayBuilder,
          subtitleStyle:
              _subtitleStyle ?? const NativeVideoPlayerSubtitleStyle(),
          heroFlight: heroFlight,
        );
      },
      lockToLandscape: lockToLandscape,
      heroFlight: heroFlight,
      onExit: () {
        // (With a flight, the phase is the flight's to end: the push future
        // completes when the pop starts, not when the video has landed.)
        if (heroFlight == null) {
          _fullscreenFlightPhase.value = FullscreenFlightPhase.none;
        } else {
          _endFlightPhaseLater();
        }
        // Update state when fullscreen dialog is dismissed by user (back button, etc.)
        _dartFullscreenCloseCallback = null;
        if (_state.isFullScreen) {
          _updateState(_state.copyWith(isFullScreen: false));

          // Mirror exitFullScreen(): leaving fullscreen must disarm the
          // activity-global automatic PiP, otherwise auto-PiP stays armed for the
          // rest of the session and any later app-leave enters PiP — even from
          // inline playback or with no video playing at all.
          if (!kIsWeb && Platform.isAndroid) {
            unawaited(_androidPip.cancelOnLeave());
            debugPrint('Automatic PiP disabled (fullscreen dialog dismissed)');
            unawaited(_refreshAvailabilityFlags());
          }
        }
      },
    );
  }

  /// Lets Dart fullscreen grow out of the inline player [context] belongs
  /// to. Null (fullscreen fades in) without a frame to fly (Android: the
  /// flight hides the fullscreen view meanwhile, and hiding a hybrid
  /// composition view leaves a stale image behind; or the capture failed)
  /// or when the screen turns on the way in (a landscape lock from portrait
  /// would leave the inline rect behind).
  Future<FullscreenHeroFlight?> _fullscreenHeroFlight(
    BuildContext context, {
    Future<Uint8List?>? inlineLayers,
  }) async {
    int? viewId;
    _platformViewContexts.forEach((id, ctx) {
      if (identical(ctx, context)) viewId = id;
    });
    final Rect? startRect = _globalRectOf(context);
    final Size screenSize = MediaQuery.sizeOf(context);
    if (viewId == null ||
        startRect == null ||
        (lockToLandscape && screenSize.height > screenSize.width)) {
      return null;
    }
    final int maxWidth =
        (screenSize.longestSide * MediaQuery.devicePixelRatioOf(context))
            .round();
    // Android: only texture tiles fly (live, through the player's active
    // texture); a hybrid-composition view can't be hidden under a flight
    // without leaving a stale image behind.
    final bool androidTexture =
        defaultTargetPlatform == TargetPlatform.android &&
        _textureViewIds.contains(viewId);
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (!androidTexture) return null;
      // Nothing loaded yet: fly what the player shows in Flutter instead.
      final bool hasFrame = _hasVideoFrame;
      final Uint8List? layers = hasFrame
          ? null
          : await (inlineLayers ?? _viewSnapshots[viewId]?.call());
      if (!hasFrame && layers == null) return null;
      if (layers != null && context.mounted) {
        await precacheImage(MemoryImage(layers), context);
      }
      if (!context.mounted) return null;
      return FullscreenHeroFlight(
        poster: layers ?? _posterFrame,
        sharedTexture: hasFrame ? _activeTextureId : null,
        startRect: startRect,
        inlineRect: () => context.mounted ? _globalRectOf(context) : null,
        capturePoster: () async => null,
        // The snapshot flies at its own shape (the inline player's), like
        // the video would at its own.
        videoAspectRatio: layers != null
            ? await _imageAspectRatio(layers)
            : _videoSize?.aspectRatio,
        onReturn: () => unawaited(FullscreenManager.restoreSystemUi()),
        onLanding: () => _landFlight(viewId!),
        onDone: () => _fullscreenFlightPhase.value = FullscreenFlightPhase.none,
        inlineBorderRadius: fullscreenFlightBorderRadius,
      );
    }

    // The primary view: this one now, the fullscreen view on the way back.
    // Nothing loaded yet: what that view shows in Flutter (poster, controls).
    Future<Uint8List?> capture() => capturePosterFrame(
      _primaryPlatformViewId ?? viewId!,
      maxWidth: maxWidth,
    );

    // Live video for the flight (iOS): the shared player as a plain engine
    // texture, which flies like any Flutter content.
    Future<int?> createLiveTexture() =>
        defaultTargetPlatform == TargetPlatform.iOS
        ? VideoPlayerMethodChannel.createFlightTexture(id)
        : Future<int?>.value();
    final Future<int?> liveTexture = createLiveTexture().timeout(
      const Duration(milliseconds: 250),
      onTimeout: () => null,
    );

    // Waits only briefly: a frame from the last pause beats a late start.
    final Uint8List? poster = await capture().timeout(
      const Duration(milliseconds: 250),
      onTimeout: () => _posterFrame,
    );
    final int? liveTextureId = await liveTexture;
    void disposeLiveTexture(int textureId) =>
        unawaited(VideoPlayerMethodChannel.disposeFlightTexture(textureId));
    // No frame (nothing loaded yet): fly what the player shows in Flutter.
    final Uint8List? flown =
        poster ??
        (_hasVideoFrame || !context.mounted
            ? null
            : await (inlineLayers ?? _viewSnapshots[viewId]?.call()));
    if (flown == null || !context.mounted) {
      if (liveTextureId != null) disposeLiveTexture(liveTextureId);
      return null;
    }
    await precacheImage(MemoryImage(flown), context);
    if (!context.mounted) {
      if (liveTextureId != null) disposeLiveTexture(liveTextureId);
      return null;
    }
    return FullscreenHeroFlight(
      createLiveTexture: createLiveTexture,
      disposeLiveTexture: disposeLiveTexture,
      liveTextureId: liveTextureId,
      poster: flown,
      startRect: startRect,
      inlineRect: () => context.mounted ? _globalRectOf(context) : null,
      capturePoster: capture,
      // A snapshot of the player's layers flies at its own shape (the
      // inline player's), like a video frame at the video's.
      videoAspectRatio: poster != null
          ? await _aspectRatioOf(flown)
          : await _imageAspectRatio(flown),
      currentAspectRatio: () => _hasVideoFrame ? _videoSize?.aspectRatio : null,
      onReturn: () => unawaited(FullscreenManager.restoreSystemUi()),
      onLanding: () => _landFlight(viewId!),
      onDone: () => _fullscreenFlightPhase.value = FullscreenFlightPhase.none,
      inlineBorderRadius: fullscreenFlightBorderRadius,
    );
  }

  /// Backstop for the flight ending the phase: a route closed before its
  /// flight was built, or whose way back was cut short (iOS PiP starting as
  /// fullscreen closes), never would, and the inline slot would stay empty
  /// for good while the video plays on. Runs once the way back is surely
  /// over, unless fullscreen opened again meanwhile.
  void _endFlightPhaseLater() {
    Timer(const Duration(milliseconds: 800), () {
      if (_isDisposed || _state.isFullScreen) return;
      if (_fullscreenFlightPhase.value != FullscreenFlightPhase.none) {
        _fullscreenFlightPhase.value = FullscreenFlightPhase.none;
      }
    });
  }

  /// The way back has nearly landed (the flight covers the inline slot):
  /// the slot shows the video again, and an Android texture tile gets the
  /// player's output back now, so it has fresh frames by the time the
  /// flight is gone (instead of a frame from before fullscreen). The flight
  /// keeps showing the fullscreen texture until then, so it never goes
  /// stale mid-air.
  void _landFlight(int inlineViewId) {
    _fullscreenFlightPhase.value = FullscreenFlightPhase.returning;
    if (defaultTargetPlatform == TargetPlatform.android &&
        _textureIdsByView.containsKey(inlineViewId)) {
      unawaited(VideoPlayerMethodChannel.reattachSurface(inlineViewId));
    }
  }

  /// The video's aspect ratio: reported by the player, else the frame's own.
  Future<double?> _aspectRatioOf(Uint8List frame) async {
    final double? reported = _videoSize?.aspectRatio;
    if (reported != null && reported.isFinite && reported > 0) return reported;
    return _imageAspectRatio(frame);
  }

  /// The snapshot of what [context]'s player view shows in Flutter.
  Future<Uint8List?>? _snapshotOfView(BuildContext? context) {
    if (context == null) return null;
    for (final MapEntry<int, BuildContext> entry
        in _platformViewContexts.entries) {
      if (identical(entry.value, context)) {
        return _viewSnapshots[entry.key]?.call();
      }
    }
    return null;
  }

  /// Width / height of an encoded image.
  static Future<double?> _imageAspectRatio(Uint8List bytes) async {
    try {
      final image = await decodeImageFromList(bytes);
      final double aspectRatio = image.width / image.height;
      image.dispose();
      return aspectRatio;
    } catch (_) {
      return null;
    }
  }

  static Rect? _globalRectOf(BuildContext context) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
  }

  /// Toggles fullscreen mode
  Future<void> toggleFullScreen() async {
    if (_state.isFullScreen) {
      await exitFullScreen();
    } else {
      await enterFullScreen();
    }
  }

  /// Sets whether native player controls are shown
  ///
  /// This is useful when you want to use custom overlay controls instead of
  /// the native player controls.
  ///
  /// **Parameters:**
  /// - show: true to show native controls, false to hide them
  Future<void> setShowNativeControls(bool show) async {
    await _methodChannel?.setShowNativeControls(show);
  }

  /// Checks if AirPlay is available on the device
  ///
  /// This is only available on iOS. On Android, this always returns false.
  /// Use this method to conditionally show/hide AirPlay buttons in your UI.
  ///
  /// **Returns:**
  /// A Future that resolves to true if AirPlay is available, false otherwise
  Future<bool> isAirPlayAvailable() async {
    if (_methodChannel == null) {
      return false;
    }
    return await _methodChannel!.isAirPlayAvailable();
  }

  /// Shows the AirPlay route picker for selecting AirPlay devices
  ///
  /// This is only available on iOS. On Android, this method does nothing.
  /// Displays the native iOS AirPlay picker UI to allow users to select
  /// an AirPlay device for video output.
  ///
  /// **Returns:**
  /// A Future that completes when the picker is shown (or immediately on Android)
  Future<void> showAirPlayPicker() async {
    if (_methodChannel == null) {
      return;
    }
    await _methodChannel!.showAirPlayPicker();
  }

  /// Disconnects from the currently connected AirPlay device (iOS only)
  ///
  /// This method stops sending video to the AirPlay device. The user can
  /// reconnect to AirPlay later using the AirPlay picker.
  ///
  /// Throws a [PlatformException] if:
  /// - Not currently connected to AirPlay
  /// - Player is not initialized
  ///
  /// Example:
  /// ```dart
  /// if (controller.isAirplayConnected) {
  ///   await controller.disconnectAirPlay();
  /// }
  /// ```
  Future<void> disconnectAirPlay() async {
    if (_methodChannel == null) {
      throw StateError('Player not initialized');
    }
    await _methodChannel!.disconnectAirPlay();
  }

  /// Locks the custom overlay to be always visible
  ///
  /// When the overlay is locked, it cannot be dismissed by tapping or by auto-hide timer.
  /// This is useful when you want to keep controls always visible, such as during
  /// live streams, interactive content, or when the user needs constant access to controls.
  ///
  /// **Usage:**
  /// ```dart
  /// // Lock overlay to always be visible
  /// controller.lockOverlay();
  /// ```
  ///
  /// To unlock the overlay and restore normal behavior, call [unlockOverlay].
  void lockOverlay() {
    final wasLocked = isOverlayLocked;
    _isOverlayLocked = true;
    _emitOverlayLock(wasLocked);
  }

  /// Unlocks the custom overlay to allow it to be dismissed
  ///
  /// When the overlay is unlocked, it can be dismissed by tapping or will auto-hide
  /// after a period of inactivity (default 3 seconds).
  ///
  /// **Usage:**
  /// ```dart
  /// // Unlock overlay to allow normal tap-to-hide behavior
  /// controller.unlockOverlay();
  /// ```
  ///
  /// To lock the overlay again and keep it always visible, call [lockOverlay].
  void unlockOverlay() {
    final wasLocked = isOverlayLocked;
    _isOverlayLocked = false;
    _emitOverlayLock(wasLocked);
  }

  /// Releases Flutter-side resources while keeping the native player alive
  ///
  /// Use this when navigating away from a screen but want to keep the video
  /// loaded and resume playback when returning. This pauses the video and
  /// cleans up Flutter resources (subscriptions, listeners, contexts) but
  /// does NOT dispose the native player.
  ///
  /// Perfect for:
  /// - Navigating between list and detail screens with the same video
  /// - Temporarily hiding a video player while keeping it loaded
  /// - Memory optimization without losing playback position
  ///
  /// **Usage:**
  /// ```dart
  /// @override
  /// void dispose() {
  ///   // Release Flutter resources but keep native player alive
  ///   _controller.releaseResources();
  ///   super.dispose();
  /// }
  /// ```
  Future<void> releaseResources() async {
    // Pause playback
    await pause();

    // Exit fullscreen if active
    if (_state.isFullScreen) {
      await exitFullScreen();
    }

    // Cancel all event channel subscriptions
    // Create a snapshot to avoid concurrent modification during iteration
    final subscriptions = _eventSubscriptions.values.toList();
    _eventSubscriptions.clear();
    for (final NativeEventSubscription subscription in subscriptions) {
      await subscription.cancel();
    }

    // Cancel PiP event subscription (Android only)
    await _safeCancelSubscription(_pipEventSubscription);
    _pipEventSubscription = null;

    // NOTE: Do NOT cancel _controllerEventSubscription here
    // The controller-level event channel persists to receive PiP/AirPlay events
    // even when all platform views are disposed. It's only cancelled in dispose().

    // Cancel buffering debounce timer
    _bufferingDebounceTimer?.cancel();
    _bufferingDebounceTimer = null;
    _endSeekHold();

    // Cancel the stalled-playback watchdogs — the handlers they would
    // notify are cleared below, and the native player is paused anyway.
    _cancelWatchdogs();

    // Clear all event handlers
    _activityEventHandlers.clear();
    _controlEventHandlers.clear();
    _airPlayAvailabilityHandlers.clear();
    _airPlayConnectionHandlers.clear();

    // Clear platform view references
    _platformViewIds.clear();
    _platformViewContexts.clear();
    _viewSnapshots.clear();
    _fullscreenViewIds.clear();
    _completeFullscreenViewsDisposed();
    _primaryPlatformViewId = null;

    // Clear method channel reference (but don't dispose native player)
    _methodChannel = null;
    _initializeCompleter = null;

    // Clear fullscreen callback (but keep overlay builder)
    _dartFullscreenCloseCallback = null;

    // Note: We do NOT clear _overlayBuilder so it persists across releases
    // The widget will call setOverlayBuilder() again when reconnecting
    // Note: We do NOT clear _state and _url so we can resume playback
    // Note: We do NOT call _methodChannel.dispose() to keep native player alive
    // Note: We do NOT close stream controllers so they can continue to be used
  }

  /// Fully disposes of all resources including the native player
  ///
  /// Should be called when the video player is no longer needed and will not
  /// be reused. This completely destroys both Flutter and native resources.
  ///
  /// For temporary cleanup while keeping the player alive, use [releaseResources] instead.
  ///
  /// **Usage:**
  /// ```dart
  /// @override
  /// void dispose() {
  ///   // Fully dispose when done with the controller
  ///   _controller.dispose();
  ///   super.dispose();
  /// }
  /// ```
  Future<void> dispose() async {
    // Prevent double disposal
    if (_isDisposed) {
      return;
    }

    // Mark as disposed immediately to prevent new events from being added
    _isDisposed = true;

    PipRestore.clearHandler(id, _onPictureInPictureRestore);
    _onPictureInPictureRestore = null;

    // Stop the Android PiP status poll.
    _androidPipPollTimer?.cancel();
    _androidPipPollTimer = null;

    // Stop the stalled-playback watchdogs.
    _cancelWatchdogs();

    // Remove from the playback coordinator (cap enforcement)
    PlaybackCoordinator.instance.unregister(_playableHandle);

    // Stop sidecar subtitle rendering/timers
    _sidecarSubtitles.dispose();

    // Wait for any in-flight controller-channel setup so it cannot subscribe
    // after teardown (its retries abort early now that _isDisposed is set).
    try {
      await _controllerChannelSetupFuture;
    } catch (e) {
      debugPrint('Controller channel setup failed during dispose: $e');
    }

    // Pause playback first to avoid crashes during disposal. Without a live
    // view (the widget usually unmounts first) the view-routed pause can only
    // fail with NO_VIEW; disposeController below stops the player instead.
    // Not while another controller with this ID still shows the player.
    if (_platformViewIds.isNotEmpty &&
        _state.activityState.isPlaying &&
        !_sharesNativePlayer) {
      await pause();
      // Give the native side a moment to process the pause
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // Exit fullscreen if active
    if (_state.isFullScreen) {
      await exitFullScreen();
    }

    // Cancel all event channel subscriptions BEFORE closing stream controllers
    // This prevents new events from coming in while we're closing
    // Create a snapshot to avoid concurrent modification during iteration
    final subscriptions = _eventSubscriptions.values.toList();
    _eventSubscriptions.clear();
    for (final NativeEventSubscription subscription in subscriptions) {
      await subscription.cancel();
    }

    // Cancel PiP event subscription (Android only)
    await _safeCancelSubscription(_pipEventSubscription);
    _pipEventSubscription = null;

    // Leave the controller-level event channel. The last controller with
    // this ID to leave cancels the subscription and then tears the native
    // channel down — after the cancel, so Dart's `cancel` hits a live
    // handler, and before the native player disposal below, so no event can
    // be emitted into a torn-down channel. Awaited so a recreate with the
    // same controller ID starts from a clean slate.
    await _sharedControllerEventChannel?.detach(this);

    // Cancel buffering debounce timer
    _bufferingDebounceTimer?.cancel();
    _bufferingDebounceTimer = null;
    _endSeekHold();

    // Clear all event handlers
    _activityEventHandlers.clear();
    _controlEventHandlers.clear();
    _airPlayAvailabilityHandlers.clear();
    _airPlayConnectionHandlers.clear();

    // Unregister method channel from AirPlay manager
    if (_methodChannel != null) {
      AirPlayStateManager.instance.unregisterMethodChannel(_methodChannel!);
    }

    // Another live controller with this ID (the same video on two screens)
    // shares the native player: leave it to that controller. The last
    // controller with the ID releases it.
    if (!_sharesNativePlayer) {
      await _releaseNativePlayer();
    }

    // Close all stream controllers
    await _bufferedPositionController.close();
    await _durationController.close();
    await _playerStateController.close();
    await _positionController.close();
    await _speedController.close();
    await _isPipEnabledController.close();
    await _isPipAvailableController.close();
    // Note: AirPlay stream controllers are managed by the global AirPlayStateManager
    await _isFullscreenController.close();
    await _isLiveController.close();
    await _qualityChangedController.close();
    await _qualitiesController.close();
    await _chaptersController.close();
    await _currentChapterController.close();
    await _isOverlayLockedController.close();
    await _videoSizeController.close();
    await _surfaceSwapRequests.close();

    // Clear platform view references
    _platformViewIds.clear();
    _platformViewContexts.clear();
    _viewSnapshots.clear();
    _textureViewIds.clear();
    _fullscreenViewIds.clear();
    _completeFullscreenViewsDisposed();
    _primaryPlatformViewId = null;

    // Clear overlay and fullscreen references
    _overlayBuilder = null;
    _dartFullscreenCloseCallback = null;

    // Clear other state
    _methodChannel = null;
    _url = null;
    _initializeCompleter = null;
  }

  /// Releases the native player for [id].
  Future<void> _releaseNativePlayer() async {
    // Dispose native player resources (removes shared player from manager).
    // Skipped without a live view for the same reason as the pause in
    // [dispose].
    if (_methodChannel != null && _platformViewIds.isNotEmpty) {
      await _methodChannel?.dispose();
    }

    // ALWAYS release by controller ID as the authoritative cleanup: the
    // view-routed dispose above races platform-view teardown when a feed
    // tile is unmounted (the call lands after the view unregistered →
    // NO_VIEW → silently dropped), which leaked one native player per
    // disposed controller until the OS killed the app (observed as an OOM
    // on a Galaxy S21 after a few six-player feed visits). disposeController
    // needs no view, and native removePlayer is idempotent on both
    // platforms, so running it after a successful view dispose is harmless.
    try {
      await _pluginMethodChannel.invokeMethod<void>('disposeController', {
        'controllerId': id,
      });
    } catch (e) {
      debugPrint('Failed to dispose native player for controller $id: $e');
    }
  }

  /// Internal method to emit pipStarted event (hides overlay before PiP)
  void _emitPipStartedEvent() {
    final controlEvent = PlayerControlEvent(
      state: PlayerControlState.pipStarted,
      data: <String, dynamic>{},
    );
    for (final handler in _controlEventHandlers) {
      handler(controlEvent);
    }
  }
}

/// Adapter exposing a controller to the [PlaybackCoordinator] without
/// widening the controller's public API.
class _ControllerPlayableHandle implements PlayableHandle {
  _ControllerPlayableHandle(this.controller);

  final NativeVideoPlayerController controller;

  @override
  int get id => controller.id;

  @override
  bool get isPipActive => controller._state.isPipEnabled;

  @override
  bool get isAirPlayConnected => controller._state.isAirplayConnected;

  @override
  Future<void> pauseForCap() => controller.pause();
}

/// App lifecycle observer to hide overlay before automatic PiP on Android
class _AppLifecycleObserver with WidgetsBindingObserver {
  _AppLifecycleObserver(this.controller);

  final NativeVideoPlayerController controller;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When app goes to background and we're in fullscreen with automatic PiP enabled,
    // hide the overlay before Android captures the screen for PiP
    if (state == AppLifecycleState.inactive &&
        controller._state.isFullScreen &&
        controller.canStartPictureInPictureAutomatically) {
      controller._emitPipStartedEvent();
    }

    // When app returns to foreground (after exiting PiP),
    // re-enable automatic PiP if still in fullscreen
    if (state == AppLifecycleState.resumed &&
        controller._state.isFullScreen &&
        controller.canStartPictureInPictureAutomatically) {
      controller._enableAutomaticPiP();
    }
  }
}

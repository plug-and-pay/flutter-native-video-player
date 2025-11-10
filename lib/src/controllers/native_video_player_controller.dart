import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../enums/native_video_player_event.dart';
import '../fullscreen/fullscreen_manager.dart';
import '../fullscreen/fullscreen_video_player.dart';
import '../models/native_video_player_media_info.dart';
import '../models/native_video_player_quality.dart';
import '../models/native_video_player_state.dart';
import '../platform/platform_utils.dart';
import '../platform/video_player_method_channel.dart';

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
    List<DeviceOrientation>? preferredOrientations,
  }) {
    // Set preferred orientations if provided
    if (preferredOrientations != null) {
      FullscreenManager.setPreferredOrientations(preferredOrientations);
    }
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

  /// BuildContext getter for showing Dart fullscreen dialog
  /// Returns a mounted context from any registered platform view
  BuildContext? get _fullscreenContext {
    // Try to find a mounted context from the registered platform views
    for (final viewId in _platformViewIds) {
      // We'll need to track contexts per platform view
      final ctx = _platformViewContexts[viewId];
      if (ctx != null && ctx.mounted) {
        return ctx;
      }
    }
    return null;
  }

  /// Map of platform view IDs to their contexts
  final Map<int, BuildContext> _platformViewContexts = <int, BuildContext>{};

  /// Overlay builder to use in fullscreen mode
  /// This is passed from NativeVideoPlayer widget
  Widget Function(BuildContext, NativeVideoPlayerController)? _overlayBuilder;

  /// Callback to close the Dart fullscreen dialog
  /// Set by FullscreenVideoPlayer when it's created
  VoidCallback? _dartFullscreenCloseCallback;

  /// Whether the overlay visibility is locked (cannot be dismissed)
  bool _isOverlayLocked = false;

  /// Whether we have a custom overlay (determines if we use Dart fullscreen and hide native controls)
  bool get _hasCustomOverlay => _overlayBuilder != null;

  /// Returns whether the overlay is currently locked (always visible)
  bool get isOverlayLocked => _isOverlayLocked;

  /// Stream controller for overlay lock state changes
  final StreamController<bool> _isOverlayLockedController =
      StreamController<bool>.broadcast();

  /// Stream of overlay lock state changes
  Stream<bool> get isOverlayLockedStream => _isOverlayLockedController.stream;

  /// Current state of the video player
  NativeVideoPlayerState _state = const NativeVideoPlayerState();

  /// Video URL set when load() is called
  String? _url;

  /// Method channel wrapper for platform communication
  VideoPlayerMethodChannel? _methodChannel;

  /// Set of platform view IDs that are using this controller
  final Set<int> _platformViewIds = <int>{};

  /// Primary platform view ID (most recent one registered)
  int? _primaryPlatformViewId;

  /// Updates the method channel to use the specified platform view ID
  void _updateMethodChannel(int platformViewId) {
    _primaryPlatformViewId = platformViewId;
    _methodChannel = VideoPlayerMethodChannel(
      primaryPlatformViewId: platformViewId,
    );
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
  final Map<int, StreamSubscription<dynamic>> _eventSubscriptions =
      <int, StreamSubscription<dynamic>>{};

  /// MainActivity PiP event channel subscription (Android only)
  StreamSubscription<dynamic>? _pipEventSubscription;

  /// MainActivity PiP event channel subscription (Android only)
  StreamSubscription<dynamic>? get pipEventSubscription =>
      _pipEventSubscription;

  /// Whether the MainActivity PiP event listener has been set up
  static bool _pipEventListenerSetup = false;

  /// Timer for buffering state debounce (400ms)
  Timer? _bufferingDebounceTimer;

  /// Track if we're currently in a buffering state (from native)
  bool _isCurrentlyBuffering = false;

  /// Track the last non-buffering activity state to restore after buffering
  PlayerActivityState? _lastNonBufferingState;

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
  final StreamController<bool> _isAirplayAvailableController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _isAirplayConnectedController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _isFullscreenController =
      StreamController<bool>.broadcast();
  final StreamController<NativeVideoPlayerQuality> _qualityChangedController =
      StreamController<NativeVideoPlayerQuality>.broadcast();
  final StreamController<List<NativeVideoPlayerQuality>> _qualitiesController =
      StreamController<List<NativeVideoPlayerQuality>>.broadcast();

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
    }
    if (oldState.currentPosition != newState.currentPosition) {
      if (!_positionController.isClosed) {
        _positionController.add(newState.currentPosition);
      }
    }
    if (oldState.speed != newState.speed) {
      if (!_speedController.isClosed) {
        _speedController.add(newState.speed);
      }
    }
    if (oldState.isPipEnabled != newState.isPipEnabled) {
      if (!_isPipEnabledController.isClosed) {
        _isPipEnabledController.add(newState.isPipEnabled);
      }
    }
    if (oldState.isPipAvailable != newState.isPipAvailable) {
      if (!_isPipAvailableController.isClosed) {
        _isPipAvailableController.add(newState.isPipAvailable);
      }
    }
    if (oldState.isAirplayAvailable != newState.isAirplayAvailable) {
      if (!_isAirplayAvailableController.isClosed) {
        _isAirplayAvailableController.add(newState.isAirplayAvailable);
      }
    }
    if (oldState.isAirplayConnected != newState.isAirplayConnected) {
      if (!_isAirplayConnectedController.isClosed) {
        _isAirplayConnectedController.add(newState.isAirplayConnected);
      }
    }
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
        // Check if we're still buffering after 400ms
        if (_isCurrentlyBuffering &&
            _state.activityState != PlayerActivityState.buffering) {
          // Update to buffering state
          _updateState(
            _state.copyWith(activityState: PlayerActivityState.buffering),
          );
        }
      });
    } else {
      // Buffering stopped - cancel the timer and restore previous state
      _bufferingDebounceTimer?.cancel();

      // If we were showing buffering state, restore the previous state
      if (_state.activityState == PlayerActivityState.buffering) {
        // Restore the last non-buffering state
        final restoredState =
            _lastNonBufferingState ?? PlayerActivityState.playing;
        _updateState(_state.copyWith(activityState: restoredState));
      }
    }
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
    if (!_isAirplayAvailableController.isClosed) {
      _isAirplayAvailableController.add(_state.isAirplayAvailable);
    }
    if (!_isAirplayConnectedController.isClosed) {
      _isAirplayConnectedController.add(_state.isAirplayConnected);
    }
    if (!_isFullscreenController.isClosed) {
      _isFullscreenController.add(_state.isFullScreen);
    }
    if (!_qualitiesController.isClosed && _state.qualities.isNotEmpty) {
      _qualitiesController.add(_state.qualities);
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
      final isPipAvailable = await _methodChannel!
          .isPictureInPictureAvailable();
      _state = _state.copyWith(isPipAvailable: isPipAvailable);
      if (!_isPipAvailableController.isClosed) {
        _isPipAvailableController.add(isPipAvailable);
      }

      // Re-fetch AirPlay availability (iOS only)
      final isAirplayAvailable = await _methodChannel!.isAirPlayAvailable();
      _state = _state.copyWith(isAirplayAvailable: isAirplayAvailable);
      if (!_isAirplayAvailableController.isClosed) {
        _isAirplayAvailableController.add(isAirplayAvailable);
      }

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
  bool get isAirplayAvailable => _state.isAirplayAvailable;

  /// Returns whether the video is currently connected to an AirPlay/Cast device
  bool get isAirplayConnected => _state.isAirplayConnected;

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
  Stream<bool> get isAirplayAvailableStream =>
      _isAirplayAvailableController.stream;

  /// Stream of AirPlay connection state changes
  Stream<bool> get isAirplayConnectedStream =>
      _isAirplayConnectedController.stream;

  /// Stream of fullscreen state changes
  Stream<bool> get isFullscreenStream => _isFullscreenController.stream;

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
    'showNativeControls':
        !_hasCustomOverlay, // Hide native controls if we have custom overlay
    'isFullScreen': _state.isFullScreen,
    'enableHDR': enableHDR,
    'enableLooping': enableLooping,
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

    // If we're reconnecting after all platform views were disposed, refresh availability flags
    if (wasDisconnected) {
      // Re-fetch availability flags from native side FIRST (wait for it to complete)
      // This ensures the state is up-to-date before we emit it
      await _refreshAvailabilityFlags();

      // Ensure native controls are hidden if we have a custom overlay
      // This is critical when rapidly navigating - the overlay builder persists
      // but native controls might not have been hidden during the reconnection
      if (_hasCustomOverlay && _methodChannel != null) {
        await setShowNativeControls(false);
      }
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

    // IMPORTANT: Set up event channel for EVERY platform view
    // This ensures that both the original and fullscreen widgets receive events
    final EventChannel eventChannel = EventChannel(
      'native_video_player_$platformViewId',
    );

    // Set up event stream and store the subscription for later cleanup
    _eventSubscriptions[platformViewId] = eventChannel.receiveBroadcastStream().listen(
      (dynamic eventMap) async {
        final map = eventMap as Map<dynamic, dynamic>;
        final String eventName = map['event'] as String;

        // Handle AirPlay availability change event
        if (eventName == 'airPlayAvailabilityChanged') {
          final bool isAvailable = map['isAvailable'] as bool? ?? false;
          _updateState(_state.copyWith(isAirplayAvailable: isAvailable));
          for (final handler in _airPlayAvailabilityHandlers) {
            handler(isAvailable);
          }
          return;
        }

        // Handle AirPlay connection change event
        if (eventName == 'airPlayConnectionChanged') {
          final bool isConnected = map['isConnected'] as bool? ?? false;
          _updateState(_state.copyWith(isAirplayConnected: isConnected));
          for (final handler in _airPlayConnectionHandlers) {
            handler(isConnected);
          }
          return;
        }

        // Determine if this is an activity event or control event
        final isActivityEvent = _isActivityEvent(eventName);

        if (isActivityEvent) {
          final activityEvent = PlayerActivityEvent.fromMap(map);

          // Complete initialization when we receive the isInitialized event
          if (!_state.activityState.isInitialized &&
              activityEvent.state == PlayerActivityState.initialized &&
              _initializeCompleter != null &&
              !_initializeCompleter!.isCompleted) {
            _isInitialized = true;
            _initializeCompleter!.complete();
          }

          // Update the last non-buffering state when we receive play/pause events
          // This ensures we can restore to the correct state after buffering
          if (activityEvent.state == PlayerActivityState.playing ||
              activityEvent.state == PlayerActivityState.paused) {
            _lastNonBufferingState = activityEvent.state;
          }

          // Update activity state
          _updateState(_state.copyWith(activityState: activityEvent.state));

          // Handle loaded events to get initial duration
          if (activityEvent.state == PlayerActivityState.loaded) {
            if (activityEvent.data != null) {
              final int duration =
                  (activityEvent.data!['duration'] as num?)?.toInt() ?? 0;
              _updateState(
                _state.copyWith(duration: Duration(milliseconds: duration)),
              );
            }
          }

          // Notify activity listeners
          for (final handler in _activityEventHandlers) {
            handler(activityEvent);
          }
        } else {
          final controlEvent = PlayerControlEvent.fromMap(map);

          // Handle fullscreen change events
          if (controlEvent.state == PlayerControlState.fullscreenEntered ||
              controlEvent.state == PlayerControlState.fullscreenExited) {
            final bool isFullscreen =
                controlEvent.data?['isFullscreen'] as bool? ??
                controlEvent.state == PlayerControlState.fullscreenEntered;
            _updateState(
              _state.copyWith(
                isFullScreen: isFullscreen,
                controlState: controlEvent.state,
              ),
            );
          }

          // Handle time update events
          if (controlEvent.state == PlayerControlState.timeUpdated) {
            if (controlEvent.data != null) {
              final int position =
                  (controlEvent.data!['position'] as num?)?.toInt() ?? 0;
              final int duration =
                  (controlEvent.data!['duration'] as num?)?.toInt() ?? 0;
              final int bufferedPosition =
                  (controlEvent.data!['bufferedPosition'] as num?)?.toInt() ??
                  0;
              final bool isBuffering =
                  (controlEvent.data!['isBuffering'] as bool?) ?? false;

              // Handle buffering state with 400ms debounce
              _handleBufferingStateChange(isBuffering);

              // Protect against duration being overwritten with 0 during AirPlay transitions
              // If we have a valid duration stored and the new duration is 0, keep the old duration
              final Duration newDuration = duration > 0
                  ? Duration(milliseconds: duration)
                  : (_state.duration != Duration.zero
                        ? _state.duration
                        : Duration.zero);

              // Update position, duration, and buffered position
              // Don't update activityState here - it's handled by the debounced buffering logic
              _updateState(
                _state.copyWith(
                  currentPosition: Duration(milliseconds: position),
                  duration: newDuration,
                  bufferedPosition: Duration(milliseconds: bufferedPosition),
                  controlState: controlEvent.state,
                ),
              );
            }
          }

          // Handle quality change events
          if (controlEvent.state == PlayerControlState.qualityChanged) {
            if (controlEvent.data != null &&
                controlEvent.data!['quality'] != null) {
              final qualityMap = controlEvent.data!['quality'] as Map;
              final quality = NativeVideoPlayerQuality.fromMap(qualityMap);
              if (!_qualityChangedController.isClosed) {
                _qualityChangedController.add(quality);
              }
            }
          }

          // Handle speed change events
          if (controlEvent.state == PlayerControlState.speedChanged) {
            if (controlEvent.data != null &&
                controlEvent.data!['speed'] != null) {
              final double speed = (controlEvent.data!['speed'] as num)
                  .toDouble();
              _updateState(_state.copyWith(speed: speed));
            }
          }

          // Handle PiP state events
          if (controlEvent.state == PlayerControlState.pipStarted ||
              controlEvent.state == PlayerControlState.pipStopped) {
            final bool isPipEnabled =
                controlEvent.state == PlayerControlState.pipStarted;
            _updateState(_state.copyWith(isPipEnabled: isPipEnabled));
          }

          // Handle PiP availability change events
          if (controlEvent.state == PlayerControlState.pipAvailabilityChanged) {
            if (controlEvent.data != null &&
                controlEvent.data!['isAvailable'] != null) {
              final bool isAvailable =
                  controlEvent.data!['isAvailable'] as bool;
              _updateState(_state.copyWith(isPipAvailable: isAvailable));
            }
          }

          // Handle AirPlay connection state events
          if (controlEvent.state == PlayerControlState.airPlayConnected ||
              controlEvent.state == PlayerControlState.airPlayDisconnected) {
            final bool isConnected =
                controlEvent.state == PlayerControlState.airPlayConnected;
            _updateState(_state.copyWith(isAirplayConnected: isConnected));

            // When AirPlay connects, the native player might reset duration temporarily
            // Re-emit the current duration to ensure it's not lost
            if (isConnected && _state.duration != Duration.zero) {
              if (!_durationController.isClosed) {
                _durationController.add(_state.duration);
              }
            }
          }

          // Update control state for other control events
          if (controlEvent.state != PlayerControlState.timeUpdated) {
            _updateState(_state.copyWith(controlState: controlEvent.state));
          }

          // Notify control listeners
          for (final handler in _controlEventHandlers) {
            handler(controlEvent);
          }
        }
      },
      onError: (dynamic error) {
        if (!_state.activityState.isInitialized &&
            _initializeCompleter != null &&
            !_initializeCompleter!.isCompleted) {
          _initializeCompleter!.completeError(error);
        }
      },
    );

    // Set up MainActivity PiP event listener (Android only, once per app)
    _setupMainActivityPipListener();
  }

  /// Sets up a global PiP event listener from MainActivity (Android only)
  ///
  /// This listener receives PiP enter/exit events from the MainActivity
  /// when the user presses the home button or exits PiP mode.
  /// Only set up once per app lifecycle.
  void _setupMainActivityPipListener() {
    if (_pipEventListenerSetup) {
      return;
    }

    _pipEventListenerSetup = true;

    // Only set up the PiP event channel on Android
    // iOS doesn't have this channel and doesn't need it
    if (!PlatformUtils.isAndroid) {
      return;
    }

    try {
      final EventChannel pipEventChannel = const EventChannel(
        'native_video_player_pip_events',
      );

      _pipEventSubscription = pipEventChannel.receiveBroadcastStream().listen(
        (dynamic eventMap) {
          final map = eventMap as Map<dynamic, dynamic>;
          final String eventName = map['event'] as String;
          final bool isInPipMode =
              map['isInPictureInPictureMode'] as bool? ?? false;

          // Create a control event based on the MainActivity event
          final PlayerControlState state;
          if (eventName == 'pipStart') {
            state = PlayerControlState.pipStarted;
          } else if (eventName == 'pipStop') {
            state = PlayerControlState.pipStopped;
          } else {
            return;
          }

          final controlEvent = PlayerControlEvent(
            state: state,
            data: <String, dynamic>{
              'isPictureInPicture': isInPipMode,
              'fromMainActivity': true,
            },
          );

          // Update controller state
          final bool isPipEnabled = state == PlayerControlState.pipStarted;
          _updateState(
            _state.copyWith(controlState: state, isPipEnabled: isPipEnabled),
          );

          // Notify all control listeners
          for (final handler in _controlEventHandlers) {
            handler(controlEvent);
          }
        },
        onError: (dynamic error) {
          // Silently handle MainActivity PiP event channel errors
        },
      );
    } catch (e) {
      // Silently handle setup errors
    }
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

  /// Determines if an event name is an activity event
  bool _isActivityEvent(String eventName) {
    switch (eventName) {
      case 'isInitialized':
      case 'loaded':
      case 'play':
      case 'pause':
      case 'buffering':
      case 'loading':
      case 'completed':
      case 'stopped':
      case 'error':
        return true;
      default:
        return false;
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

    // Cancel the event channel subscription for this platform view
    unawaited(
      _eventSubscriptions[platformViewId]?.cancel() ?? Future<void>.value(),
    );
    _eventSubscriptions.remove(platformViewId);

    // If the disposed view was the primary view, switch to another active view
    if (_primaryPlatformViewId == platformViewId &&
        _platformViewIds.isNotEmpty) {
      // Use the most recent remaining view
      final newPrimaryViewId = _platformViewIds.last;
      _updateMethodChannel(newPrimaryViewId);
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
  ///
  /// **Returns:**
  /// A Future that completes when the video is loaded
  ///
  /// **Note:** For better clarity, consider using [loadUrl] for remote videos or [loadFile] for local files.
  Future<void> load({required String url, Map<String, String>? headers}) async {
    if (_state.activityState.isLoaded) {
      return;
    }

    if (!_state.activityState.isInitialized) {
      throw Exception('Controller not initialized. Call initialize() first.');
    }

    if (_methodChannel == null) {
      throw Exception(
        'Method channel not initialized. Platform view not created.',
      );
    }

    _url = url;

    try {
      await _methodChannel!.load(
        url: url,
        autoPlay: autoPlay,
        headers: headers,
        mediaInfo: mediaInfo?.toMap(),
      );

      // Fetch available qualities after loading
      final qualities = await _methodChannel!.getAvailableQualities();

      _updateState(
        _state.copyWith(
          qualities: qualities,
          activityState: PlayerActivityState.loaded,
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
  /// ```
  Future<void> loadUrl({
    required String url,
    Map<String, String>? headers,
  }) async {
    return load(url: url, headers: headers);
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
  Future<void> play() async {
    await _methodChannel?.play();
  }

  /// Pauses video playback
  Future<void> pause() async {
    await _methodChannel?.pause();
  }

  /// Seeks to a specific position
  Future<void> seekTo(Duration position) async {
    await _methodChannel?.seekTo(position);
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

  /// Sets whether the video should loop
  Future<void> setLooping(bool looping) async {
    await _methodChannel?.setLooping(looping);
  }

  /// Sets the video quality
  Future<void> setQuality(NativeVideoPlayerQuality quality) async {
    await _methodChannel?.setQuality(quality);
  }

  /// Returns whether Picture-in-Picture is available on this device
  /// Checks the actual device capabilities rather than just the platform
  /// PiP is available on iOS 14+ and Android 8+ (if the device supports it)
  Future<bool> isPictureInPictureAvailable() async {
    if (_methodChannel == null) {
      return false;
    }
    return await _methodChannel!.isPictureInPictureAvailable();
  }

  /// Enters Picture-in-Picture mode
  /// Only works on iOS 14+ and Android 8+
  Future<bool> enterPictureInPicture() async {
    if (_methodChannel == null) {
      return false;
    }
    return await _methodChannel!.enterPictureInPicture();
  }

  /// Exits Picture-in-Picture mode
  /// Only works on iOS 14+ and Android 8+
  Future<bool> exitPictureInPicture() async {
    if (_methodChannel == null) {
      return false;
    }
    final successfully = await _methodChannel!.exitPictureInPicture();

    _emitCurrentState();

    return successfully;
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

    _updateState(_state.copyWith(isFullScreen: true));

    if (_hasCustomOverlay && _fullscreenContext != null) {
      // Emit fullscreen entered event
      final controlEvent = PlayerControlEvent(
        state: PlayerControlState.fullscreenEntered,
        data: <String, dynamic>{'isFullscreen': true},
      );
      for (final handler in _controlEventHandlers) {
        handler(controlEvent);
      }

      // Use Dart fullscreen when we have a custom overlay
      await _enterDartFullscreen();
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

    if (_hasCustomOverlay) {
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

  /// Enters Dart-based fullscreen mode
  Future<void> _enterDartFullscreen() async {
    final context = _fullscreenContext;

    if (context == null) {
      // Fallback: reset state since we can't show fullscreen
      _updateState(_state.copyWith(isFullScreen: false));
      return;
    }

    await FullscreenManager.showFullscreenDialog(
      context: context,
      builder: (dialogContext) {
        return FullscreenVideoPlayer(
          controller: this,
          overlayBuilder: _overlayBuilder,
        );
      },
      lockToLandscape: lockToLandscape,
      onExit: () {
        // Update state when fullscreen dialog is dismissed by user (back button, etc.)
        _dartFullscreenCloseCallback = null;
        if (_state.isFullScreen) {
          _updateState(_state.copyWith(isFullScreen: false));
        }
      },
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
    _isOverlayLocked = true;
    if (!_isOverlayLockedController.isClosed) {
      _isOverlayLockedController.add(true);
    }
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
    _isOverlayLocked = false;
    if (!_isOverlayLockedController.isClosed) {
      _isOverlayLockedController.add(false);
    }
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
    for (final StreamSubscription<dynamic> subscription
        in _eventSubscriptions.values) {
      await subscription.cancel();
    }
    _eventSubscriptions.clear();

    // Cancel PiP event subscription (Android only)
    await _pipEventSubscription?.cancel();
    _pipEventSubscription = null;

    // Cancel buffering debounce timer
    _bufferingDebounceTimer?.cancel();
    _bufferingDebounceTimer = null;

    // Clear all event handlers
    _activityEventHandlers.clear();
    _controlEventHandlers.clear();
    _airPlayAvailabilityHandlers.clear();
    _airPlayConnectionHandlers.clear();

    // Clear platform view references
    _platformViewIds.clear();
    _platformViewContexts.clear();
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

    // Pause playback first to avoid crashes during disposal
    if (_state.activityState.isPlaying) {
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
    for (final StreamSubscription<dynamic> subscription
        in _eventSubscriptions.values) {
      await subscription.cancel();
    }
    _eventSubscriptions.clear();

    // Cancel PiP event subscription (Android only)
    await _pipEventSubscription?.cancel();
    _pipEventSubscription = null;

    // Cancel buffering debounce timer
    _bufferingDebounceTimer?.cancel();
    _bufferingDebounceTimer = null;

    // Clear all event handlers
    _activityEventHandlers.clear();
    _controlEventHandlers.clear();
    _airPlayAvailabilityHandlers.clear();
    _airPlayConnectionHandlers.clear();

    // Dispose native player resources (removes shared player from manager)
    await _methodChannel?.dispose();

    // Close all stream controllers
    await _bufferedPositionController.close();
    await _durationController.close();
    await _playerStateController.close();
    await _positionController.close();
    await _speedController.close();
    await _isPipEnabledController.close();
    await _isPipAvailableController.close();
    await _isAirplayAvailableController.close();
    await _isAirplayConnectedController.close();
    await _isFullscreenController.close();
    await _qualityChangedController.close();
    await _qualitiesController.close();
    await _isOverlayLockedController.close();

    // Clear platform view references
    _platformViewIds.clear();
    _platformViewContexts.clear();
    _primaryPlatformViewId = null;

    // Clear overlay and fullscreen references
    _overlayBuilder = null;
    _dartFullscreenCloseCallback = null;

    // Clear other state
    _methodChannel = null;
    _url = null;
    _initializeCompleter = null;
  }
}

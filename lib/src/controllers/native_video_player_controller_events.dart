part of 'native_video_player_controller.dart';

/// Platform-channel event plumbing for [NativeVideoPlayerController]:
/// controller-level EventChannel registration ordering (the
/// MissingPluginException fix, GitHub issue #31), per-view EventChannel
/// subscription with retry, and routing of controller-scoped events
/// (PiP/AirPlay) that survive view disposal. Implementation detail of the
/// controller, split out for readability; private members stay accessible
/// because part files share the library.
extension _ControllerEventPlumbing on NativeVideoPlayerController {
  /// Sets up the controller-level event channel for persistent events
  ///
  /// This channel receives PiP and AirPlay events independently of platform views.
  /// It persists even when all platform views are disposed, allowing events to
  /// flow after calling releaseResources(). Only disposed when controller.dispose() is called.
  ///
  /// The native StreamHandler is registered FIRST (via the shared plugin
  /// method channel, which exists from plugin registration) and Dart only
  /// listens after the native ack. Listening without a registered handler
  /// makes the EventChannel's `listen` call fail with a
  /// MissingPluginException (GitHub issue #31). Same ordering as the official
  /// video_player plugin, which registers its event channel inside `create`
  /// before Dart subscribes.
  ///
  /// The channel is shared with every other live controller that has the
  /// same [id] (see [_SharedControllerEventChannel]).
  Future<void> _setupControllerEventChannel() async {
    final channel = _SharedControllerEventChannel.attach(this);
    _sharedControllerEventChannel = channel;
    await channel.start(retryRegistration: true);
  }

  /// Whether another live controller has this [id]. Controllers with the
  /// same ID share one native player (the same video on two screens), so it
  /// must outlive this one.
  bool get _sharesNativePlayer =>
      _SharedControllerEventChannel.hasLiveController(id);

  /// Safety net: makes sure the controller event channel is registered and
  /// subscribed once a platform view exists. By that point the plugin is
  /// guaranteed to be attached (it created the platform view), so a setup
  /// attempt that failed in the constructor can be retried here.
  Future<void> _ensureControllerEventChannel() async {
    if (_isDisposed) {
      return;
    }
    // Let any in-flight constructor setup finish first.
    final pending = _controllerChannelSetupFuture;
    if (pending != null) {
      await pending;
    }
    if (_isDisposed) {
      return;
    }
    await _sharedControllerEventChannel?.start(retryRegistration: false);
  }

  /// Handles events from the controller-level event channel
  ///
  /// Processes PiP and AirPlay events that persist independently of platform views.
  void _handleControllerEvent(dynamic eventMap) {
    if (_isDisposed) {
      return;
    }

    final map = eventMap as Map<dynamic, dynamic>;
    final String eventName = map['event'] as String;

    // Handle PiP events
    if (eventName == 'pipStart' || eventName == 'pipStop') {
      final bool isPipEnabled = eventName == 'pipStart';

      // iOS sends each PiP change on the view's channel too; only a change
      // reaches listeners, once.
      if (isPipEnabled == _state.isPipEnabled) {
        return;
      }

      debugPrint(
        'Controller-level event: $eventName (isPipEnabled=$isPipEnabled)',
      );

      // When exiting PiP, restore the custom overlay if it was hidden
      if (!isPipEnabled && _hideOverlayForPip) {
        _hideOverlayForPip = false;

        // Restore custom overlay controls by hiding native controls
        if (_overlayBuilder != null) {
          unawaited(setShowNativeControls(false));
        }
      }

      // Update state
      _updateState(_state.copyWith(isPipEnabled: isPipEnabled));

      // Notify control listeners
      final controlEvent = PlayerControlEvent(
        state: isPipEnabled
            ? PlayerControlState.pipStarted
            : PlayerControlState.pipStopped,
        data: Map<String, dynamic>.from(map),
      );
      for (final handler in _controlEventHandlers) {
        handler(controlEvent);
      }
      return;
    }

    // The iOS total-player LRU cap evicted this controller's native player
    // (NativeVideoPlayerConfig.iosMaxTotalPlayers): remember the resume
    // position and mark for a transparent re-load on the next play() — the
    // torn-down player would otherwise silently no-op every command.
    if (eventName == 'playerEvicted') {
      final int positionMs = (map['positionMs'] as num?)?.toInt() ?? 0;
      _evictionResumePosition = positionMs > 0
          ? Duration(milliseconds: positionMs)
          : _state.currentPosition;
      _needsReloadAfterEviction = _url != null;

      debugPrint(
        'Controller-level event: playerEvicted '
        '(resume position: $_evictionResumePosition)',
      );
      return;
    }

    // Handle AirPlay availability
    if (eventName == 'airPlayAvailabilityChanged') {
      final bool isAvailable = map['isAvailable'] as bool? ?? false;

      debugPrint(
        'Controller-level event: airPlayAvailabilityChanged (isAvailable=$isAvailable)',
      );

      // Update global AirPlay state manager
      final globalManager = AirPlayStateManager.instance;
      if (globalManager.isAirPlayAvailable != isAvailable) {
        globalManager.updateAvailability(isAvailable);
      }

      // Also update local state for backward compatibility
      _updateState(_state.copyWith(isAirplayAvailable: isAvailable));

      // Notify local listeners
      for (final handler in _airPlayAvailabilityHandlers) {
        handler(isAvailable);
      }
      return;
    }

    // Handle AirPlay connection
    if (eventName == 'airPlayConnectionChanged') {
      final bool isConnected = map['isConnected'] as bool? ?? false;
      final bool isConnecting = map['isConnecting'] as bool? ?? false;
      final String? deviceName = map['deviceName'] as String?;

      debugPrint(
        'Controller-level event: airPlayConnectionChanged (isConnected=$isConnected, isConnecting=$isConnecting, deviceName=$deviceName)',
      );

      // Update global AirPlay state manager
      final globalManager = AirPlayStateManager.instance;
      globalManager.updateConnection(
        isConnected,
        isConnecting: isConnecting,
        deviceName: deviceName,
      );

      // Also update local state for backward compatibility
      _updateState(
        _state.copyWith(
          isAirplayConnected: isConnected,
          isAirplayConnecting: isConnecting,
          airPlayDeviceName: deviceName,
        ),
      );

      // Notify local listeners
      for (final handler in _airPlayConnectionHandlers) {
        handler(isConnected);
      }
      return;
    }
  }

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
      case 'idle':
        return true;
      default:
        return false;
    }
  }

  /// Subscribes to the platform view's EventChannel, retrying while the
  /// native view may still be registering its handler.
  ///
  /// Gives up as soon as the view is disposed (or the controller is): a
  /// subscription created for a view that is already gone only produced a
  /// failing `listen` and, later, a failing `cancel`.
  ///
  /// **Parameters:**
  /// - platformViewId: The ID of the platform view to subscribe to
  Future<void> _subscribeToEventChannelWithRetry(int platformViewId) async {
    const List<Duration> retryDelays = <Duration>[
      Duration(milliseconds: 50),
      Duration(milliseconds: 100),
      Duration(milliseconds: 200),
      Duration(milliseconds: 400),
      Duration(milliseconds: 800),
    ];

    // Add a small initial delay to give native side more time to initialize
    // This reduces the chance of hitting the race condition
    await Future<void>.delayed(const Duration(milliseconds: 10));

    for (final Duration retryDelay in retryDelays) {
      if (!_isPlatformViewLive(platformViewId)) {
        return;
      }

      final NativeEventSubscription subscription = NativeEventSubscription(
        'native_video_player_$platformViewId',
        onEvent: _handlePlatformViewEvent,
        onError: _handlePlatformViewEventError,
      );
      // Registered before listening so a dispose that lands meanwhile
      // cancels this attempt.
      unawaited(_eventSubscriptions[platformViewId]?.cancel());
      _eventSubscriptions[platformViewId] = subscription;

      if (await subscription.listen()) {
        return;
      }

      if (identical(_eventSubscriptions[platformViewId], subscription)) {
        _eventSubscriptions.remove(platformViewId);
      }
      if (subscription.isCancelled) {
        return;
      }

      if (kDebugMode) {
        debugPrint(
          'EventChannel subscription for view $platformViewId failed, '
          'retrying in ${retryDelay.inMilliseconds}ms',
        );
      }
      await Future<void>.delayed(retryDelay);
    }

    if (kDebugMode && _isPlatformViewLive(platformViewId)) {
      debugPrint(
        'EventChannel subscription for view $platformViewId failed after '
        '${retryDelays.length} attempts. Some events may be lost.',
      );
    }
  }

  /// Whether [platformViewId] is still attached to this live controller.
  bool _isPlatformViewLive(int platformViewId) =>
      !_isDisposed && _platformViewIds.contains(platformViewId);

  /// Handles an event from a platform view's EventChannel.
  void _handlePlatformViewEvent(dynamic eventMap) {
    final map = eventMap as Map<dynamic, dynamic>;
    final String eventName = map['event'] as String;

    // NOTE: PiP and AirPlay events are now handled by the controller-level
    // event channel (_handleControllerEvent) to persist when views are disposed

    // Handle AirPlay connection change event (for backward compatibility)
    if (eventName == 'airPlayConnectionChanged') {
      final bool isConnected = map['isConnected'] as bool? ?? false;
      final bool isConnecting = map['isConnecting'] as bool? ?? false;
      final String? deviceName = map['deviceName'] as String?;

      // Only update global state if values are actually different
      // This ensures one source of truth and prevents redundant stream emissions
      // when multiple controllers report the same state
      final globalManager = AirPlayStateManager.instance;
      final bool shouldUpdate =
          globalManager.isAirPlayConnected != isConnected ||
          globalManager.isAirPlayConnecting != isConnecting ||
          globalManager.airPlayDeviceName != deviceName;

      if (shouldUpdate) {
        // Update global AirPlay state with connecting state and device name
        globalManager.updateConnection(
          isConnected,
          isConnecting: isConnecting,
          deviceName: deviceName,
        );
      }

      // Also update local state for backward compatibility
      _updateState(
        _state.copyWith(
          isAirplayConnected: isConnected,
          isAirplayConnecting: isConnecting,
          airPlayDeviceName: deviceName,
        ),
      );
      for (final handler in _airPlayConnectionHandlers) {
        handler(isConnected);
      }
      return;
    }

    // Texture-mode aspect ratio: there is no native
    // AspectRatioFrameLayout for texture-rendered views, so the
    // widget letterboxes the Texture from this event.
    if (eventName == 'videoSize') {
      final width = (map['width'] as num?)?.toDouble() ?? 0;
      final height = (map['height'] as num?)?.toDouble() ?? 0;
      final rotation = (map['rotationCorrection'] as num?)?.toInt();
      if (width > 0 && height > 0) {
        _videoSize = NativeVideoPlayerVideoSize(
          width: width,
          height: height,
          rotationCorrection: rotation ?? 0,
        );
        if (!_videoSizeController.isClosed) {
          _videoSizeController.add(_videoSize!);
        }
      }
      return;
    }

    // Determine if this is an activity event or control event
    final isActivityEvent = _isActivityEvent(eventName);

    if (isActivityEvent) {
      final activityEvent = PlayerActivityEvent.fromMap(map);

      // Complete initialization when we receive the isInitialized event
      // OR if method channel exists and we have platform views
      if ((!_state.activityState.isInitialized &&
              activityEvent.state == PlayerActivityState.initialized &&
              _initializeCompleter != null &&
              !_initializeCompleter!.isCompleted) ||
          (_methodChannel != null &&
              _platformViewIds.isNotEmpty &&
              !_isInitialized)) {
        _isInitialized = true;
        if (_initializeCompleter != null &&
            !_initializeCompleter!.isCompleted) {
          _initializeCompleter!.complete();
        }
        _isInitializing = false;
      }

      if (_holdsDuringSeek(map, activityEvent.state)) {
        return;
      }

      // Handle loaded events to get initial duration (also from a loaded
      // that leaves the state as it is, see _keepsCurrentState)
      if (activityEvent.state == PlayerActivityState.loaded) {
        if (activityEvent.data != null) {
          final int duration =
              (activityEvent.data!['duration'] as num?)?.toInt() ?? 0;
          // A loaded without a duration keeps the one known so far.
          if (duration > 0) {
            _updateState(
              _state.copyWith(duration: Duration(milliseconds: duration)),
            );
          }
        }
      }

      if (_keepsCurrentState(activityEvent.state)) {
        return;
      }

      // Any state but buffering proves the player isn't buffering (any
      // more). Only time updates cleared this flag, and a paused player
      // sends none: a buffering blip at a seek (whose time update says
      // isBuffering) then still flipped the state to buffering after the
      // player had reported loaded, a spinner that never went away.
      if (activityEvent.state != PlayerActivityState.buffering) {
        _isCurrentlyBuffering = false;
        _bufferingDebounceTimer?.cancel();
      }

      // Update the last non-buffering state when we receive play/pause events
      // This ensures we can restore to the correct state after buffering
      if (activityEvent.state == PlayerActivityState.playing ||
          activityEvent.state == PlayerActivityState.paused) {
        _lastNonBufferingState = activityEvent.state;
      }

      if (activityEvent.state == PlayerActivityState.playing) {
        _playReportedDuringLoad = true;
      }

      // Update activity state
      _updateState(_state.copyWith(activityState: activityEvent.state));

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

        // Check if this event is coming from Android for PiP preparation
        // Android sends fullscreenChange event before entering PiP to hide app bar/FAB
        final bool isFromAndroidPipPreparation =
            PlatformUtils.isAndroid &&
            controlEvent.data?['fromAndroidPipPreparation'] == true;

        if (isFromAndroidPipPreparation) {
          // Android is preparing for PiP - enter fullscreen
          if (isFullscreen) {
            // Hide custom overlay during PiP preparation
            // This ensures the overlay controls don't show in PiP mode
            // We set a flag instead of nulling _overlayBuilder so we can restore it later
            _hideOverlayForPip = true;
            _isOverlayLocked = false;

            // Enable native controls for PiP mode and enter native fullscreen
            // Use method channel directly to avoid state checks in enterFullScreen()
            unawaited(setShowNativeControls(true));
            unawaited(enterFullScreen());
          }
        } else {
          // Normal fullscreen change from native side (e.g. the user
          // tapping PlayerView's own fullscreen button, or PiP exit
          // restoration). Native has already performed the transition,
          // so only mirror it in Dart — calling enterFullScreen() /
          // exitFullScreen() here would send the command back down the
          // method channel and run the native transition a second time.
          unawaited(_syncFullScreenFromNative(isFullscreen));
        }

        // Always update state for fullscreen changes
        _updateState(
          _state.copyWith(
            isFullScreen: isFullscreen,
            controlState: controlEvent.state,
          ),
        );
      }

      // The native seek is done: time updates from here on are current
      // (earlier ones arrived before this event).
      if (controlEvent.state == PlayerControlState.seeked) {
        _pendingSeekTarget = null;
      }

      // Handle time update events
      if (controlEvent.state == PlayerControlState.timeUpdated) {
        if (controlEvent.data != null) {
          final int position =
              (controlEvent.data!['position'] as num?)?.toInt() ?? 0;
          final int duration =
              (controlEvent.data!['duration'] as num?)?.toInt() ?? 0;
          final int bufferedPosition =
              (controlEvent.data!['bufferedPosition'] as num?)?.toInt() ?? 0;
          final bool isBuffering =
              (controlEvent.data!['isBuffering'] as bool?) ?? false;
          // Older native builds don't send it; keep the last known value.
          final bool? isLive = controlEvent.data!['isLive'] as bool?;

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
          final Duration reported = Duration(milliseconds: position);
          _updateState(
            _state.copyWith(
              // A leftover from before a seek keeps the seek's target.
              currentPosition: _isStaleAfterSeek(reported)
                  ? _state.currentPosition
                  : reported,
              duration: newDuration,
              bufferedPosition: Duration(milliseconds: bufferedPosition),
              controlState: controlEvent.state,
              isLive: isLive,
            ),
          );
        }
      }

      // Handle quality change events
      if (controlEvent.state == PlayerControlState.qualityChanged) {
        final data = controlEvent.data;
        if (data != null) {
          // Native emits the selected quality's fields flat in the event
          // map (url/label/isAuto); the controller's synthetic control
          // events nest them under 'quality'. Support both so the
          // selected quality reaches qualityChangedStream.
          final qualityMap =
              (data['quality'] as Map?) ??
              ((data['url'] != null || data['label'] != null) ? data : null);
          if (qualityMap != null && !_qualityChangedController.isClosed) {
            _qualityChangedController.add(
              NativeVideoPlayerQuality.fromMap(qualityMap),
            );
          }
        }
      }

      // Handle speed change events
      if (controlEvent.state == PlayerControlState.speedChanged) {
        if (controlEvent.data != null && controlEvent.data!['speed'] != null) {
          final double speed = (controlEvent.data!['speed'] as num).toDouble();
          _updateState(_state.copyWith(speed: speed));
        }
      }

      // Handle PiP state events
      if (controlEvent.state == PlayerControlState.pipStarted ||
          controlEvent.state == PlayerControlState.pipStopped) {
        final bool isPipEnabled =
            controlEvent.state == PlayerControlState.pipStarted;

        // A view reports the current PiP state when it attaches, and iOS
        // sends each change on the controller channel too: only a change
        // reaches listeners, once.
        if (isPipEnabled == _state.isPipEnabled) {
          return;
        }

        // When exiting PiP, restore the custom overlay if it was hidden
        if (!isPipEnabled && _hideOverlayForPip) {
          _hideOverlayForPip = false;

          // Restore custom overlay controls by hiding native controls
          if (_overlayBuilder != null) {
            unawaited(setShowNativeControls(false));
          }
        }

        _updateState(_state.copyWith(isPipEnabled: isPipEnabled));
      }

      // Handle PiP availability change events
      if (controlEvent.state == PlayerControlState.pipAvailabilityChanged) {
        if (controlEvent.data != null &&
            controlEvent.data!['isAvailable'] != null) {
          final bool isAvailable = controlEvent.data!['isAvailable'] as bool;
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
  }

  /// Handles an error sent through a platform view's EventChannel.
  void _handlePlatformViewEventError(Object error) {
    if (!_state.activityState.isInitialized &&
        _initializeCompleter != null &&
        !_initializeCompleter!.isCompleted) {
      _initializeCompleter!.completeError(error);
    }
  }
}

/// The controller-level EventChannel `native_video_player_controller_<id>`,
/// shared by every live controller with that ID.
///
/// Natively there is one handler and one sink per controller ID, and a Dart
/// [BinaryMessenger] keeps one handler per channel name, so two controllers
/// with the same ID (the same video on two screens) cannot each own the
/// channel: the newer one's listen replaced the older one's, and the older
/// one's dispose then cancelled and tore the channel down under the newer one
/// (MissingPluginException on `listen`/`cancel`, "No active stream to
/// cancel"). One subscription per ID fans events out to every attached
/// controller, and only the last controller to detach cancels it and tears
/// the native channel down.
class _SharedControllerEventChannel {
  _SharedControllerEventChannel._(this.controllerId, this._previousTeardown);

  static final Map<int, _SharedControllerEventChannel> _channels =
      <int, _SharedControllerEventChannel>{};

  /// In-flight teardowns by controller ID: a channel created while the
  /// previous one for its ID is still being torn down waits for it, so the
  /// teardown cannot remove the native handler the new one registered.
  static final Map<int, Future<void>> _teardowns = <int, Future<void>>{};

  /// Returns the channel for [controller]'s ID, creating it if needed, and
  /// attaches [controller] to it.
  static _SharedControllerEventChannel attach(
    NativeVideoPlayerController controller,
  ) {
    final channel = _channels.putIfAbsent(
      controller.id,
      () => _SharedControllerEventChannel._(
        controller.id,
        _teardowns[controller.id],
      ),
    );
    channel._controllers.add(controller);
    return channel;
  }

  /// Whether a live controller with [controllerId] exists.
  static bool hasLiveController(int controllerId) =>
      _channels[controllerId]?._hasLiveControllers ?? false;

  final int controllerId;
  final Future<void>? _previousTeardown;
  final Set<NativeVideoPlayerController> _controllers =
      <NativeVideoPlayerController>{};
  NativeEventSubscription? _subscription;
  Future<void>? _starting;

  bool get _hasLiveControllers =>
      _controllers.any((controller) => !controller._isDisposed);

  /// Registers the native handler and listens, once for all attached
  /// controllers.
  ///
  /// With [retryRegistration] (the constructor path) a registration that
  /// keeps failing gives up without listening — the plugin is not attached,
  /// and a platform view will retry. Without it (the platform-view path) the
  /// registration is attempted once and the listen happens regardless: on
  /// iOS the platform view registers the handler natively as well.
  Future<void> start({required bool retryRegistration}) {
    if (_subscription != null) {
      return Future<void>.value();
    }
    return _starting ??= _start(
      retryRegistration: retryRegistration,
    ).whenComplete(() => _starting = null);
  }

  Future<void> _start({required bool retryRegistration}) async {
    await _previousTeardown;

    final bool registered = await _registerNativeHandler(
      retry: retryRegistration,
    );
    if (!registered && retryRegistration) {
      return;
    }
    if (!_hasLiveControllers || _subscription != null) {
      return;
    }

    final NativeEventSubscription subscription = NativeEventSubscription(
      'native_video_player_controller_$controllerId',
      onEvent: _dispatch,
      onError: (Object error) {
        debugPrint('Controller event channel error: $error');
      },
    );
    _subscription = subscription;
    if (!await subscription.listen() &&
        identical(_subscription, subscription)) {
      _subscription = null;
    }
  }

  /// Asks the native side to register the StreamHandler for this ID,
  /// retrying briefly (when [retry]) in case the plugin is not attached yet
  /// (cold start / hot restart races).
  Future<bool> _registerNativeHandler({required bool retry}) async {
    for (var attempt = 0; ; attempt++) {
      if (!_hasLiveControllers) {
        return false;
      }
      try {
        await NativeVideoPlayerController._pluginMethodChannel
            .invokeMethod<void>('setupControllerEventChannel', {
              'controllerId': controllerId,
            });
        return true;
      } catch (e) {
        final retryDelays =
            NativeVideoPlayerController.controllerChannelRetryDelays;
        if (!retry || attempt >= retryDelays.length) {
          debugPrint(
            'Controller event channel setup failed for controller '
            '$controllerId ($e); will retry when a platform view is created.',
          );
          return false;
        }
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
  }

  void _dispatch(dynamic event) {
    for (final NativeVideoPlayerController controller
        in _controllers.toList()) {
      // A throwing app listener on one controller must not keep the event
      // from the other controllers that share this channel.
      try {
        controller._handleControllerEvent(event);
      } catch (exception, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: exception,
            stack: stack,
            library: 'better_native_video_player',
            context: ErrorDescription('while dispatching a controller event'),
          ),
        );
      }
    }
  }

  /// Detaches [controller]. The last controller to detach cancels the
  /// subscription and then tears the native channel down.
  Future<void> detach(NativeVideoPlayerController controller) async {
    _controllers.remove(controller);
    if (_controllers.isNotEmpty) {
      return;
    }

    if (identical(_channels[controllerId], this)) {
      _channels.remove(controllerId);
    }
    final Future<void> teardown = _tearDown();
    _teardowns[controllerId] = teardown;
    await teardown;
    if (identical(_teardowns[controllerId], teardown)) {
      _teardowns.remove(controllerId);
    }
  }

  Future<void> _tearDown() async {
    // A start in flight would otherwise subscribe after the cancel below.
    await _starting;

    final NativeEventSubscription? subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();

    try {
      await NativeVideoPlayerController._pluginMethodChannel.invokeMethod<void>(
        'teardownControllerEventChannel',
        {'controllerId': controllerId},
      );
    } catch (e) {
      debugPrint('Failed to teardown controller event channel: $e');
    }
  }
}

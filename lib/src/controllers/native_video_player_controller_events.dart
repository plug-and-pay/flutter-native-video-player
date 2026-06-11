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
  /// makes the EventChannel's internal `listen` call fail with a
  /// MissingPluginException that the services library reports straight to
  /// [FlutterError.onError] (GitHub issue #31). Same ordering as the official
  /// video_player plugin, which registers its event channel inside `create`
  /// before Dart subscribes.
  Future<void> _setupControllerEventChannel() async {
    final bool registered = await _registerControllerChannelWithRetry();
    if (!registered || _isDisposed) {
      return;
    }
    _listenToControllerEventChannel();
  }

  /// Asks the native side to register the StreamHandler for
  /// `native_video_player_controller_$id`, retrying briefly in case the
  /// plugin is not attached yet (cold start / hot restart races).
  Future<bool> _registerControllerChannelWithRetry() async {
    for (var attempt = 0; ; attempt++) {
      if (_isDisposed) {
        return false;
      }
      try {
        await NativeVideoPlayerController._pluginMethodChannel
            .invokeMethod<void>('setupControllerEventChannel', {
              'controllerId': id,
            });
        return true;
      } catch (e) {
        if (attempt >=
            NativeVideoPlayerController.controllerChannelRetryDelays.length) {
          debugPrint(
            'Controller event channel setup failed for controller $id ($e); '
            'will retry when a platform view is created.',
          );
          return false;
        }
        await Future<void>.delayed(
          NativeVideoPlayerController.controllerChannelRetryDelays[attempt],
        );
      }
    }
  }

  /// Subscribes to the controller-level event channel. Idempotent.
  void _listenToControllerEventChannel() {
    if (_controllerEventSubscription != null || _isDisposed) {
      return;
    }
    _controllerEventChannel = EventChannel(
      'native_video_player_controller_$id',
    );
    _controllerEventSubscription = _controllerEventChannel!
        .receiveBroadcastStream()
        .listen(
          _handleControllerEvent,
          onError: (dynamic error) {
            debugPrint('Controller event channel error: $error');
          },
          cancelOnError: false,
        );
  }

  /// Safety net: makes sure the controller event channel is registered and
  /// subscribed once a platform view exists. By that point the plugin is
  /// guaranteed to be attached (it created the platform view), so a setup
  /// attempt that failed in the constructor can be retried here.
  Future<void> _ensureControllerEventChannel() async {
    if (_controllerEventSubscription != null || _isDisposed) {
      return;
    }
    // Let any in-flight constructor setup finish first.
    final pending = _controllerChannelSetupFuture;
    if (pending != null) {
      await pending;
    }
    if (_controllerEventSubscription != null || _isDisposed) {
      return;
    }
    try {
      await NativeVideoPlayerController._pluginMethodChannel.invokeMethod<void>(
        'setupControllerEventChannel',
        {'controllerId': id},
      );
    } catch (e) {
      // On iOS the platform-view init also registers the handler natively,
      // so listening is safe once a view exists even if this call failed.
      debugPrint('Controller event channel setup retry failed: $e');
    }
    _listenToControllerEventChannel();
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

  /// Subscribes to EventChannel with retry logic to handle race conditions
  ///
  /// Retries subscription up to 5 times with exponential backoff if MissingPluginException
  /// occurs. This handles the case where Flutter tries to subscribe before the native
  /// VideoPlayerView has finished initializing.
  ///
  /// **Parameters:**
  /// - platformViewId: The ID of the platform view to subscribe to
  Future<void> _subscribeToEventChannelWithRetry(int platformViewId) async {
    const int maxRetries = 5;
    const List<int> delays = [
      50,
      100,
      200,
      400,
      800,
    ]; // Exponential backoff in milliseconds

    final EventChannel eventChannel = EventChannel(
      'native_video_player_$platformViewId',
    );

    // Add a small initial delay to give native side more time to initialize
    // This reduces the chance of hitting the race condition
    await Future.delayed(const Duration(milliseconds: 10));

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        // Try to create the stream and subscribe to the event channel
        // The exception can be thrown during receiveBroadcastStream() call
        final stream = eventChannel.receiveBroadcastStream();
        _eventSubscriptions[platformViewId] = stream.listen(
          (dynamic eventMap) async {
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
                  // Normal fullscreen change from native side (e.g., PiP exit restoration)
                  // Actually call the fullscreen methods to sync UI state
                  if (isFullscreen && !_state.isFullScreen) {
                    // Native side entered fullscreen, sync Flutter state
                    unawaited(enterFullScreen());
                  } else if (!isFullscreen && _state.isFullScreen) {
                    // Native side exited fullscreen, sync Flutter state
                    unawaited(exitFullScreen());
                  }
                }

                // Always update state for fullscreen changes
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
                      (controlEvent.data!['bufferedPosition'] as num?)
                          ?.toInt() ??
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
                      bufferedPosition: Duration(
                        milliseconds: bufferedPosition,
                      ),
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
              if (controlEvent.state ==
                  PlayerControlState.pipAvailabilityChanged) {
                if (controlEvent.data != null &&
                    controlEvent.data!['isAvailable'] != null) {
                  final bool isAvailable =
                      controlEvent.data!['isAvailable'] as bool;
                  _updateState(_state.copyWith(isPipAvailable: isAvailable));
                }
              }

              // Handle AirPlay connection state events
              if (controlEvent.state == PlayerControlState.airPlayConnected ||
                  controlEvent.state ==
                      PlayerControlState.airPlayDisconnected) {
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

        // Successfully subscribed, exit retry loop
        return;
      } on MissingPluginException catch (e) {
        // EventChannel not ready yet, retry after delay
        if (attempt < maxRetries - 1) {
          if (kDebugMode) {
            debugPrint(
              'EventChannel subscription failed (attempt ${attempt + 1}/$maxRetries), retrying in ${delays[attempt]}ms: $e',
            );
          }
          await Future.delayed(Duration(milliseconds: delays[attempt]));
        } else {
          // All retries exhausted, log warning but don't crash
          if (kDebugMode) {
            debugPrint(
              'EventChannel subscription failed after $maxRetries attempts. Some events may be lost.',
            );
          }
          // Still allow the controller to function, just without event stream
        }
      } catch (e) {
        // Non-MissingPluginException error, don't retry
        if (kDebugMode) {
          debugPrint('EventChannel subscription error (non-retryable): $e');
        }
        rethrow;
      }
    }
  }
}

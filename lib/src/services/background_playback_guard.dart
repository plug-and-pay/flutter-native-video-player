import 'dart:async';

import 'package:flutter/widgets.dart';

import '../controllers/native_video_player_controller.dart';
import '../enums/native_video_player_event.dart';
import 'airplay_state_manager.dart';

/// Pauses playback when the app is backgrounded and resumes it on return —
/// for controllers that should NOT keep playing audio in the background.
///
/// PiP and AirPlay sessions are deliberately left alone: those are exactly
/// the situations where playback must continue while the app is hidden.
/// Playback is only resumed if it was this guard that paused it, so a video
/// the user paused themselves stays paused.
///
/// [pauseInBackground] is mutable, so a settings toggle can flip the
/// behavior at runtime without re-wiring listeners.
///
/// ```dart
/// final guard = BackgroundPlaybackGuard(controller);
/// // ... when the player goes away:
/// guard.dispose();
/// ```
class BackgroundPlaybackGuard with WidgetsBindingObserver {
  BackgroundPlaybackGuard(this.controller, {this.pauseInBackground = true}) {
    WidgetsBinding.instance.addObserver(this);
  }

  final NativeVideoPlayerController controller;

  /// Whether backgrounding should pause playback. Mutable on purpose.
  bool pauseInBackground;

  bool _pausedByGuard = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        if (!pauseInBackground ||
            !controller.activityState.isPlaying ||
            controller.isPipEnabled ||
            AirPlayStateManager.instance.isAirPlayConnected) {
          return;
        }
        unawaited(_pauseUnlessInPictureInPicture());
      case AppLifecycleState.resumed:
        if (_pausedByGuard) {
          _pausedByGuard = false;
          unawaited(controller.play());
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// The synchronous [NativeVideoPlayerController.isPipEnabled] flag is
  /// poll-derived on Android and can be stale at exactly the
  /// background-transition moment — pausing on it would silence an active
  /// PiP session (and abandon audio focus with it, HAB-836). Confirm
  /// against the platform's ground truth, and re-check the playback state
  /// after the await before pausing.
  Future<void> _pauseUnlessInPictureInPicture() async {
    final bool isInPictureInPicture = await controller
        .getPictureInPictureStatus();
    if (isInPictureInPicture || !controller.activityState.isPlaying) {
      return;
    }

    _pausedByGuard = true;
    await controller.pause();
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}

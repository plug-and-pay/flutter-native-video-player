import 'dart:async';

import '../controllers/native_video_player_controller.dart';
import '../enums/native_video_player_event.dart';

/// Types of playback quality-of-experience events.
enum PlaybackAnalyticsEventType {
  /// First frame after load; [PlaybackAnalyticsEvent.value] = startup ms.
  startup,

  /// Playback stalled (buffering after having played).
  stallStarted,

  /// Stall ended; value = stall duration ms.
  stallEnded,

  /// User/programmatic seek.
  seeked,

  /// Adaptive or manual quality change.
  qualityChanged,

  /// Periodic heartbeat; value = total watched ms so far.
  watchedHeartbeat,

  /// Playback reached the end.
  completed,
}

/// One QoE event with an optional numeric [value] (milliseconds for
/// durations) and free-form [data].
class PlaybackAnalyticsEvent {
  const PlaybackAnalyticsEvent(this.type, {this.value, this.data});

  final PlaybackAnalyticsEventType type;
  final int? value;
  final Map<String, dynamic>? data;

  @override
  String toString() =>
      'PlaybackAnalyticsEvent(${type.name}'
      '${value != null ? ', $value' : ''})';
}

/// Derives playback quality-of-experience events (startup time, stalls,
/// watched duration, quality switches, completion) from a controller's
/// existing event streams — no extra platform traffic.
///
/// Composable by design: create one per controller you want to measure and
/// [dispose] it with the controller.
///
/// ```dart
/// final analytics = PlaybackAnalytics(controller);
/// analytics.events.listen(sendToMetrics);
/// ```
class PlaybackAnalytics {
  PlaybackAnalytics(
    this.controller, {
    this.heartbeatInterval = const Duration(seconds: 30),
  }) {
    _loadStopwatch.start();
    controller.addActivityListener(_onActivity);
    controller.addControlListener(_onControl);
  }

  final NativeVideoPlayerController controller;
  final Duration heartbeatInterval;

  final _events = StreamController<PlaybackAnalyticsEvent>.broadcast();
  final Stopwatch _loadStopwatch = Stopwatch();
  final Stopwatch _stallStopwatch = Stopwatch();
  final Stopwatch _watchedStopwatch = Stopwatch();
  Timer? _heartbeat;
  bool _sawFirstFrame = false;
  bool _everPlayed = false;
  int _stallCount = 0;

  /// QoE events; broadcast, safe to listen multiple times.
  Stream<PlaybackAnalyticsEvent> get events => _events.stream;

  /// Stalls observed so far (buffering after playback started).
  int get stallCount => _stallCount;

  /// Total time actually spent playing.
  Duration get watchedDuration => _watchedStopwatch.elapsed;

  void _onActivity(PlayerActivityEvent event) {
    switch (event.state) {
      case PlayerActivityState.playing:
        _everPlayed = true;
        _watchedStopwatch.start();
        _heartbeat ??= Timer.periodic(heartbeatInterval, (_) {
          _emit(
            PlaybackAnalyticsEvent(
              PlaybackAnalyticsEventType.watchedHeartbeat,
              value: _watchedStopwatch.elapsedMilliseconds,
            ),
          );
        });
        if (!_sawFirstFrame) {
          _sawFirstFrame = true;
          _emit(
            PlaybackAnalyticsEvent(
              PlaybackAnalyticsEventType.startup,
              value: _loadStopwatch.elapsedMilliseconds,
            ),
          );
        }
        if (_stallStopwatch.isRunning) {
          _stallStopwatch.stop();
          _emit(
            PlaybackAnalyticsEvent(
              PlaybackAnalyticsEventType.stallEnded,
              value: _stallStopwatch.elapsedMilliseconds,
              data: {'stallCount': _stallCount},
            ),
          );
          _stallStopwatch.reset();
        }
      case PlayerActivityState.buffering:
        _watchedStopwatch.stop();
        _stopHeartbeat();
        if (_everPlayed && !_stallStopwatch.isRunning) {
          _stallCount++;
          _stallStopwatch.start();
          _emit(
            const PlaybackAnalyticsEvent(
              PlaybackAnalyticsEventType.stallStarted,
            ),
          );
        }
      case PlayerActivityState.paused:
      case PlayerActivityState.stopped:
      case PlayerActivityState.error:
        _watchedStopwatch.stop();
        _stopHeartbeat();
      case PlayerActivityState.completed:
        _watchedStopwatch.stop();
        _stopHeartbeat();
        _emit(
          PlaybackAnalyticsEvent(
            PlaybackAnalyticsEventType.completed,
            value: _watchedStopwatch.elapsedMilliseconds,
          ),
        );
      default:
        break;
    }
  }

  void _onControl(PlayerControlEvent event) {
    switch (event.state) {
      case PlayerControlState.seeked:
        _emit(
          PlaybackAnalyticsEvent(
            PlaybackAnalyticsEventType.seeked,
            data: event.data,
          ),
        );
      case PlayerControlState.qualityChanged:
        _emit(
          PlaybackAnalyticsEvent(
            PlaybackAnalyticsEventType.qualityChanged,
            data: event.data,
          ),
        );
      default:
        break;
    }
  }

  /// Heartbeats only tick while actually playing; any other state stops
  /// them so watched-duration values never repeat idly.
  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void _emit(PlaybackAnalyticsEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void dispose() {
    controller.removeActivityListener(_onActivity);
    controller.removeControlListener(_onControl);
    _heartbeat?.cancel();
    _events.close();
  }
}

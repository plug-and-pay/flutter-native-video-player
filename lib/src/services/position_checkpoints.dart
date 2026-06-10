import 'dart:async';

import '../controllers/native_video_player_controller.dart';

/// Throttled position reporting for resume-position persistence.
///
/// Emits the playback position immediately on the first update, then at
/// most once per [interval] while it advances, plus one final checkpoint
/// from [dispose] — so the last watched position is never lost. Store the
/// emitted value and hand it back via `load(startAt: ...)` to resume.
///
/// ```dart
/// final checkpoints = PositionCheckpoints(
///   controller,
///   onCheckpoint: (position) => storage.savePosition(videoId, position),
/// );
/// // ... later, with the controller:
/// checkpoints.dispose(); // flushes the final position
/// ```
class PositionCheckpoints {
  PositionCheckpoints(
    this.controller, {
    this.interval = const Duration(seconds: 5),
    void Function(Duration position)? onCheckpoint,
  }) : _onCheckpoint = onCheckpoint {
    _subscription = controller.positionStream.listen(_onPosition);
  }

  final NativeVideoPlayerController controller;

  /// Minimum time between two emitted checkpoints.
  final Duration interval;

  final void Function(Duration position)? _onCheckpoint;
  final StreamController<Duration> _checkpoints =
      StreamController<Duration>.broadcast();
  StreamSubscription<Duration>? _subscription;
  final Stopwatch _sinceLastEmit = Stopwatch();
  Duration? _lastPosition;

  /// Checkpoint stream; broadcast, safe to listen multiple times.
  Stream<Duration> get checkpoints => _checkpoints.stream;

  /// Latest observed position (may be newer than the last checkpoint).
  Duration? get lastPosition => _lastPosition;

  void _onPosition(Duration position) {
    _lastPosition = position;
    if (_sinceLastEmit.isRunning && _sinceLastEmit.elapsed < interval) {
      return;
    }
    _sinceLastEmit
      ..reset()
      ..start();
    _emit(position);
  }

  void _emit(Duration position) {
    if (!_checkpoints.isClosed) {
      _checkpoints.add(position);
    }
    _onCheckpoint?.call(position);
  }

  /// Emits the final checkpoint and stops listening.
  void dispose() {
    final last = _lastPosition;
    if (last != null) {
      _emit(last);
    }
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_checkpoints.close());
  }
}

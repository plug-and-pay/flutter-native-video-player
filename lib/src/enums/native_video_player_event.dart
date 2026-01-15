/// Player activity state representing playback status
enum PlayerActivityState {
  idle,
  initializing,
  initialized,
  loading,
  loaded,
  playing,
  paused,
  buffering,
  completed,
  stopped,
  error,
}

/// Player control state for user interactions and settings
enum PlayerControlState {
  none,
  qualityChanged,
  speedChanged,
  seeked,
  pipStarted,
  pipStopped,
  pipAvailabilityChanged,
  airPlayAvailabilityChanged,
  airPlayConnected,
  airPlayDisconnected,
  fullscreenEntered,
  fullscreenExited,
  timeUpdated,
}

/// Activity state event for playback changes
class PlayerActivityEvent {
  const PlayerActivityEvent({required this.state, this.data});

  factory PlayerActivityEvent.fromMap(Map<dynamic, dynamic> map) {
    final String eventName = map['event'] as String;
    final PlayerActivityState state = _stateFromString(eventName);

    final Map<String, dynamic> data = Map<String, dynamic>.from(map)
      ..remove('event');

    return PlayerActivityEvent(state: state, data: data.isEmpty ? null : data);
  }

  final PlayerActivityState state;
  final Map<String, dynamic>? data;

  static PlayerActivityState _stateFromString(String event) {
    switch (event) {
      case 'isInitialized':
        return PlayerActivityState.initialized;
      case 'loaded':
        return PlayerActivityState.loaded;
      case 'play':
        return PlayerActivityState.playing;
      case 'pause':
        return PlayerActivityState.paused;
      case 'buffering':
        return PlayerActivityState.buffering;
      case 'loading':
        return PlayerActivityState.loading;
      case 'completed':
        return PlayerActivityState.completed;
      case 'stopped':
        return PlayerActivityState.stopped;
      case 'error':
        return PlayerActivityState.error;
      case 'idle':
        return PlayerActivityState.idle;
      default:
        return PlayerActivityState.idle;
    }
  }
}

/// Control state event for user interactions and settings
class PlayerControlEvent {
  const PlayerControlEvent({required this.state, this.data});

  factory PlayerControlEvent.fromMap(Map<dynamic, dynamic> map) {
    final String eventName = map['event'] as String;
    final PlayerControlState state = _stateFromString(eventName, map);

    final Map<String, dynamic> data = Map<String, dynamic>.from(map)
      ..remove('event');

    return PlayerControlEvent(state: state, data: data.isEmpty ? null : data);
  }

  final PlayerControlState state;
  final Map<String, dynamic>? data;

  static PlayerControlState _stateFromString(
    String event,
    Map<dynamic, dynamic> map,
  ) {
    switch (event) {
      case 'qualityChange':
        return PlayerControlState.qualityChanged;
      case 'speedChange':
        return PlayerControlState.speedChanged;
      case 'seek':
        return PlayerControlState.seeked;
      case 'pipStart':
        return PlayerControlState.pipStarted;
      case 'pipStop':
        return PlayerControlState.pipStopped;
      case 'pipAvailabilityChanged':
        return PlayerControlState.pipAvailabilityChanged;
      case 'airPlayAvailabilityChanged':
        return PlayerControlState.airPlayAvailabilityChanged;
      case 'airPlayConnectionChanged':
        // Check if connected or disconnected from data
        final bool isConnected = map['isConnected'] as bool? ?? false;
        return isConnected
            ? PlayerControlState.airPlayConnected
            : PlayerControlState.airPlayDisconnected;
      case 'fullscreenChange':
        // Check if entering or exiting fullscreen from data
        final bool isFullscreen = map['isFullscreen'] as bool? ?? true;
        return isFullscreen
            ? PlayerControlState.fullscreenEntered
            : PlayerControlState.fullscreenExited;
      case 'timeUpdate':
      case 'timeUpdated': // Native side sends 'timeUpdated' in some cases
        return PlayerControlState.timeUpdated;
      default:
        return PlayerControlState.none;
    }
  }
}

/// Extension methods for activity state
extension PlayerActivityStateExtension on PlayerActivityState {
  bool get isInitializing => this == PlayerActivityState.initializing;
  bool get isInitialized => this == PlayerActivityState.initialized;
  bool get isLoading => this == PlayerActivityState.loading;
  bool get isLoaded => this == PlayerActivityState.loaded;
  bool get isPlaying => this == PlayerActivityState.playing;
  bool get isBuffering => this == PlayerActivityState.buffering;
  bool get isPaused => this == PlayerActivityState.paused;
  bool get hasError => this == PlayerActivityState.error;
  bool get isCompleted => this == PlayerActivityState.completed;
  bool get isStopped => this == PlayerActivityState.stopped;
  bool get isIdle => this == PlayerActivityState.idle;
}

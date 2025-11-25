import '../enums/native_video_player_event.dart';
import 'native_video_player_quality.dart';
import 'native_video_player_subtitle_track.dart';

/// Represents the state of the native video player
class NativeVideoPlayerState {
  const NativeVideoPlayerState({
    this.isFullScreen = false,
    this.currentPosition = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.volume = 1.0,
    this.speed = 1.0,
    this.qualities = const <NativeVideoPlayerQuality>[],
    this.subtitleTracks = const <NativeVideoPlayerSubtitleTrack>[],
    this.activityState = PlayerActivityState.idle,
    this.controlState = PlayerControlState.none,
    this.isPipEnabled = false,
    this.isPipAvailable = false,
    this.isAirplayAvailable = false,
    this.isAirplayConnected = false,
    this.isAirplayConnecting = false,
    this.airPlayDeviceName,
  });

  /// Whether the video is currently in fullscreen mode
  final bool isFullScreen;

  /// Current playback position
  final Duration currentPosition;

  /// Total video duration
  final Duration duration;

  /// Buffered position (how far the video has been buffered)
  final Duration bufferedPosition;

  /// Current volume (0.0 to 1.0)
  final double volume;

  /// Current playback speed
  final double speed;

  /// Available video qualities (HLS variants)
  final List<NativeVideoPlayerQuality> qualities;

  /// Available subtitle/caption tracks
  final List<NativeVideoPlayerSubtitleTrack> subtitleTracks;

  /// Current activity state (playing, paused, buffering, etc.)
  final PlayerActivityState activityState;

  /// Current control state (quality change, speed change, pip, fullscreen, etc.)
  final PlayerControlState controlState;

  /// Whether Picture-in-Picture mode is currently active
  final bool isPipEnabled;

  /// Whether Picture-in-Picture is available on the device
  final bool isPipAvailable;

  /// Whether AirPlay is available on the device
  final bool isAirplayAvailable;

  /// Whether the video is currently connected to an AirPlay device
  final bool isAirplayConnected;

  /// Whether the video is currently connecting to an AirPlay device
  final bool isAirplayConnecting;

  /// The name of the currently connected AirPlay device, or null if not connected
  final String? airPlayDeviceName;

  /// Creates a copy of this state with the given fields replaced with new values
  NativeVideoPlayerState copyWith({
    bool? isFullScreen,
    Duration? currentPosition,
    Duration? duration,
    Duration? bufferedPosition,
    double? volume,
    double? speed,
    List<NativeVideoPlayerQuality>? qualities,
    List<NativeVideoPlayerSubtitleTrack>? subtitleTracks,
    PlayerActivityState? activityState,
    PlayerControlState? controlState,
    bool? isPipEnabled,
    bool? isPipAvailable,
    bool? isAirplayAvailable,
    bool? isAirplayConnected,
    bool? isAirplayConnecting,
    String? airPlayDeviceName,
  }) {
    return NativeVideoPlayerState(
      isFullScreen: isFullScreen ?? this.isFullScreen,
      currentPosition: currentPosition ?? this.currentPosition,
      duration: duration ?? this.duration,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      volume: volume ?? this.volume,
      speed: speed ?? this.speed,
      qualities: qualities ?? this.qualities,
      subtitleTracks: subtitleTracks ?? this.subtitleTracks,
      activityState: activityState ?? this.activityState,
      controlState: controlState ?? this.controlState,
      isPipEnabled: isPipEnabled ?? this.isPipEnabled,
      isPipAvailable: isPipAvailable ?? this.isPipAvailable,
      isAirplayAvailable: isAirplayAvailable ?? this.isAirplayAvailable,
      isAirplayConnected: isAirplayConnected ?? this.isAirplayConnected,
      isAirplayConnecting: isAirplayConnecting ?? this.isAirplayConnecting,
      airPlayDeviceName: airPlayDeviceName ?? this.airPlayDeviceName,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is NativeVideoPlayerState &&
        other.isFullScreen == isFullScreen &&
        other.currentPosition == currentPosition &&
        other.duration == duration &&
        other.bufferedPosition == bufferedPosition &&
        other.volume == volume &&
        other.speed == speed &&
        other.qualities == qualities &&
        other.subtitleTracks == subtitleTracks &&
        other.activityState == activityState &&
        other.controlState == controlState &&
        other.isPipEnabled == isPipEnabled &&
        other.isPipAvailable == isPipAvailable &&
        other.isAirplayAvailable == isAirplayAvailable &&
        other.isAirplayConnected == isAirplayConnected &&
        other.isAirplayConnecting == isAirplayConnecting &&
        other.airPlayDeviceName == airPlayDeviceName;
  }

  @override
  int get hashCode {
    return Object.hash(
      isFullScreen,
      currentPosition,
      duration,
      bufferedPosition,
      volume,
      speed,
      qualities,
      subtitleTracks,
      activityState,
      controlState,
      isPipEnabled,
      isPipAvailable,
      isAirplayAvailable,
      isAirplayConnected,
      isAirplayConnecting,
      airPlayDeviceName,
    );
  }
}

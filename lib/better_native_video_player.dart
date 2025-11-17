/// A Flutter plugin for native video playback on iOS and Android.
///
/// This plugin provides a native video player that uses AVPlayerViewController
/// on iOS and ExoPlayer (Media3) on Android, offering features like:
/// - HLS streaming with quality selection
/// - Picture-in-Picture support
/// - AirPlay support with device name tracking (iOS)
/// - Fullscreen playback (native and Dart-based)
/// - Custom overlay widgets
/// - Now Playing integration (Control Center / lock screen)
/// - Background playback with media notifications
library;

export 'src/controllers/native_video_player_controller.dart';
export 'src/enums/native_video_player_event.dart';
export 'src/fullscreen/fullscreen_manager.dart';
export 'src/fullscreen/fullscreen_video_player.dart';
export 'src/models/native_video_player_media_info.dart';
export 'src/models/native_video_player_quality.dart';
export 'src/models/native_video_player_state.dart';
export 'src/native_video_player_widget.dart';
export 'src/platform/platform_utils.dart';
export 'src/services/airplay_state_manager.dart';

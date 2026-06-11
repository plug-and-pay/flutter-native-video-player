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

export 'src/config/native_video_player_config.dart';
export 'src/controllers/native_video_player_controller.dart';
export 'src/enums/native_video_player_event.dart';
export 'src/fullscreen/fullscreen_manager.dart';
export 'src/fullscreen/fullscreen_video_player.dart';
export 'src/models/native_video_player_audio_track.dart';
export 'src/models/native_video_player_download.dart';
export 'src/models/native_video_player_media_info.dart';
export 'src/models/native_video_player_playback_range.dart';
export 'src/models/native_video_player_quality.dart';
export 'src/models/native_video_player_sidecar_subtitle.dart';
export 'src/models/native_video_player_state.dart';
export 'src/models/native_video_player_subtitle_style.dart';
export 'src/models/native_video_player_subtitle_track.dart';
export 'src/models/native_video_player_video_size.dart';
export 'src/subtitles/storyboard_thumbnails.dart';
export 'src/subtitles/subtitle_cue.dart';
export 'src/subtitles/subtitle_parser.dart' show SubtitleFormat;
export 'src/native_video_player_widget.dart';
export 'src/platform/platform_utils.dart';
export 'src/services/airplay_state_manager.dart';
export 'src/services/background_playback_guard.dart';
export 'src/services/native_video_player_cache.dart';
export 'src/services/video_download_controller.dart';
export 'src/services/native_video_player_playlist.dart';
export 'src/services/playback_analytics.dart';
export 'src/services/position_checkpoints.dart';

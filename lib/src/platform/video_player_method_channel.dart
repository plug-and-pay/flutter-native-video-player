import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/native_video_player_quality.dart';

/// Handles all method channel communication with the native platform
class VideoPlayerMethodChannel {
  VideoPlayerMethodChannel({required this.primaryPlatformViewId})
    : _methodChannel = const MethodChannel('native_video_player');

  final int primaryPlatformViewId;
  final MethodChannel _methodChannel;

  /// Loads a video URL
  Future<void> load({
    required String url,
    required bool autoPlay,
    Map<String, String>? headers,
    Map<String, dynamic>? mediaInfo,
  }) async {
    final Map<String, Object> params = <String, Object>{
      'url': url,
      'autoPlay': autoPlay,
      'viewId': primaryPlatformViewId,
    };

    if (headers != null) {
      params['headers'] = headers;
    }

    if (mediaInfo != null) {
      params['mediaInfo'] = mediaInfo;
    }

    await _methodChannel.invokeMethod<void>('load', params);
  }

  /// Starts or resumes video playback
  Future<void> play() async {
    try {
      await _methodChannel.invokeMethod<void>('play', <String, Object>{
        'viewId': primaryPlatformViewId,
      });
    } catch (e) {
      // Silently handle errors
    }
  }

  /// Pauses video playback
  Future<void> pause() async {
    try {
      await _methodChannel.invokeMethod<void>('pause', <String, Object>{
        'viewId': primaryPlatformViewId,
      });
    } catch (e) {
      debugPrint('Error calling pause: $e');
    }
  }

  /// Seeks to a specific position
  Future<void> seekTo(Duration position) async {
    try {
      await _methodChannel.invokeMethod<void>('seekTo', <String, Object>{
        'viewId': primaryPlatformViewId,
        'milliseconds': position.inMilliseconds,
      });
    } catch (e) {
      debugPrint('Error calling seekTo: $e');
    }
  }

  /// Sets the volume
  Future<void> setVolume(double volume) async {
    try {
      await _methodChannel.invokeMethod<void>('setVolume', <String, Object>{
        'viewId': primaryPlatformViewId,
        'volume': volume,
      });
    } catch (e) {
      debugPrint('Error calling setVolume: $e');
    }
  }

  /// Sets the playback speed
  Future<void> setSpeed(double speed) async {
    try {
      await _methodChannel.invokeMethod<void>('setSpeed', <String, Object>{
        'viewId': primaryPlatformViewId,
        'speed': speed,
      });
    } catch (e) {
      debugPrint('Error calling setSpeed: $e');
    }
  }

  /// Sets whether the video should loop
  Future<void> setLooping(bool looping) async {
    try {
      await _methodChannel.invokeMethod<void>('setLooping', <String, Object>{
        'viewId': primaryPlatformViewId,
        'looping': looping,
      });
    } catch (e) {
      debugPrint('Error calling setLooping: $e');
    }
  }

  /// Sets the video quality
  Future<void> setQuality(NativeVideoPlayerQuality quality) async {
    try {
      final Map<String, Object> params = <String, Object>{
        'viewId': primaryPlatformViewId,
        'quality': quality.toMap(),
      };
      await _methodChannel.invokeMethod<void>('setQuality', params);
    } catch (e) {
      debugPrint('Error calling setQuality: $e');
    }
  }

  /// Gets available video qualities
  Future<List<NativeVideoPlayerQuality>> getAvailableQualities() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'getAvailableQualities',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      if (result is List) {
        final qualities = result
            .map(
              (dynamic e) =>
                  NativeVideoPlayerQuality.fromMap(e as Map<dynamic, dynamic>),
            )
            .toList();
        return qualities;
      }
      debugPrint('No qualities found in result');
      return <NativeVideoPlayerQuality>[];
    } catch (e) {
      debugPrint('Error fetching qualities: $e');
      return <NativeVideoPlayerQuality>[];
    }
  }

  /// Checks if Picture-in-Picture is available
  Future<bool> isPictureInPictureAvailable() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'isPictureInPictureAvailable',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error checking PiP availability: $e');
      return false;
    }
  }

  /// Enters Picture-in-Picture mode
  Future<bool> enterPictureInPicture() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'enterPictureInPicture',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error calling enterPictureInPicture: $e');
      return false;
    }
  }

  /// Exits Picture-in-Picture mode
  Future<bool> exitPictureInPicture() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'exitPictureInPicture',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error calling exitPictureInPicture: $e');
      return false;
    }
  }

  /// Enters fullscreen mode
  Future<void> enterFullScreen() async {
    try {
      await _methodChannel.invokeMethod<void>(
        'enterFullScreen',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
    } catch (e) {
      debugPrint('Error calling enterFullScreen: $e');
    }
  }

  /// Exits fullscreen mode
  Future<void> exitFullScreen() async {
    try {
      await _methodChannel.invokeMethod<void>(
        'exitFullScreen',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
    } catch (e) {
      debugPrint('Error calling exitFullScreen: $e');
    }
  }

  /// Sets whether native player controls are shown
  Future<void> setShowNativeControls(bool show) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'setShowNativeControls',
        <String, Object>{'viewId': primaryPlatformViewId, 'show': show},
      );
    } catch (e) {
      debugPrint('Error calling setShowNativeControls: $e');
    }
  }

  /// Checks if AirPlay is available (iOS only)
  Future<bool> isAirPlayAvailable() async {
    try {
      final dynamic result = await _methodChannel.invokeMethod<dynamic>(
        'isAirPlayAvailable',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
      return result == true;
    } catch (e) {
      debugPrint('Error calling isAirPlayAvailable: $e');
      return false;
    }
  }

  /// Shows the AirPlay route picker (iOS only)
  Future<void> showAirPlayPicker() async {
    try {
      await _methodChannel.invokeMethod<void>(
        'showAirPlayPicker',
        <String, Object>{'viewId': primaryPlatformViewId},
      );
    } catch (e) {
      debugPrint('Error calling showAirPlayPicker: $e');
    }
  }

  /// Disposes the native player resources
  Future<void> dispose() async {
    try {
      await _methodChannel.invokeMethod<void>('dispose', <String, Object>{
        'viewId': primaryPlatformViewId,
      });
    } catch (e) {
      debugPrint('Error calling dispose: $e');
    }
  }
}

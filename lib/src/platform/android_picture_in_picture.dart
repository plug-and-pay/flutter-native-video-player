import 'package:flutter/services.dart';

/// Width-to-height ratio of the Android picture-in-picture window.
class PipAspectRatio {
  const PipAspectRatio(this.numerator, this.denominator);

  final int numerator;
  final int denominator;

  double get value => numerator / denominator;

  /// Android only accepts ratios between 1:2.39 and 2.39:1 (inclusive).
  bool get fitsAndroidLimits => value >= 1 / 2.39 && value <= 2.39;

  @override
  String toString() => '$numerator:$denominator';
}

/// Android picture-in-picture, backed by the plugin's own activity handling.
///
/// On Android the whole activity becomes the PiP window, so this state is
/// app-wide: one shared instance, like the activity it drives.
class AndroidPictureInPicture {
  AndroidPictureInPicture._();

  static final AndroidPictureInPicture instance = AndroidPictureInPicture._();

  static const MethodChannel _channel = MethodChannel(
    'native_video_player/pip',
  );

  bool? _isAvailable;

  /// Whether the device supports PiP (Android 8+ and the system feature).
  /// Cached once known, since it doesn't change while the app runs.
  Future<bool> get isAvailable async {
    _isAvailable ??= await _channel.invokeMethod<bool>('isAvailable');
    return _isAvailable ?? false;
  }

  /// Whether the activity is in PiP right now.
  Future<bool> get isInPictureInPicture async {
    if (!await isAvailable) {
      return false;
    }
    return await _channel.invokeMethod<bool>('isInPictureInPictureMode') ??
        false;
  }

  /// Enters PiP right away. Returns whether the activity entered it.
  Future<bool> enterNow(PipAspectRatio aspectRatio) =>
      _enable(aspectRatio, autoEnter: false);

  /// Enters PiP automatically when the user leaves the app (Android 12+;
  /// throws a [PlatformException] below that).
  Future<void> enableOnLeave(PipAspectRatio aspectRatio) =>
      _enable(aspectRatio, autoEnter: true);

  /// Stops [enableOnLeave] from entering PiP on the next leave.
  Future<void> cancelOnLeave() => _channel.invokeMethod<void>('cancelAutoEnter');

  Future<bool> _enable(
    PipAspectRatio aspectRatio, {
    required bool autoEnter,
  }) async {
    if (!aspectRatio.fitsAndroidLimits) {
      throw ArgumentError.value(
        aspectRatio,
        'aspectRatio',
        'Android PiP needs a ratio between 1:2.39 and 2.39:1',
      );
    }

    // Clear an earlier on-leave request so it can't outlive this one.
    await cancelOnLeave();
    return await _channel.invokeMethod<bool>(
          'enable',
          <String, Object>{
            'numerator': aspectRatio.numerator,
            'denominator': aspectRatio.denominator,
            'autoEnter': autoEnter,
          },
        ) ??
        false;
  }
}

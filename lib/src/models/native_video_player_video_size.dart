import 'package:flutter/foundation.dart';

/// The native video's display dimensions, reported by texture-rendered
/// views (see `NativeVideoPlayerConfig.androidTextureMode`) so the widget
/// can letterbox the `Texture` to the correct aspect ratio.
@immutable
class NativeVideoPlayerVideoSize {
  const NativeVideoPlayerVideoSize({
    required this.width,
    required this.height,
    this.rotationCorrection = 0,
  });

  /// Display width in pixels (pixel aspect ratio already applied).
  final double width;

  /// Display height in pixels.
  final double height;

  /// Clockwise degrees (0/90/180/270) the widget must rotate the texture.
  /// Non-zero only on engine backends that don't handle rotation natively.
  final int rotationCorrection;

  /// Width/height corrected for [rotationCorrection].
  double get aspectRatio =>
      rotationCorrection % 180 == 0 ? width / height : height / width;
}

import 'package:flutter/widgets.dart';

/// Visual style AND position for sidecar subtitles rendered by the plugin's
/// Flutter overlay (covers the caption customization requested in issue
/// #29: size, colors, and where on the video the captions sit).
///
/// Applies to sidecar (VTT/SRT) subtitles only; EMBEDDED native subtitle
/// tracks are rendered by the platform with system caption settings.
///
/// To change the style at runtime, rebuild the [NativeVideoPlayer] widget
/// with a new `subtitleStyle` (the overlay rebuilds immediately).
@immutable
class NativeVideoPlayerSubtitleStyle {
  const NativeVideoPlayerSubtitleStyle({
    this.fontSize = 16,
    this.fontWeight = FontWeight.w500,
    this.fontStyle = FontStyle.normal,
    this.fontFamily,
    this.lineHeight,
    this.textColor = const Color(0xFFFFFFFF),
    this.backgroundColor = const Color(0xB3000000),
    this.outlineColor,
    this.outlineWidth = 0,
    this.alignment = Alignment.bottomCenter,
    this.padding = const EdgeInsets.only(bottom: 24, left: 16, right: 16),
    this.textAlign = TextAlign.center,
    this.fullscreenLandscapeFontSize,
    this.fullscreenLandscapeFontWeight,
    this.fullscreenLandscapeLineHeight,
  });

  // --- Text ---
  final double fontSize;
  final FontWeight fontWeight;
  final FontStyle fontStyle;

  /// Custom font family; null uses the app's default.
  final String? fontFamily;

  /// Line height multiplier (TextStyle.height); null uses the font default.
  final double? lineHeight;

  final Color textColor;

  /// Background behind each cue line (translucent black by default).
  final Color backgroundColor;

  /// Optional text outline for readability on busy video.
  final Color? outlineColor;
  final double outlineWidth;

  // --- Position ---

  /// Where the cue block sits on the video surface: any [Alignment]
  /// (e.g. [Alignment.bottomCenter] default, [Alignment.topCenter] for
  /// top-positioned captions, [Alignment.center], corners, ...).
  final Alignment alignment;

  /// Space between the cue block and the video edges.
  final EdgeInsets padding;

  /// Text alignment within multi-line cues.
  final TextAlign textAlign;

  // --- Fullscreen-landscape overrides ---

  /// When the player is fullscreen AND in landscape, these override the base
  /// typography so captions can grow for the large-video experience. Each is
  /// null by default, falling back to the matching base value
  /// ([fontSize] / [fontWeight] / [lineHeight]). They have no effect inline or
  /// in fullscreen-portrait, where the base values are always used.
  final double? fullscreenLandscapeFontSize;
  final FontWeight? fullscreenLandscapeFontWeight;
  final double? fullscreenLandscapeLineHeight;

  NativeVideoPlayerSubtitleStyle copyWith({
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    String? fontFamily,
    double? lineHeight,
    Color? textColor,
    Color? backgroundColor,
    Color? outlineColor,
    double? outlineWidth,
    Alignment? alignment,
    EdgeInsets? padding,
    TextAlign? textAlign,
    double? fullscreenLandscapeFontSize,
    FontWeight? fullscreenLandscapeFontWeight,
    double? fullscreenLandscapeLineHeight,
  }) {
    return NativeVideoPlayerSubtitleStyle(
      fontSize: fontSize ?? this.fontSize,
      fontWeight: fontWeight ?? this.fontWeight,
      fontStyle: fontStyle ?? this.fontStyle,
      fontFamily: fontFamily ?? this.fontFamily,
      lineHeight: lineHeight ?? this.lineHeight,
      textColor: textColor ?? this.textColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      outlineColor: outlineColor ?? this.outlineColor,
      outlineWidth: outlineWidth ?? this.outlineWidth,
      alignment: alignment ?? this.alignment,
      padding: padding ?? this.padding,
      textAlign: textAlign ?? this.textAlign,
      fullscreenLandscapeFontSize:
          fullscreenLandscapeFontSize ?? this.fullscreenLandscapeFontSize,
      fullscreenLandscapeFontWeight:
          fullscreenLandscapeFontWeight ?? this.fullscreenLandscapeFontWeight,
      fullscreenLandscapeLineHeight:
          fullscreenLandscapeLineHeight ?? this.fullscreenLandscapeLineHeight,
    );
  }
}

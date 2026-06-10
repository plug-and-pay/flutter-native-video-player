import 'package:flutter/foundation.dart';

import '../subtitles/subtitle_parser.dart';

/// An external (sidecar) subtitle source: a VTT or SRT file referenced by
/// URL, local file path, or provided as raw content.
///
/// Sidecar subtitles are parsed and rendered by the plugin in a Flutter
/// overlay layer (styleable via `NativeVideoPlayerSubtitleStyle`), so they
/// work identically for HLS and MP4 on both platforms. On Android the
/// source is ALSO attached natively (`MediaItem.SubtitleConfiguration`) so
/// captions stay visible in PiP and native fullscreen. Limitations: the
/// Flutter layer cannot render inside iOS native fullscreen, the iOS PiP
/// window, or on an AirPlay receiver (the cues keep rendering on the phone
/// during AirPlay; use embedded HLS tracks when receiver-side captions are
/// required).
@immutable
class NativeVideoPlayerSidecarSubtitle {
  const NativeVideoPlayerSidecarSubtitle.url(
    String this.url, {
    required this.language,
    required this.label,
    this.format,
  }) : filePath = null,
       content = null;

  const NativeVideoPlayerSidecarSubtitle.file(
    String this.filePath, {
    required this.language,
    required this.label,
    this.format,
  }) : url = null,
       content = null;

  const NativeVideoPlayerSidecarSubtitle.content(
    String this.content, {
    required this.language,
    required this.label,
    this.format,
  }) : url = null,
       filePath = null;

  /// Network location of the subtitle file (VTT/SRT).
  final String? url;

  /// Local file path of the subtitle file.
  final String? filePath;

  /// Raw subtitle text (already downloaded/bundled).
  final String? content;

  /// Explicit format; auto-detected from the extension/content when null.
  final SubtitleFormat? format;

  /// BCP-47 / ISO language code (e.g. "en", "nl").
  final String language;

  /// Human-readable name shown in track pickers (e.g. "English").
  final String label;

  /// Map representation sent to the Android side for native sideloading
  /// (URL sources only — file/content sources are materialized first).
  Map<String, dynamic> toMap() => <String, dynamic>{
    if (url != null) 'url': url,
    if (filePath != null) 'filePath': filePath,
    'language': language,
    'label': label,
    'format': (format ?? SubtitleFormat.vtt).name,
  };
}

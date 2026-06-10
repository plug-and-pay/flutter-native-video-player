import 'package:flutter/foundation.dart';

/// An A-B playback range: playback is confined to [start]..[end].
///
/// With [loop] enabled the player seeks back to [start] whenever the
/// position reaches [end] (A-B loop); without it the player pauses at
/// [end] once (clip range). Set via
/// `NativeVideoPlayerController.setPlaybackRange` and cleared with
/// `clearPlaybackRange` (loading a new video also clears it — a range is
/// meaningful only for the video it was set on).
@immutable
class NativeVideoPlayerPlaybackRange {
  const NativeVideoPlayerPlaybackRange({
    required this.start,
    required this.end,
    this.loop = true,
  }) : assert(end > start, 'end must be after start');

  /// Range start (the loop's "A" point).
  final Duration start;

  /// Range end (the loop's "B" point).
  final Duration end;

  /// Seek back to [start] at [end] (true) or pause once at [end] (false).
  final bool loop;

  /// Whether [position] lies inside the range.
  bool contains(Duration position) => position >= start && position < end;

  @override
  String toString() =>
      'NativeVideoPlayerPlaybackRange(${start.inMilliseconds}ms..'
      '${end.inMilliseconds}ms, loop: $loop)';
}

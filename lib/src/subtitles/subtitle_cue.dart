import 'package:flutter/foundation.dart';

/// One timed subtitle cue parsed from a VTT/SRT source.
@immutable
class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.lines,
  });

  /// Cue start, relative to playback position zero.
  final Duration start;

  /// Cue end (exclusive).
  final Duration end;

  /// The cue text, one entry per visual line.
  final List<String> lines;

  /// Whether this cue should be visible at [position].
  bool isActiveAt(Duration position) => position >= start && position < end;

  @override
  String toString() =>
      'SubtitleCue(${start.inMilliseconds}-${end.inMilliseconds}ms, '
      '${lines.join(r'\n')})';
}

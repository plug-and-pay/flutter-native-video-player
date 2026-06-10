import 'subtitle_cue.dart';

/// Subtitle text formats supported by the sidecar parser.
enum SubtitleFormat { vtt, srt }

/// Parser for sidecar subtitle files (WebVTT and SubRip).
///
/// Tolerant by design: malformed cues are skipped, never thrown on — a
/// subtitle file must not be able to break playback. The structural
/// approach (split blocks on blank lines, find the `-->` timing line)
/// follows better_player's proven parser, hardened for BOM/headers, both
/// `,`/`.` millisecond separators, optional hours, cue settings and inline
/// tags.
class SubtitleParser {
  SubtitleParser._();

  /// Splits `HH:MM:SS.mmm`, `MM:SS.mmm` (comma or dot before millis).
  static final RegExp _timestampPattern = RegExp(
    r'^(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[.,](\d{1,3})$',
  );

  /// Inline markup stripped from cue text: `<i>`, `</b>`, `<v Name>`,
  /// `<c.classname>`, `{b}`-style SRT tags, etc.
  static final RegExp _inlineTags = RegExp(r'<[^>]*>|\{[^}]*\}');

  /// Detects the format from a file name/URL extension or the content's
  /// first line. Defaults to [SubtitleFormat.srt] when nothing matches —
  /// SRT's numbered blocks also parse fine through the structural parser.
  static SubtitleFormat detectFormat({String? name, String? content}) {
    final lower = name?.toLowerCase() ?? '';
    if (lower.endsWith('.vtt')) return SubtitleFormat.vtt;
    if (lower.endsWith('.srt')) return SubtitleFormat.srt;
    if (content != null && _stripBom(content).trimLeft().startsWith('WEBVTT')) {
      return SubtitleFormat.vtt;
    }
    return SubtitleFormat.srt;
  }

  /// Parses [content] into a list of cues sorted by start time.
  /// The [format] only affects header handling; cue blocks are structural.
  static List<SubtitleCue> parse(String content, {SubtitleFormat? format}) {
    final text = _stripBom(content).replaceAll('\r\n', '\n');
    final cues = <SubtitleCue>[];

    for (final block in text.split(RegExp(r'\n\s*\n'))) {
      final lines = block
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) continue;

      // Skip VTT header/metadata blocks (WEBVTT, NOTE, STYLE, REGION).
      final first = lines.first;
      if (first.startsWith('WEBVTT') ||
          first.startsWith('NOTE') ||
          first.startsWith('STYLE') ||
          first.startsWith('REGION')) {
        continue;
      }

      // Find the timing line ("start --> end [settings]"); anything before
      // it is an SRT index or VTT cue identifier, anything after is text.
      final timingIndex = lines.indexWhere((l) => l.contains('-->'));
      if (timingIndex == -1 || timingIndex == lines.length - 1) continue;

      final timingParts = lines[timingIndex].split('-->');
      if (timingParts.length != 2) continue;

      final start = _parseTimestamp(timingParts[0].trim());
      // VTT cue settings (position/align/...) follow the end timestamp.
      final end = _parseTimestamp(timingParts[1].trim().split(' ').first);
      if (start == null || end == null || end <= start) continue;

      final cueLines = lines
          .sublist(timingIndex + 1)
          .map((l) => l.replaceAll(_inlineTags, '').trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (cueLines.isEmpty) continue;

      cues.add(SubtitleCue(start: start, end: end, lines: cueLines));
    }

    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  static Duration? _parseTimestamp(String raw) {
    final match = _timestampPattern.firstMatch(raw);
    if (match == null) return null;
    final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
    final minutes = int.parse(match.group(2)!);
    final seconds = int.parse(match.group(3)!);
    // "5" means 500ms, "05" means 50ms, "005" means 5ms.
    final millis = int.parse(match.group(4)!.padRight(3, '0'));
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: millis,
    );
  }

  static String _stripBom(String s) =>
      s.startsWith('\u{FEFF}') ? s.substring(1) : s;
}

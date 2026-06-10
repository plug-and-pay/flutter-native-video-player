import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:better_native_video_player/src/subtitles/subtitle_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('format detection', () {
    test('by extension', () {
      expect(
        SubtitleParser.detectFormat(name: 'subs/movie.VTT'),
        SubtitleFormat.vtt,
      );
      expect(
        SubtitleParser.detectFormat(
          name: 'https://x.test/a.srt?token=1'.split('?').first,
        ),
        SubtitleFormat.srt,
      );
    });

    test('by WEBVTT header (with BOM)', () {
      expect(
        SubtitleParser.detectFormat(content: '\u{FEFF}WEBVTT\n\n'),
        SubtitleFormat.vtt,
      );
    });

    test('defaults to srt', () {
      expect(SubtitleParser.detectFormat(content: '1\n'), SubtitleFormat.srt);
    });
  });

  group('VTT parsing', () {
    test('parses cues with header, identifiers and settings', () {
      const vtt = '''
WEBVTT - some title

NOTE this is a comment

intro
00:00.500 --> 00:02.000 align:middle position:50%
Hello <i>world</i>

00:01:02.000 --> 00:01:04.500
Two lines
of text
''';
      final cues = SubtitleParser.parse(vtt, format: SubtitleFormat.vtt);
      expect(cues, hasLength(2));
      expect(cues[0].start, const Duration(milliseconds: 500));
      expect(cues[0].end, const Duration(seconds: 2));
      expect(cues[0].lines, ['Hello world']);
      expect(cues[1].start, const Duration(minutes: 1, seconds: 2));
      expect(cues[1].lines, ['Two lines', 'of text']);
    });

    test('voice and class tags are stripped', () {
      const vtt = '''
WEBVTT

00:00.000 --> 00:01.000
<v Fred>Hi there <c.yellow>friend</c>
''';
      final cues = SubtitleParser.parse(vtt);
      expect(cues.single.lines, ['Hi there friend']);
    });
  });

  group('SRT parsing', () {
    test('parses numbered blocks with comma milliseconds', () {
      const srt = '''
1
00:00:01,000 --> 00:00:02,500
Eerste regel

2
00:00:03,000 --> 00:00:05,000
Tweede {b}regel{/b}
''';
      final cues = SubtitleParser.parse(srt, format: SubtitleFormat.srt);
      expect(cues, hasLength(2));
      expect(cues[0].start, const Duration(seconds: 1));
      expect(cues[0].end, const Duration(milliseconds: 2500));
      expect(cues[1].lines, ['Tweede regel']);
    });

    test('windows line endings', () {
      final cues = SubtitleParser.parse(
        '1\r\n00:00:01,000 --> 00:00:02,000\r\nCRLF text\r\n',
      );
      expect(cues.single.lines, ['CRLF text']);
    });
  });

  group('robustness', () {
    test('malformed cues are skipped, never thrown', () {
      const broken = '''
not a cue at all

99:99 --> nonsense
Bad timing

2
00:00:05,000 --> 00:00:04,000
End before start

3
00:00:06,000 --> 00:00:07,000
Valid survivor
''';
      final cues = SubtitleParser.parse(broken);
      expect(cues, hasLength(1));
      expect(cues.single.lines, ['Valid survivor']);
    });

    test('cues come back sorted by start time', () {
      const srt = '''
1
00:00:10,000 --> 00:00:11,000
Later

2
00:00:01,000 --> 00:00:02,000
Earlier
''';
      final cues = SubtitleParser.parse(srt);
      expect(cues.first.lines, ['Earlier']);
    });

    test('empty input yields no cues', () {
      expect(SubtitleParser.parse(''), isEmpty);
      expect(SubtitleParser.parse('WEBVTT\n'), isEmpty);
    });
  });

  group('SubtitleCue', () {
    test('isActiveAt boundaries: start inclusive, end exclusive', () {
      const cue = SubtitleCue(
        start: Duration(seconds: 1),
        end: Duration(seconds: 2),
        lines: ['x'],
      );
      expect(cue.isActiveAt(const Duration(milliseconds: 999)), isFalse);
      expect(cue.isActiveAt(const Duration(seconds: 1)), isTrue);
      expect(cue.isActiveAt(const Duration(milliseconds: 1999)), isTrue);
      expect(cue.isActiveAt(const Duration(seconds: 2)), isFalse);
    });
  });
}

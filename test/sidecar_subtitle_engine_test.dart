import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:better_native_video_player/src/subtitles/sidecar_subtitle_engine.dart';
import 'package:flutter_test/flutter_test.dart';

const _vtt = '''
WEBVTT

00:00.000 --> 00:02.000
First cue

00:03.000 --> 00:05.000
Second cue
line two

00:05.000 --> 00:06.000
Third cue
''';

void main() {
  late SidecarSubtitleEngine engine;

  setUp(() {
    engine = SidecarSubtitleEngine();
    engine.setSources([
      const NativeVideoPlayerSidecarSubtitle.content(
        _vtt,
        language: 'en',
        label: 'English',
      ),
    ]);
  });

  tearDown(() => engine.dispose());

  test('nothing is emitted before a source is selected', () {
    engine.onPosition(const Duration(seconds: 1));
    expect(engine.activeCueLines.value, isEmpty);
  });

  test('select + position drives active cue lines', () async {
    await engine.select(0);
    engine.onPosition(const Duration(seconds: 1));
    expect(engine.activeCueLines.value, ['First cue']);

    engine.onPosition(const Duration(milliseconds: 2500)); // gap
    expect(engine.activeCueLines.value, isEmpty);

    engine.onPosition(const Duration(seconds: 4));
    expect(engine.activeCueLines.value, ['Second cue', 'line two']);
  });

  test('cue boundary is end-exclusive across adjacent cues', () async {
    await engine.select(0);
    engine.onPosition(const Duration(seconds: 5));
    expect(engine.activeCueLines.value, ['Third cue']);
  });

  test('seek backwards re-anchors', () async {
    await engine.select(0);
    engine.onPosition(const Duration(seconds: 4));
    expect(engine.activeCueLines.value, ['Second cue', 'line two']);
    engine.onPosition(Duration.zero);
    expect(engine.activeCueLines.value, ['First cue']);
  });

  test('deselect clears active lines', () async {
    await engine.select(0);
    engine.onPosition(const Duration(seconds: 1));
    expect(engine.activeCueLines.value, isNotEmpty);
    engine.deselect();
    expect(engine.activeCueLines.value, isEmpty);
    expect(engine.selectedSource, isNull);
  });

  test('setSources resets selection and cache', () async {
    await engine.select(0);
    engine.setSources([
      const NativeVideoPlayerSidecarSubtitle.content(
        'WEBVTT\n\n00:00.000 --> 00:01.000\nOther\n',
        language: 'nl',
        label: 'Nederlands',
      ),
    ]);
    expect(engine.selectedSource, isNull);
    await engine.select(0);
    engine.onPosition(Duration.zero);
    expect(engine.activeCueLines.value, ['Other']);
  });

  test('select with invalid index throws RangeError', () {
    expect(() => engine.select(5), throwsRangeError);
  });
}

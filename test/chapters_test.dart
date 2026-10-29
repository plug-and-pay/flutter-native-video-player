import 'dart:async';
import 'dart:ui' as ui;

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _intro = NativeVideoPlayerChapter(start: Duration.zero, title: 'Intro');
const _partTwo = NativeVideoPlayerChapter(
  start: Duration(seconds: 30),
  title: 'Part two',
);
const _outro = NativeVideoPlayerChapter(
  start: Duration(seconds: 45),
  title: 'Outro',
);
const _chapters = [_intro, _partTwo, _outro];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseText', () {
    test('reads timestamp-first lines and skips the rest', () {
      final chapters = NativeVideoPlayerChapters.parseText('''
In this video we build a player.

0:00 Intro
1:23 - Setting up
(12:05) Outro: thanks!
1:02:03 | Bonus
Not a chapter at 2:30 in the middle
''');
      expect(chapters.map((c) => (c.start, c.title)), [
        (Duration.zero, 'Intro'),
        (const Duration(minutes: 1, seconds: 23), 'Setting up'),
        (const Duration(minutes: 12, seconds: 5), 'Outro: thanks!'),
        (const Duration(hours: 1, minutes: 2, seconds: 3), 'Bonus'),
      ]);
    });

    test('reads timestamp-last lines, bullets and brackets', () {
      final chapters = NativeVideoPlayerChapters.parseText(
        '• Intro - 0:00\n- Part two (1:23)\n[2:00] Outro',
      );
      expect(chapters.map((c) => (c.start, c.title)), [
        (Duration.zero, 'Intro'),
        (const Duration(minutes: 1, seconds: 23), 'Part two'),
        (const Duration(minutes: 2), 'Outro'),
      ]);
    });

    test('sorts, keeps the first of a shared start, skips bad times', () {
      final chapters = NativeVideoPlayerChapters.parseText(
        '2:00 Later\n0:00 First\n0:00 Duplicate\n1:75 Bad seconds\n3:00',
      );
      expect(chapters.map((c) => c.title), ['First', 'Later']);
    });

    test('handles Windows line endings and empty input', () {
      expect(NativeVideoPlayerChapters.parseText(''), isEmpty);
      expect(
        NativeVideoPlayerChapters.parseText(
          '0:00 A\r\n0:10 B\r\n',
        ).map((c) => c.title),
        ['A', 'B'],
      );
    });
  });

  group('parseVtt', () {
    test('takes cue starts and text, ignores cue ends', () {
      final chapters = NativeVideoPlayerChapters.parseVtt('''WEBVTT

chapter-1
00:00:00.000 --> 00:00:30.000
Intro

chapter-2
00:00:30.000 --> 00:00:40.000
Part <b>two</b>

00:00:45.500 --> 00:01:00.000
Outro
''');
      expect(chapters.map((c) => (c.start, c.title)), [
        (Duration.zero, 'Intro'),
        (const Duration(seconds: 30), 'Part two'),
        (const Duration(seconds: 45, milliseconds: 500), 'Outro'),
      ]);
    });
  });

  group('chapter math', () {
    test('indexAt / chapterAt find the chapter playing at a position', () {
      expect(NativeVideoPlayerChapters.indexAt(_chapters, Duration.zero), 0);
      expect(
        NativeVideoPlayerChapters.chapterAt(
          _chapters,
          const Duration(seconds: 30),
        ),
        _partTwo,
      );
      expect(
        NativeVideoPlayerChapters.chapterAt(
          _chapters,
          const Duration(minutes: 5),
        ),
        _outro,
      );
      expect(
        NativeVideoPlayerChapters.indexAt(const [
          _partTwo,
        ], const Duration(seconds: 10)),
        -1,
      );
      expect(NativeVideoPlayerChapters.indexAt(const [], Duration.zero), -1);
    });

    test('segments cover the bar, one per chapter', () {
      final segments = NativeVideoPlayerChapters.segments(
        _chapters,
        const Duration(seconds: 60),
      );
      expect(segments.map((s) => (s.startFraction, s.endFraction)), [
        (0.0, 0.5),
        (0.5, 0.75),
        (0.75, 1.0),
      ]);
      expect(segments.map((s) => s.chapter), _chapters);
      expect(segments.last.end, const Duration(seconds: 60));
      expect(segments[1].contains(const Duration(seconds: 44)), isTrue);
      expect(segments[1].contains(const Duration(seconds: 45)), isFalse);
    });

    test('segments add an untitled lead-in and drop chapters past the end', () {
      final segments = NativeVideoPlayerChapters.segments(const [
        _partTwo,
        _outro,
      ], const Duration(seconds: 40));
      expect(segments.map((s) => (s.index, s.chapter?.title)), [
        (-1, null),
        (0, 'Part two'),
      ]);
      expect(segments.last.endFraction, 1.0);
    });

    test('segments without chapters or duration', () {
      expect(
        NativeVideoPlayerChapters.segments(
          const [],
          const Duration(seconds: 9),
        ),
        hasLength(1),
      );
      expect(
        NativeVideoPlayerChapters.segments(_chapters, Duration.zero),
        isEmpty,
      );
    });

    test('snapTarget snaps within the threshold, to the nearest start', () {
      const threshold = Duration(seconds: 1);
      Duration? snap(int ms) => NativeVideoPlayerChapters.snapTarget(
        _chapters,
        Duration(milliseconds: ms),
        threshold: threshold,
      );
      expect(snap(29200), const Duration(seconds: 30)); // just before
      expect(snap(30900), const Duration(seconds: 30)); // just after
      expect(snap(28500), isNull); // too far
      expect(snap(44500), const Duration(seconds: 45));
      expect(snap(300), isNull, reason: 'zero is not a snap point');
      expect(
        NativeVideoPlayerChapters.snap(
          _chapters,
          const Duration(seconds: 20),
          threshold: threshold,
        ),
        const Duration(seconds: 20),
      );
    });

    test('snapTarget picks the closer of two nearby starts', () {
      const close = [
        NativeVideoPlayerChapter(start: Duration(seconds: 10), title: 'a'),
        NativeVideoPlayerChapter(start: Duration(seconds: 11), title: 'b'),
      ];
      expect(
        NativeVideoPlayerChapters.snapTarget(
          close,
          const Duration(milliseconds: 10600),
          threshold: const Duration(seconds: 2),
        ),
        const Duration(seconds: 11),
      );
    });
  });

  group('storyboard precache order', () {
    test('imageUrlsAround: the sheet at the position first, then outward', () {
      final storyboard = StoryboardThumbnails.fromUniformGrid(
        spriteUrls: const ['s0', 's1', 's2', 's3', 's4'],
        frameInterval: const Duration(seconds: 1),
        columns: 2,
        frameWidth: 10,
        frameHeight: 10,
        framesPerSprite: 4,
      );
      expect(storyboard.imageUrlsAround(const Duration(seconds: 9), limit: 3), [
        's2',
        's1', // frame 7 is nearer to frame 9 than frame 12
        's3',
      ]);
      expect(storyboard.imageUrlsAround(Duration.zero, limit: 2), ['s0', 's1']);
      expect(storyboard.imageUrlsAround(Duration.zero, limit: 0), isEmpty);
    });
  });

  group('Bunny storyboard from the playlist URL', () {
    test('keeps a query token', () {
      final storyboard = StoryboardThumbnails.bunnyFromPlaylistUrl(
        'https://vz-abc.b-cdn.net/guid/playlist.m3u8?token=t&expires=1',
        duration: const Duration(minutes: 3),
      )!;
      expect(
        storyboard.entries.first.url,
        'https://vz-abc.b-cdn.net/guid/seek/_0.jpg?token=t&expires=1',
      );
      // 90 frames every 2 s, 36 per sheet: 3 sheets.
      expect(storyboard.entries.map((e) => e.url).toSet(), hasLength(3));
    });

    test('keeps a path token', () {
      final storyboard = StoryboardThumbnails.bunnyFromPlaylistUrl(
        'https://vz-abc.b-cdn.net/bcdn_token=t&expires=1&token_path=%2Fguid%2F'
        '/guid/playlist.m3u8',
        duration: const Duration(seconds: 30),
      )!;
      expect(
        storyboard.entries.first.url,
        'https://vz-abc.b-cdn.net/bcdn_token=t&expires=1&token_path=%2Fguid%2F'
        '/guid/seek/_0.jpg',
      );
    });

    test('without an aspect ratio, the frame height comes from the sheet', () {
      // 90 s at a frame every 2 s: 45 frames, one full sheet + 9 frames.
      final storyboard = StoryboardThumbnails.bunnyFromPlaylistUrl(
        'https://vz-abc.b-cdn.net/guid/playlist.m3u8',
        duration: const Duration(seconds: 90),
      )!;
      final first = storyboard.thumbnailAt(const Duration(seconds: 14))!;
      // Frame 7: column 1, row 1. A portrait sheet: 6 rows of 300 x 533.
      expect(
        first.regionIn(const Size(1800, 3198)),
        const Rect.fromLTWH(300, 533, 300, 533),
      );
      // Bunny pads the partly filled last sheet (9 frames) to the full
      // 6 x 6 grid too; frame 44 is its 9th: column 2, row 1.
      final last = storyboard.thumbnailAt(const Duration(seconds: 88))!;
      expect(last.gridCell!.rows, 6);
      expect(
        last.regionIn(const Size(1800, 3198)),
        const Rect.fromLTWH(600, 533, 300, 533),
      );
      // With a known aspect ratio nothing is measured.
      final known = StoryboardThumbnails.bunny(
        videoBaseUrl: 'https://vz-abc.b-cdn.net/guid',
        duration: const Duration(seconds: 90),
        aspectRatio: 9 / 16,
      );
      expect(known.entries.first.gridCell, isNull);
      expect(
        known.entries[7].regionIn(const Size(1800, 3198)),
        const Rect.fromLTWH(300, 533, 300, 533),
      );
    });

    test('null without a path', () {
      expect(
        StoryboardThumbnails.bunnyFromPlaylistUrl(
          'https://vz-abc.b-cdn.net',
          duration: const Duration(seconds: 30),
        ),
        isNull,
      );
    });
  });

  group('NativeVideoPlayerProgressBar without a controller', () {
    Widget host(Widget bar) => MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 300),
          child: SizedBox(width: 400, child: bar),
        ),
      ),
    );

    Offset at(WidgetTester tester, double x) =>
        tester.getTopLeft(find.byType(NativeVideoPlayerProgressBar)) +
        Offset(x, 16);

    Future<void> drag(WidgetTester tester, double from, double to) async {
      final gesture = await tester.startGesture(at(tester, from));
      await gesture.moveTo(at(tester, (from + to) / 2));
      await gesture.moveTo(at(tester, to));
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    testWidgets('uses the values and onSeek it is given, with callbacks', (
      tester,
    ) async {
      final seeks = <Duration>[];
      final events = <String>[];
      await tester.pumpWidget(
        host(
          NativeVideoPlayerProgressBar(
            position: const Duration(seconds: 10),
            duration: const Duration(seconds: 60),
            chapters: _chapters,
            onSeek: seeks.add,
            hapticFeedback: false,
            onScrubStart: (_) => events.add('start'),
            onScrubEnd: (p) => events.add('end ${p.inSeconds}'),
          ),
        ),
      );
      await drag(tester, 100, 205);
      expect(seeks, [const Duration(seconds: 30)], reason: 'snapped');
      expect(events, ['start', 'end 30']);
    });

    testWidgets('preview, chapter and snap callbacks', (tester) async {
      final previews = <NativeVideoPlayerScrubDetails?>[];
      final chapters = <String?>[];
      final snaps = <String>[];
      await tester.pumpWidget(
        host(
          NativeVideoPlayerProgressBar(
            duration: const Duration(seconds: 60),
            chapters: _chapters,
            onSeek: _ignoreSeek,
            hapticFeedback: false,
            // Drawn elsewhere by the app: no bubble, callbacks still fire.
            showPreview: false,
            onPreviewChanged: previews.add,
            onScrubChapterChanged: (c) => chapters.add(c?.title),
            onSnap: (c) => snaps.add(c.title),
          ),
        ),
      );
      final gesture = await tester.startGesture(at(tester, 100));
      await gesture.moveTo(at(tester, 150));
      await tester.pump();
      await gesture.moveTo(at(tester, 205));
      await tester.pump();
      expect(find.text('Part two'), findsNothing, reason: 'no bubble');
      expect(previews.last?.chapter, _partTwo);
      expect(previews.last?.snapped, isTrue);
      expect(previews.last?.position, const Duration(seconds: 30));
      await gesture.up();
      await tester.pump();
      await tester.pump();
      expect(previews.last, isNull, reason: 'gone after release');
      expect(chapters, ['Intro', 'Part two', null]);
      expect(snaps, ['Part two']);
    });

    testWidgets('the default height fits the bar, an explicit one wins', (
      tester,
    ) async {
      Future<double> heightWith(NativeVideoPlayerProgressBarStyle style) async {
        await tester.pumpWidget(
          host(
            NativeVideoPlayerProgressBar(
              duration: const Duration(seconds: 60),
              onSeek: _ignoreSeek,
              style: style,
            ),
          ),
        );
        return tester.getSize(find.byType(NativeVideoPlayerProgressBar)).height;
      }

      // The grown thumb (2 x 8) plus 4 px above and below.
      expect(await heightWith(const NativeVideoPlayerProgressBarStyle()), 24);
      expect(
        await heightWith(
          const NativeVideoPlayerProgressBarStyle(
            barHeight: 2,
            expandedBarHeight: 7,
            thumbRadius: 0,
            expandedThumbRadius: 10,
          ),
        ),
        28,
      );
      expect(
        await heightWith(const NativeVideoPlayerProgressBarStyle(height: 20)),
        20,
      );
    });

    testWidgets('showPreview: false shows no bubble', (tester) async {
      await tester.pumpWidget(
        host(
          const NativeVideoPlayerProgressBar(
            duration: Duration(seconds: 60),
            chapters: _chapters,
            showPreview: false,
            onSeek: _ignoreSeek,
          ),
        ),
      );
      final gesture = await tester.startGesture(at(tester, 100));
      await gesture.moveTo(at(tester, 150));
      await gesture.moveTo(at(tester, 205));
      await tester.pump();
      expect(find.text('Part two'), findsNothing);
      expect(find.text('0:30'), findsNothing);
      await gesture.up();
      await tester.pump();
    });

    testWidgets('preview parts can be switched off; a custom builder', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          NativeVideoPlayerProgressBar(
            duration: const Duration(seconds: 60),
            chapters: _chapters,
            onSeek: _ignoreSeek,
            previewStyle: const NativeVideoPlayerScrubPreviewStyle(
              showChapterTitle: false,
              backgroundColor: Colors.black,
              padding: EdgeInsets.all(8),
              arrowSize: Size(8, 6),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(at(tester, 100));
      await gesture.moveTo(at(tester, 150));
      await gesture.moveTo(at(tester, 205));
      await tester.pump();
      expect(find.text('Part two'), findsNothing);
      expect(find.text('0:30'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        host(
          NativeVideoPlayerProgressBar(
            duration: const Duration(seconds: 60),
            chapters: _chapters,
            onSeek: _ignoreSeek,
            previewBuilder: (context, details) =>
                Text('custom ${details.chapter?.title} ${details.snapped}'),
          ),
        ),
      );
      final second = await tester.startGesture(at(tester, 100));
      await second.moveTo(at(tester, 150));
      await second.moveTo(at(tester, 205));
      await tester.pump();
      expect(find.text('custom Part two true'), findsOneWidget);
      await second.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a storyboard image that fails to load does not throw', (
      tester,
    ) async {
      final storyboard = StoryboardThumbnails.fromUniformGrid(
        spriteUrls: const ['assets/does-not-exist.jpg'],
        frameInterval: const Duration(seconds: 10),
        columns: 10,
        frameWidth: 160,
        frameHeight: 90,
        framesPerSprite: 60,
      );
      await tester.pumpWidget(
        host(
          NativeVideoPlayerProgressBar(
            duration: const Duration(seconds: 60),
            chapters: _chapters,
            storyboard: storyboard,
            storyboardHeaders: const {'Referer': 'https://example.com'},
            onSeek: _ignoreSeek,
          ),
        ),
      );
      final gesture = await tester.startGesture(at(tester, 100));
      await gesture.moveTo(at(tester, 150));
      await gesture.moveTo(at(tester, 205));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The frame is left out; title and time still show.
      expect(find.text('Part two'), findsOneWidget);
      expect(find.text('0:30'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a portrait frame keeps its shape, bounded in the bubble', (
      tester,
    ) async {
      // A full Bunny sheet of a 9:16 video (72 s = 36 frames): 6 x 6
      // frames of 300 x 533.
      final sheet = (await tester.runAsync(
        () => createTestImage(width: 1800, height: 3198),
      ))!;
      addTearDown(sheet.dispose);
      final storyboard = StoryboardThumbnails.bunnyFromPlaylistUrl(
        'https://vz-abc.b-cdn.net/guid/playlist.m3u8',
        duration: const Duration(seconds: 72),
      )!;
      await tester.pumpWidget(
        host(
          NativeVideoPlayerProgressBar(
            duration: const Duration(seconds: 72),
            storyboard: storyboard,
            storyboardPrecacheLimit: 0,
            storyboardImageProvider: (url, headers) => _ReadyImage(url, sheet),
            onSeek: _ignoreSeek,
          ),
        ),
      );
      final gesture = await tester.startGesture(at(tester, 100));
      await gesture.moveTo(at(tester, 150));
      await gesture.moveTo(at(tester, 180));
      await tester.pumpAndSettle();
      final frame = find.descendant(
        of: find.byType(NativeVideoPlayerScrubPreview),
        matching: find.byType(CustomPaint),
      );
      final size = tester.getSize(frame.first);
      expect(size.height, 160, reason: 'long side = thumbnailWidth');
      expect(size.width, closeTo(160 * 300 / 533, 0.01));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    group('no stale preview', () {
      Finder previewTime(String text) => find.descendant(
        of: find.byType(NativeVideoPlayerScrubPreview),
        matching: find.text(text),
      );

      testWidgets('a hover that is not a mouse never pins a preview', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(
            const NativeVideoPlayerProgressBar(
              duration: Duration(seconds: 60),
              onSeek: _ignoreSeek,
            ),
          ),
        );
        // Some Android touch screens report a hover at each touch-down and
        // never an exit.
        final hover = await tester.createGesture(
          kind: PointerDeviceKind.stylus,
        );
        await hover.addPointer(location: at(tester, 100));
        await hover.moveTo(at(tester, 100));
        await tester.pump();
        final drag = await tester.startGesture(at(tester, 100));
        await drag.moveTo(at(tester, 200));
        await drag.moveTo(at(tester, 300));
        await drag.up();
        await tester.pumpAndSettle();
        expect(find.byType(NativeVideoPlayerScrubPreview), findsNothing);
        await hover.removePointer();
      });

      testWidgets('a mouse hover shows a preview until it leaves', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(
            const NativeVideoPlayerProgressBar(
              duration: Duration(seconds: 60),
              onSeek: _ignoreSeek,
            ),
          ),
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(at(tester, 200));
        await tester.pumpAndSettle();
        expect(previewTime('0:30'), findsOneWidget);
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(find.byType(NativeVideoPlayerScrubPreview), findsNothing);
        await mouse.removePointer();
      });

      testWidgets('a cancelled pointer leaves no preview', (tester) async {
        final seeks = <Duration>[];
        await tester.pumpWidget(
          host(
            NativeVideoPlayerProgressBar(
              duration: const Duration(seconds: 60),
              onSeek: seeks.add,
            ),
          ),
        );
        final drag = await tester.startGesture(at(tester, 100));
        await drag.moveTo(at(tester, 200));
        await drag.moveTo(at(tester, 300));
        await tester.pump();
        expect(previewTime('0:45'), findsOneWidget);
        await drag.cancel();
        await tester.pumpAndSettle();
        expect(find.byType(NativeVideoPlayerScrubPreview), findsNothing);
      });

      testWidgets('a long-press that wins the gesture leaves no preview', (
        tester,
      ) async {
        var longPressed = false;
        await tester.pumpWidget(
          host(
            GestureDetector(
              onLongPress: () => longPressed = true,
              child: const NativeVideoPlayerProgressBar(
                duration: Duration(seconds: 60),
                onSeek: _ignoreSeek,
              ),
            ),
          ),
        );
        final press = await tester.startGesture(at(tester, 100));
        await tester.pump(const Duration(seconds: 1));
        expect(longPressed, isTrue);
        await press.up();
        await tester.pumpAndSettle();
        expect(find.byType(NativeVideoPlayerScrubPreview), findsNothing);
      });

      testWidgets('moved to another parent mid-drag: no preview after', (
        tester,
      ) async {
        final key = GlobalKey();
        final inCard = ValueNotifier(true);
        addTearDown(inCard.dispose);
        final bar = NativeVideoPlayerProgressBar(
          key: key,
          duration: const Duration(seconds: 60),
          onSeek: _ignoreSeek,
        );
        await tester.pumpWidget(
          host(
            ValueListenableBuilder<bool>(
              valueListenable: inCard,
              builder: (context, card, _) => card
                  ? Padding(padding: EdgeInsets.zero, child: bar)
                  : Center(child: SizedBox(width: 400, child: bar)),
            ),
          ),
        );
        final drag = await tester.startGesture(at(tester, 100));
        await drag.moveTo(at(tester, 200));
        await drag.moveTo(at(tester, 300));
        await tester.pump();
        expect(find.byType(NativeVideoPlayerScrubPreview), findsOneWidget);
        // The overlay rebuilds the controls under another parent.
        inCard.value = false;
        await tester.pump();
        expect(find.byType(NativeVideoPlayerScrubPreview), findsNothing);
        await drag.up();
        await tester.pumpAndSettle();
        expect(find.byType(NativeVideoPlayerScrubPreview), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a full drag shows the preview from start to end and back', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(
            const NativeVideoPlayerProgressBar(
              duration: Duration(seconds: 60),
              onSeek: _ignoreSeek,
            ),
          ),
        );
        final bar = tester.getRect(find.byType(NativeVideoPlayerProgressBar));
        final drag = await tester.startGesture(
          Offset(bar.left + 1, bar.center.dy),
        );
        await drag.moveTo(Offset(bar.left + 60, bar.center.dy));
        await drag.moveTo(Offset(bar.right + 30, bar.center.dy));
        await tester.pump();
        expect(previewTime('1:00'), findsOneWidget, reason: 'the very end');
        await drag.moveTo(Offset(bar.left - 30, bar.center.dy));
        await tester.pump();
        expect(previewTime('0:00'), findsOneWidget, reason: 'the very start');
        await drag.up();
        await tester.pumpAndSettle();
      });
    });

    group('after the release', () {
      // The slider's value: the time where the thumb is.
      String? shownTime(WidgetTester tester) => tester
          .widget<Semantics>(
            find.descendant(
              of: find.byType(NativeVideoPlayerProgressBar),
              matching: find.byWidgetPredicate(
                (w) => w is Semantics && (w.properties.slider ?? false),
              ),
            ),
          )
          .properties
          .value;

      testWidgets('the thumb waits at the target, then follows the player', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(
            const NativeVideoPlayerProgressBar(
              position: Duration.zero,
              duration: Duration(seconds: 60),
              onSeek: _ignoreSeek,
            ),
          ),
        );
        final drag = await tester.startGesture(at(tester, 100));
        await drag.moveTo(at(tester, 150));
        await drag.moveTo(at(tester, 200));
        await drag.up();
        await tester.pump();
        expect(shownTime(tester), '0:30');
        await tester.pump(const Duration(milliseconds: 1500));
        expect(shownTime(tester), '0:30', reason: 'no jump back yet');
        // The player never got there: back to where it plays after 2 s.
        await tester.pump(const Duration(seconds: 1));
        expect(shownTime(tester), '0:00');
      });

      testWidgets('an unplayed video showing its resume position first '
          'does not move the thumb off the target', (tester) async {
        final position = ValueNotifier(Duration.zero);
        addTearDown(position.dispose);
        await tester.pumpWidget(
          host(
            ValueListenableBuilder<Duration>(
              valueListenable: position,
              builder: (context, p, _) => NativeVideoPlayerProgressBar(
                position: p,
                duration: const Duration(seconds: 163),
                onSeek: _ignoreSeek,
              ),
            ),
          ),
        );
        // Release at the very start of a video that never played.
        final drag = await tester.startGesture(at(tester, 100));
        await drag.moveTo(at(tester, 60));
        await drag.moveTo(at(tester, 0));
        await drag.up();
        await tester.pump();
        expect(shownTime(tester), '0:00');
        // It loads at its resume position (0:57) before the seek lands...
        await tester.pump(const Duration(milliseconds: 600));
        position.value = const Duration(seconds: 57);
        await tester.pump();
        expect(shownTime(tester), '0:00', reason: 'not the resume position');
        await tester.pump(const Duration(milliseconds: 800));
        expect(shownTime(tester), '0:00');
        // ...then lands at the target, and the thumb follows the player.
        position.value = const Duration(milliseconds: 200);
        await tester.pump();
        position.value = const Duration(seconds: 1);
        await tester.pump();
        expect(shownTime(tester), '0:01');
      });
    });

    group('the preview never sticks out', () {
      Widget hostAt(Widget bar, {required double top, double width = 400}) =>
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.only(top: top),
                child: SizedBox(width: width, child: bar),
              ),
            ),
          );

      Future<ui.Image> sheet(WidgetTester tester) async {
        final image = (await tester.runAsync(
          () => createTestImage(width: 1600, height: 540),
        ))!;
        addTearDown(image.dispose);
        return image;
      }

      StoryboardThumbnails board() => StoryboardThumbnails.fromUniformGrid(
        spriteUrls: const ['https://cdn.example.com/s.jpg'],
        frameInterval: const Duration(seconds: 10),
        columns: 10,
        frameWidth: 160,
        frameHeight: 90,
        framesPerSprite: 60,
      );

      Future<TestGesture> drag(WidgetTester tester, double x) async {
        final gesture = await tester.startGesture(at(tester, x - 50));
        await gesture.moveTo(at(tester, x - 20));
        await gesture.moveTo(at(tester, x));
        await tester.pumpAndSettle();
        return gesture;
      }

      testWidgets('scaled down to the room above the bar', (tester) async {
        final image = await sheet(tester);
        await tester.pumpWidget(
          hostAt(
            NativeVideoPlayerProgressBar(
              duration: const Duration(seconds: 60),
              chapters: _chapters,
              storyboard: board(),
              storyboardPrecacheLimit: 0,
              storyboardImageProvider: (url, _) => _ReadyImage(url, image),
              onSeek: _ignoreSeek,
            ),
            top: 70, // a small inline player: 70 px above the bar
          ),
        );
        final gesture = await drag(tester, 120);
        final bar = tester.getRect(find.byType(NativeVideoPlayerProgressBar));
        final bubble = tester.getRect(
          find.byType(NativeVideoPlayerScrubPreview),
        );
        expect(bubble.top, greaterThanOrEqualTo(0), reason: 'stays on screen');
        expect(bubble.bottom, lessThan(bar.top + 12));
        expect(bubble.height, lessThan(90), reason: 'frame + text scaled');
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });

      testWidgets('left out when there is no room', (tester) async {
        await tester.pumpWidget(
          hostAt(
            const NativeVideoPlayerProgressBar(
              duration: Duration(seconds: 60),
              chapters: _chapters,
              onSeek: _ignoreSeek,
            ),
            top: 0,
          ),
        );
        final gesture = await drag(tester, 205);
        expect(find.byType(NativeVideoPlayerScrubPreview), findsNothing);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });

      testWidgets('no wider than the bar, previewMaxHeight caps it', (
        tester,
      ) async {
        final image = await sheet(tester);
        await tester.pumpWidget(
          hostAt(
            NativeVideoPlayerProgressBar(
              duration: const Duration(seconds: 60),
              storyboard: board(),
              storyboardPrecacheLimit: 0,
              storyboardImageProvider: (url, _) => _ReadyImage(url, image),
              previewMaxHeight: 60,
              onSeek: _ignoreSeek,
            ),
            top: 300,
            width: 100, // narrower than the 160 px frame
          ),
        );
        final gesture = await drag(tester, 60);
        final bar = tester.getRect(find.byType(NativeVideoPlayerProgressBar));
        final bubble = tester.getRect(
          find.byType(NativeVideoPlayerScrubPreview),
        );
        expect(bubble.left, greaterThanOrEqualTo(bar.left - 0.01));
        expect(bubble.right, lessThanOrEqualTo(bar.right + 0.01));
        expect(bubble.height, lessThanOrEqualTo(60.01));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('sheets are loaded before playback and kept for the scrub', (
      tester,
    ) async {
      final sheet = (await tester.runAsync(
        () => createTestImage(width: 1600, height: 540),
      ))!;
      addTearDown(sheet.dispose);
      _ReadyImage.loads = 0;
      final storyboard = StoryboardThumbnails.fromUniformGrid(
        // A URL no other test loaded, so it isn't in the image cache yet.
        spriteUrls: const ['https://cdn.example.com/warm.jpg'],
        frameInterval: const Duration(seconds: 10),
        columns: 10,
        frameWidth: 160,
        frameHeight: 90,
        framesPerSprite: 60,
      );
      await tester.pumpWidget(
        host(
          NativeVideoPlayerProgressBar(
            // Not played yet: position zero, duration from the API.
            position: Duration.zero,
            duration: const Duration(seconds: 60),
            storyboard: storyboard,
            // Loads asynchronously, like a NetworkImage.
            storyboardImageProvider: (url, _) =>
                _ReadyImage(url, sheet, async: true),
            onSeek: _ignoreSeek,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(_ReadyImage.loads, 1, reason: 'loaded before any scrub');
      // A busy app's other images may flush the cache; the bar's sheet
      // stays live and is not loaded again.
      PaintingBinding.instance.imageCache.clear();
      final gesture = await tester.startGesture(at(tester, 100));
      await gesture.moveTo(at(tester, 130));
      await gesture.moveTo(at(tester, 150));
      await tester.pump();
      expect(_ReadyImage.loads, 1);
      expect(
        find.descendant(
          of: find.byType(NativeVideoPlayerScrubPreview),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
        reason: 'the frame shows on the first scrub frame',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('while a sheet loads the bubble shows the time alone', (
      tester,
    ) async {
      final storyboard = StoryboardThumbnails.fromUniformGrid(
        spriteUrls: const ['https://cdn.example.com/slow.jpg'],
        frameInterval: const Duration(seconds: 10),
        columns: 10,
        frameWidth: 160,
        frameHeight: 90,
        framesPerSprite: 60,
      );
      await tester.pumpWidget(
        host(
          NativeVideoPlayerProgressBar(
            duration: const Duration(seconds: 60),
            storyboard: storyboard,
            storyboardImageProvider: (url, _) => _PendingImage(url),
            onSeek: _ignoreSeek,
          ),
        ),
      );
      final gesture = await tester.startGesture(at(tester, 100));
      await gesture.moveTo(at(tester, 130));
      await gesture.moveTo(at(tester, 150));
      await tester.pump();
      final preview = find.byType(NativeVideoPlayerScrubPreview);
      expect(
        find.descendant(of: preview, matching: find.byType(CustomPaint)),
        findsNothing,
        reason: 'no empty frame',
      );
      expect(
        find.descendant(of: preview, matching: find.textContaining(':')),
        findsOneWidget,
        reason: 'the time',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a storyboard image that failed is fetched again later', (
      tester,
    ) async {
      _FailingImage.loads = 0;
      final storyboard = StoryboardThumbnails.fromUniformGrid(
        spriteUrls: const ['https://cdn.example.com/seek/_0.jpg'],
        frameInterval: const Duration(seconds: 10),
        columns: 10,
        frameWidth: 160,
        frameHeight: 90,
        framesPerSprite: 60,
      );
      await tester.pumpWidget(
        host(
          NativeVideoPlayerProgressBar(
            duration: const Duration(seconds: 60),
            storyboard: storyboard,
            storyboardPrecacheLimit: 0,
            storyboardImageProvider: (url, headers) => _FailingImage(url),
            onSeek: _ignoreSeek,
          ),
        ),
      );
      Future<void> scrub() async {
        final gesture = await tester.startGesture(at(tester, 100));
        await gesture.moveTo(at(tester, 150));
        await gesture.moveTo(at(tester, 180));
        await tester.pumpAndSettle();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await scrub();
      expect(_FailingImage.loads, 1);
      expect(tester.takeException(), isNull);
      // A 403 or a dropped connection must not lose the previews for the
      // rest of the video: the next scrub asks again.
      await scrub();
      expect(_FailingImage.loads, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a custom image provider builder receives the headers', (
      tester,
    ) async {
      final requested = <(String, Map<String, String>?)>[];
      final storyboard = StoryboardThumbnails.fromUniformGrid(
        spriteUrls: const ['https://cdn.example.com/seek/_0.jpg'],
        frameInterval: const Duration(seconds: 10),
        columns: 10,
        frameWidth: 160,
        frameHeight: 90,
        framesPerSprite: 60,
      );
      await tester.pumpWidget(
        host(
          NativeVideoPlayerProgressBar(
            duration: const Duration(seconds: 60),
            storyboard: storyboard,
            storyboardHeaders: const {'Referer': 'https://huddle.example'},
            storyboardImageProvider: (url, headers) {
              requested.add((url, headers));
              return const AssetImage('assets/does-not-exist.jpg');
            },
            onSeek: _ignoreSeek,
          ),
        ),
      );
      // Precached around the start before any drag.
      await tester.pumpAndSettle();
      expect(requested, isNotEmpty);
      expect(requested.first.$1, 'https://cdn.example.com/seek/_0.jpg');
      expect(requested.first.$2, {'Referer': 'https://huddle.example'});
      expect(tester.takeException(), isNull);
    });
  });

  group('controller', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const methodChannel = MethodChannel('native_video_player');

    late List<MethodCall> calls;
    late NativeVideoPlayerController controller;
    MockStreamHandlerEventSink? viewSink;
    var seq = 0;
    late int controllerId;
    late int viewId;

    setUp(() {
      seq++;
      controllerId = 8800 + seq;
      viewId = 9800 + seq;
      calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        return call.method == 'getAvailableQualities' ? <Object?>[] : null;
      });
    });

    tearDown(() async {
      await controller.dispose().timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
      messenger.setMockMethodCallHandler(methodChannel, null);
    });

    Future<void> attach(WidgetTester tester, {Widget? child}) async {
      messenger.setMockStreamHandler(
        EventChannel('native_video_player_controller_$controllerId'),
        MockStreamHandler.inline(onListen: (arguments, events) {}),
      );
      messenger.setMockStreamHandler(
        EventChannel('native_video_player_$viewId'),
        MockStreamHandler.inline(
          onListen: (_, events) {
            viewSink = events;
          },
        ),
      );
      controller = NativeVideoPlayerController(id: controllerId);
      await tester.pumpWidget(child ?? const SizedBox());
      final context = tester.element(find.byType(Directionality).first);
      await controller.onPlatformViewCreated(viewId, context);
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> sendPosition(
      WidgetTester tester,
      int ms, {
      bool isLive = false,
    }) async {
      viewSink!.success({
        'event': 'timeUpdate',
        'position': ms,
        'duration': 60000,
        'bufferedPosition': ms,
        'isBuffering': false,
        'isLive': isLive,
      });
      await tester.pump();
    }

    List<int> seeks() => [
      for (final c in calls.where((c) => c.method == 'seekTo'))
        (c.arguments as Map)['milliseconds'] as int,
    ];

    testWidgets('tracks the current chapter and emits on crossings', (
      tester,
    ) async {
      await attach(
        tester,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(),
        ),
      );
      final emitted = <String?>[];
      final sub = controller.currentChapterStream.listen(
        (c) => emitted.add(c?.title),
      );

      controller.setChapters(const [_outro, _intro, _partTwo]);
      expect(controller.chapters, _chapters, reason: 'sorted');
      expect(controller.currentChapter, _intro);

      await sendPosition(tester, 10000);
      await sendPosition(tester, 31000);
      await sendPosition(tester, 32000);
      await sendPosition(tester, 50000);
      expect(controller.currentChapter, _outro);
      expect(emitted, ['Intro', 'Part two', 'Outro']);

      controller.setChapters(const []);
      expect(controller.currentChapter, isNull);
      await tester.pump();
      expect(emitted.last, isNull);
      // Not awaited: the cancel future never completes in the fake-async
      // zone, which would hang the test.
      unawaited(sub.cancel());
    });

    testWidgets('chapter changes reach control listeners', (tester) async {
      await attach(
        tester,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(),
        ),
      );
      final events = <PlayerControlEvent>[];
      controller.addControlListener((e) {
        if (e.state == PlayerControlState.chapterChanged ||
            e.state == PlayerControlState.chaptersChanged) {
          events.add(e);
        }
      });
      controller.setChapters(_chapters);
      await sendPosition(tester, 31000);
      await sendPosition(tester, 32000); // same chapter: no event
      expect(events.map((e) => e.state), [
        PlayerControlState.chaptersChanged,
        PlayerControlState.chapterChanged,
        PlayerControlState.chapterChanged,
      ]);
      expect(events.map((e) => e.data).toList(), [
        {'count': 3},
        {'index': 0, 'title': 'Intro', 'startMs': 0},
        {'index': 1, 'title': 'Part two', 'startMs': 30000},
      ]);
      expect(controller.currentChapterIndex, 1);
    });

    testWidgets('next / previous chapter', (tester) async {
      await attach(
        tester,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(),
        ),
      );
      controller.setChapters(_chapters);

      // The native player confirms each seek before reporting positions far
      // from its target (the controller drops stale ones until then).
      Future<void> seekDone(int ms) async {
        viewSink!.success({'event': 'seek', 'position': ms});
        await tester.pump();
      }

      await sendPosition(tester, 10000);
      await controller.seekToNextChapter();
      // Reported a hair before the start after the seek: still "next" is 45s.
      await sendPosition(tester, 29900);
      await controller.seekToNextChapter();
      await seekDone(45000);
      await sendPosition(tester, 50000);
      await controller.seekToNextChapter(); // last chapter: nothing
      expect(seeks(), [30000, 45000]);

      // 5 s into Outro: back to its start; within 3 s: to the previous one.
      await controller.seekToPreviousChapter();
      await sendPosition(tester, 46000);
      await controller.seekToPreviousChapter();
      await seekDone(30000);
      await sendPosition(tester, 1000);
      await controller.seekToPreviousChapter();
      expect(seeks(), [30000, 45000, 45000, 30000, 0]);
    });

    testWidgets('load(chapters:) sets them; a different URL clears them', (
      tester,
    ) async {
      await attach(
        tester,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(),
        ),
      );
      // Set before the first load: kept.
      controller.setChapters(_chapters);
      await controller.load(url: 'https://example.com/a.m3u8');
      expect(controller.chapters, _chapters);

      // Same URL again (eviction re-load path): kept.
      await controller.load(url: 'https://example.com/a.m3u8', force: true);
      expect(controller.chapters, _chapters);

      await controller.load(url: 'https://example.com/b.m3u8', force: true);
      expect(controller.chapters, isEmpty);

      await controller.load(
        url: 'https://example.com/c.m3u8',
        chapters: const [_partTwo],
        force: true,
      );
      expect(controller.chapters, const [_partTwo]);

      // A guarded (no-op) load still applies the chapters passed.
      await controller.load(
        url: 'https://example.com/c.m3u8',
        chapters: _chapters,
      );
      expect(controller.chapters, _chapters);
    });

    testWidgets('chapters are hidden while live', (tester) async {
      await attach(
        tester,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(),
        ),
      );
      controller.setChapters(_chapters);
      await sendPosition(tester, 31000);
      expect(controller.currentChapter, _partTwo);

      await sendPosition(tester, 32000, isLive: true);
      expect(controller.chapters, isEmpty);
      expect(controller.currentChapter, isNull);
      await controller.seekToNextChapter();
      expect(seeks(), isEmpty);
    });

    group('NativeVideoPlayerProgressBar', () {
      late List<String> haptics;

      Widget app() => MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 300),
            child: SizedBox(
              width: 400,
              child: Builder(
                builder: (context) =>
                    NativeVideoPlayerProgressBar(controller: controller),
              ),
            ),
          ),
        ),
      );

      Future<void> pumpBar(WidgetTester tester) async {
        haptics = [];
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        // The widget tree goes in before the controller attaches, so the
        // bar is built with this test's controller.
        messenger.setMockStreamHandler(
          EventChannel('native_video_player_controller_$controllerId'),
          MockStreamHandler.inline(onListen: (arguments, events) {}),
        );
        messenger.setMockStreamHandler(
          EventChannel('native_video_player_$viewId'),
          MockStreamHandler.inline(
            onListen: (_, events) {
              viewSink = events;
            },
          ),
        );
        controller = NativeVideoPlayerController(id: controllerId);
        await tester.pumpWidget(app());
        final context = tester.element(find.byType(SizedBox).first);
        await controller.onPlatformViewCreated(viewId, context);
        await tester.pump(const Duration(milliseconds: 100));
        controller.setChapters(_chapters);
        await sendPosition(tester, 0);
      }

      Offset at(WidgetTester tester, double x) =>
          tester.getTopLeft(find.byType(NativeVideoPlayerProgressBar)) +
          Offset(x, 16);

      testWidgets('drag near a chapter start snaps, ticks and seeks there', (
        tester,
      ) async {
        await pumpBar(tester);
        // 400 px for 60 s: 30 s (Part two) is at x = 200; 8 px = 1.2 s.
        final gesture = await tester.startGesture(at(tester, 100));
        await gesture.moveTo(at(tester, 150));
        await tester.pump();
        expect(find.text('Intro'), findsOneWidget, reason: 'preview title');
        expect(haptics, isEmpty);

        await gesture.moveTo(at(tester, 205)); // 30.75 s, within 8 px
        await tester.pump();
        expect(find.text('Part two'), findsOneWidget);
        expect(find.text('0:30'), findsOneWidget);
        expect(haptics, ['HapticFeedbackType.selectionClick']);

        await gesture.moveTo(at(tester, 203)); // still snapped: no new tick
        await tester.pump();
        expect(haptics, hasLength(1));

        await gesture.up();
        await tester.pump();
        expect(seeks(), [30000]);
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text('Part two'), findsNothing, reason: 'preview hides');
      });

      testWidgets('a drag away from chapter starts seeks to the finger', (
        tester,
      ) async {
        await pumpBar(tester);
        final gesture = await tester.startGesture(at(tester, 100));
        await gesture.moveTo(at(tester, 220)); // 33 s, 20 px from 30 s
        await tester.pump();
        await gesture.up();
        await tester.pump();
        // The track is inset 8 px at both ends: 400 px box, 384 px track,
        // so x = 220 is (220 - 8) / 384 of 60 s.
        expect(seeks(), [33125]);
        expect(haptics, isEmpty);
      });

      testWidgets('keeps the overlay up while scrubbing, then lets go', (
        tester,
      ) async {
        await pumpBar(tester);
        final locks = <bool>[];
        final sub = controller.isOverlayLockedStream.listen(locks.add);
        final gesture = await tester.startGesture(at(tester, 100));
        await gesture.moveTo(at(tester, 150));
        await tester.pump();
        expect(controller.isOverlayLocked, isTrue);
        await gesture.up();
        await tester.pump();
        expect(controller.isOverlayLocked, isFalse);
        expect(locks, [true, false]);

        // The app's own lock survives a scrub.
        controller.lockOverlay();
        final again = await tester.startGesture(at(tester, 100));
        await again.moveTo(at(tester, 150));
        await again.up();
        await tester.pump();
        expect(controller.isOverlayLocked, isTrue);
        controller.unlockOverlay();
        expect(controller.isOverlayLocked, isFalse);
        unawaited(sub.cancel());
        await tester.pump(const Duration(seconds: 2));
      });

      testWidgets('while the player loads the thumb keeps the target', (
        tester,
      ) async {
        await pumpBar(tester);
        // A video that wasn't loaded: the release makes it load.
        viewSink!.success({'event': 'loading'});
        await tester.pump();
        expect(controller.activityState, PlayerActivityState.loading);
        String? shown() => tester
            .widget<Semantics>(
              find.descendant(
                of: find.byType(NativeVideoPlayerProgressBar),
                matching: find.byWidgetPredicate(
                  (w) => w is Semantics && (w.properties.slider ?? false),
                ),
              ),
            )
            .properties
            .value;
        final gesture = await tester.startGesture(at(tester, 100));
        await gesture.moveTo(at(tester, 150));
        await gesture.moveTo(at(tester, 220)); // 33 s
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(seconds: 4));
        expect(shown(), '0:33', reason: 'no jump back while loading');
        // Loaded, at the target: the thumb follows the player again.
        viewSink!.success({'event': 'loaded', 'duration': 60000});
        await tester.pump();
        await sendPosition(tester, 33500);
        await sendPosition(tester, 34000);
        expect(shown(), '0:34');
        // Playing: disarms the controller's load watchdog.
        viewSink!.success({'event': 'play'});
        await tester.pump();
      });

      testWidgets('the thumb at either end is whole inside the touch area', (
        tester,
      ) async {
        await pumpBar(tester);
        final box = tester.getRect(find.byType(NativeVideoPlayerProgressBar));
        // A finger on the left half of the thumb at 0:00 (inside the box's
        // inset, left of the track) starts a drag at the very start...
        await tester.tapAt(Offset(box.left + 2, box.center.dy));
        await tester.pump();
        // ...and on the right half of the thumb at the end, at the end.
        await tester.tapAt(Offset(box.right - 2, box.center.dy));
        await tester.pump();
        expect(seeks(), [0, 60000]);
      });

      testWidgets('tap seeks', (tester) async {
        await pumpBar(tester);
        await tester.tapAt(at(tester, 100));
        await tester.pump();
        expect(seeks(), [14375]); // (100 - 8) / 384 of 60 s
      });

      testWidgets('no snapping for live', (tester) async {
        await pumpBar(tester);
        await sendPosition(tester, 0, isLive: true);
        final gesture = await tester.startGesture(at(tester, 100));
        await gesture.moveTo(at(tester, 205));
        await tester.pump();
        await gesture.up();
        await tester.pump();
        expect(seeks(), [30781]); // (205 - 8) / 384 of 60 s
        expect(haptics, isEmpty);
      });
    });
  });
}

void _ignoreSeek(Duration _) {}

/// An image that always fails to load, counting the attempts.
class _FailingImage extends ImageProvider<_FailingImage> {
  const _FailingImage(this.url);

  final String url;
  static int loads = 0;

  @override
  Future<_FailingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _FailingImage key,
    ImageDecoderCallback decode,
  ) {
    loads++;
    return OneFrameImageStreamCompleter(
      Future<ImageInfo>.error(StateError('403 for $url')),
    );
  }

  @override
  bool operator ==(Object other) => other is _FailingImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// An image that is already decoded, for frame layout tests.
class _ReadyImage extends ImageProvider<_ReadyImage> {
  const _ReadyImage(this.url, this.image, {this.async = false});

  final String url;
  final ui.Image image;
  final bool async;
  static int loads = 0;

  @override
  Future<_ReadyImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_ReadyImage key, ImageDecoderCallback decode) {
    loads++;
    final info = ImageInfo(image: image.clone());
    return OneFrameImageStreamCompleter(
      async ? Future.value(info) : SynchronousFuture(info),
    );
  }

  @override
  bool operator ==(Object other) => other is _ReadyImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// An image that never finishes loading.
class _PendingImage extends ImageProvider<_PendingImage> {
  const _PendingImage(this.url);

  final String url;

  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _PendingImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Completer<ImageInfo>().future);

  @override
  bool operator ==(Object other) => other is _PendingImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

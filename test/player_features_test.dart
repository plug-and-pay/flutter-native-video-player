import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Player feature wave: startAt, A-B playback range, playlist auto-advance,
/// position checkpoints, playback analytics, storyboard thumbnails — all
/// against a mocked platform side, events injected through the per-view
/// EventChannel like the native side would send them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');

  late List<MethodCall> calls;
  late NativeVideoPlayerController controller;
  MockStreamHandlerEventSink? viewSink;

  // Fresh controller/view ids per test: each id pair means fresh
  // EventChannel NAMES, so a previous test's late async channel teardown
  // can never clear the handler the current test just registered (the
  // same re-subscription race exists on-device, which is why the stress
  // harness also uses fresh ids per visit).
  var testSeq = 0;
  late int controllerId;
  late int viewId;

  setUp(() {
    testSeq++;
    controllerId = 7700 + testSeq;
    viewId = 9100 + testSeq;
    calls = <MethodCall>[];
    viewSink = null;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getAvailableQualities':
          return <Object?>[];
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    // A controller constructed in the fake-async zone can hold futures that
    // never complete once that zone is gone, so a plain await could hang
    // forever — the timeout caps the cost. Unique per-test channel names
    // make any leftover state harmless.
    await controller.dispose().timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  // Everything zone-sensitive happens INSIDE the test body, not setUp:
  // setUp runs outside testWidgets' fake-async zone, and flutter_test pins
  // mock stream handlers to the zone that registered them — handlers (and
  // controllers) created in setUp deliver their injected events on the
  // real event loop, where the fake-async test never observes them.
  Future<void> attachView(WidgetTester tester) async {
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_controller_$controllerId'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_$viewId'),
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          viewSink = events;
        },
      ),
    );
    controller = NativeVideoPlayerController(id: controllerId);
    await tester.pumpWidget(const SizedBox());
    final BuildContext context = tester.element(find.byType(SizedBox));
    await controller.onPlatformViewCreated(viewId, context);
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> sendEvent(
    WidgetTester tester,
    Map<String, dynamic> event,
  ) async {
    viewSink!.success(event);
    await tester.pump();
  }

  Future<void> sendPosition(WidgetTester tester, int positionMs) =>
      sendEvent(tester, {
        'event': 'timeUpdate',
        'position': positionMs,
        'duration': 60000,
        'bufferedPosition': positionMs,
        'isBuffering': false,
      });

  group('load startAt', () {
    testWidgets('passes startAtMs to the platform', (tester) async {
      await attachView(tester);
      await controller.load(
        url: 'https://example.com/v.mp4',
        startAt: const Duration(seconds: 42),
      );

      final call = calls.lastWhere((c) => c.method == 'load');
      expect((call.arguments as Map)['startAtMs'], 42000);
    });

    testWidgets('omits startAtMs when not requested', (tester) async {
      await attachView(tester);
      await controller.load(url: 'https://example.com/v.mp4');

      final call = calls.lastWhere((c) => c.method == 'load');
      expect((call.arguments as Map).containsKey('startAtMs'), isFalse);
    });

    testWidgets('force loads over an already-loaded video', (tester) async {
      await attachView(tester);
      await controller.load(url: 'https://example.com/a.mp4');
      // State 'loaded' blocks a plain load...
      await controller.load(url: 'https://example.com/b.mp4');
      expect(
        calls.where((c) => c.method == 'load').length,
        1,
        reason: 'guard must keep swallowing duplicate loads by default',
      );
      // ...but force replaces the video.
      await controller.load(url: 'https://example.com/b.mp4', force: true);
      final urls = calls
          .where((c) => c.method == 'load')
          .map((c) => (c.arguments as Map)['url'])
          .toList();
      expect(urls, ['https://example.com/a.mp4', 'https://example.com/b.mp4']);
    });
  });

  group('A-B playback range', () {
    testWidgets('loops back to start when reaching end', (tester) async {
      await attachView(tester);
      await controller.setPlaybackRange(
        start: const Duration(seconds: 10),
        end: const Duration(seconds: 20),
      );
      // Outside the range at set time -> immediate seek to start.
      var seeks = calls.where((c) => c.method == 'seekTo').toList();
      expect((seeks.last.arguments as Map)['milliseconds'], 10000);

      await sendPosition(tester, 15000); // inside: nothing happens
      await sendPosition(tester, 20100); // past end: loop
      seeks = calls.where((c) => c.method == 'seekTo').toList();
      expect(seeks, hasLength(2));
      expect((seeks.last.arguments as Map)['milliseconds'], 10000);
      expect(controller.playbackRange, isNotNull);
    });

    testWidgets('clip range pauses once and releases', (tester) async {
      await attachView(tester);
      await sendPosition(tester, 12000); // already inside -> no initial seek
      await controller.setPlaybackRange(
        start: const Duration(seconds: 10),
        end: const Duration(seconds: 20),
        loop: false,
      );
      expect(calls.where((c) => c.method == 'seekTo'), isEmpty);

      await sendPosition(tester, 20500);
      expect(calls.where((c) => c.method == 'pause'), hasLength(1));
      expect(controller.playbackRange, isNull, reason: 'one-shot releases');
    });

    testWidgets('clearPlaybackRange stops enforcement', (tester) async {
      await attachView(tester);
      await controller.setPlaybackRange(
        start: Duration.zero,
        end: const Duration(seconds: 5),
      );
      controller.clearPlaybackRange();
      await sendPosition(tester, 9000);
      expect(calls.where((c) => c.method == 'seekTo'), isEmpty);
      expect(controller.playbackRange, isNull);
    });

    testWidgets('loading a new video clears the range', (tester) async {
      await attachView(tester);
      await controller.setPlaybackRange(
        start: Duration.zero,
        end: const Duration(seconds: 5),
      );
      await controller.load(url: 'https://example.com/v.mp4');
      expect(controller.playbackRange, isNull);
    });
  });

  group('NativeVideoPlayerPlaylist', () {
    const items = [
      NativeVideoPlayerPlaylistItem(url: 'https://example.com/1.mp4'),
      NativeVideoPlayerPlaylistItem(
        url: 'https://example.com/2.mp4',
        startAt: Duration(seconds: 7),
      ),
      NativeVideoPlayerPlaylistItem(url: 'https://example.com/3.mp4'),
    ];

    testWidgets('start loads and plays the first item', (tester) async {
      await attachView(tester);
      final playlist = NativeVideoPlayerPlaylist(controller, items: items);
      addTearDown(playlist.dispose);

      await playlist.start();
      expect(playlist.currentIndex, 0);
      final load = calls.lastWhere((c) => c.method == 'load');
      expect((load.arguments as Map)['url'], 'https://example.com/1.mp4');
      expect(calls.any((c) => c.method == 'play'), isTrue);
    });

    testWidgets('auto-advances on completed, carrying per-item startAt', (
      tester,
    ) async {
      await attachView(tester);
      final playlist = NativeVideoPlayerPlaylist(controller, items: items);
      addTearDown(playlist.dispose);
      final indices = <int>[];
      playlist.currentIndexStream.listen(indices.add);

      await playlist.start();
      await sendEvent(tester, {'event': 'completed'});
      await tester.pump();

      expect(playlist.currentIndex, 1);
      final load = calls.lastWhere((c) => c.method == 'load');
      expect((load.arguments as Map)['url'], 'https://example.com/2.mp4');
      expect((load.arguments as Map)['startAtMs'], 7000);
      await tester.pump();
      expect(indices, [0, 1]);
    });

    testWidgets('non-looping playlist stops after the last item', (
      tester,
    ) async {
      await attachView(tester);
      final playlist = NativeVideoPlayerPlaylist(controller, items: items);
      addTearDown(playlist.dispose);

      await playlist.playItemAt(2);
      expect(playlist.hasNext, isFalse);
      final loadsBefore = calls.where((c) => c.method == 'load').length;
      await sendEvent(tester, {'event': 'completed'});
      await tester.pump();
      expect(calls.where((c) => c.method == 'load').length, loadsBefore);
    });

    testWidgets('looping playlist wraps to the first item', (tester) async {
      await attachView(tester);
      final playlist = NativeVideoPlayerPlaylist(
        controller,
        items: items,
        loop: true,
      );
      addTearDown(playlist.dispose);

      await playlist.playItemAt(2);
      await sendEvent(tester, {'event': 'completed'});
      await tester.pump();
      expect(playlist.currentIndex, 0);
    });
  });

  group('PositionCheckpoints', () {
    testWidgets('first position emits, then throttles, dispose flushes', (
      tester,
    ) async {
      await attachView(tester);
      final emitted = <Duration>[];
      final checkpoints = PositionCheckpoints(
        controller,
        onCheckpoint: emitted.add,
      );

      await sendPosition(tester, 1000);
      await sendPosition(tester, 2000); // within interval -> swallowed
      await sendPosition(tester, 3000); // within interval -> swallowed
      expect(emitted, [const Duration(seconds: 1)]);
      expect(checkpoints.lastPosition, const Duration(seconds: 3));

      checkpoints.dispose();
      expect(emitted, [const Duration(seconds: 1), const Duration(seconds: 3)]);
    });
  });

  group('PlaybackAnalytics', () {
    testWidgets('emits startup, stall pair and completed', (tester) async {
      await attachView(tester);
      final analytics = PlaybackAnalytics(controller);
      final events = <PlaybackAnalyticsEvent>[];
      analytics.events.listen(events.add);

      await sendEvent(tester, {'event': 'play'});
      await sendEvent(tester, {'event': 'buffering'});
      await sendEvent(tester, {'event': 'play'});
      await sendEvent(tester, {'event': 'completed'});
      await tester.pump();

      expect(events.map((e) => e.type).toList(), [
        PlaybackAnalyticsEventType.startup,
        PlaybackAnalyticsEventType.stallStarted,
        PlaybackAnalyticsEventType.stallEnded,
        PlaybackAnalyticsEventType.completed,
      ]);
      expect(analytics.stallCount, 1);
      // In-body dispose: the heartbeat Timer must die inside the fake zone.
      analytics.dispose();
    });

    testWidgets('pre-playback buffering is not a stall', (tester) async {
      await attachView(tester);
      final analytics = PlaybackAnalytics(controller);
      final events = <PlaybackAnalyticsEvent>[];
      analytics.events.listen(events.add);

      await sendEvent(tester, {'event': 'buffering'});
      await sendEvent(tester, {'event': 'play'});
      await tester.pump();

      expect(events.map((e) => e.type).toList(), [
        PlaybackAnalyticsEventType.startup,
      ]);
      expect(analytics.stallCount, 0);
      // In-body dispose: the heartbeat Timer must die inside the fake zone.
      analytics.dispose();
    });
  });

  group('StoryboardThumbnails', () {
    const vtt = '''
WEBVTT

00:00:00.000 --> 00:00:05.000
sprite1.jpg#xywh=0,0,160,90

00:00:05.000 --> 00:00:10.000
sprite1.jpg#xywh=160,0,160,90

00:00:10.000 --> 00:00:15.000
full10.jpg
''';

    test('parses sprite regions and resolves relative URLs', () {
      final board = StoryboardThumbnails.parseVtt(
        vtt,
        baseUrl: Uri.parse('https://cdn.example.com/sb/board.vtt'),
      );

      expect(board.entries, hasLength(3));
      expect(board.entries[0].url, 'https://cdn.example.com/sb/sprite1.jpg');
      expect(board.entries[0].region, const Rect.fromLTWH(0, 0, 160, 90));
      expect(board.entries[1].region, const Rect.fromLTWH(160, 0, 160, 90));
      expect(board.entries[2].url, 'https://cdn.example.com/sb/full10.jpg');
      expect(board.entries[2].region, isNull);
    });

    test('thumbnailAt picks the covering / nearest earlier entry', () {
      final board = StoryboardThumbnails.parseVtt(vtt);

      expect(board.thumbnailAt(Duration.zero)!.url, 'sprite1.jpg');
      expect(
        board.thumbnailAt(const Duration(seconds: 7))!.region,
        const Rect.fromLTWH(160, 0, 160, 90),
      );
      expect(board.thumbnailAt(const Duration(seconds: 12))!.url, 'full10.jpg');
      // Past the last cue: nearest earlier entry still serves the scrubber.
      expect(board.thumbnailAt(const Duration(minutes: 5))!.url, 'full10.jpg');
    });

    test('malformed xywh fragments degrade to whole-image entries', () {
      final board = StoryboardThumbnails.parseVtt('''
WEBVTT

00:00:00.000 --> 00:00:05.000
img.jpg#xywh=oops,0,160
''');
      expect(board.entries, hasLength(1));
      expect(board.entries.single.region, isNull);
    });
  });

  group('BackgroundPlaybackGuard', () {
    testWidgets('pauses on background and resumes on foreground', (
      tester,
    ) async {
      await attachView(tester);
      final guard = BackgroundPlaybackGuard(controller);
      addTearDown(guard.dispose);

      await sendEvent(tester, {'event': 'play'});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(calls.where((c) => c.method == 'pause'), hasLength(1));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls.where((c) => c.method == 'play'), hasLength(1));
    });

    testWidgets('leaves a paused player alone', (tester) async {
      await attachView(tester);
      final guard = BackgroundPlaybackGuard(controller);
      addTearDown(guard.dispose);

      await sendEvent(tester, {'event': 'play'});
      await sendEvent(tester, {'event': 'pause'});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls.where((c) => c.method == 'pause'), isEmpty);
      expect(calls.where((c) => c.method == 'play'), isEmpty);
    });
  });
}

import 'dart:async';

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

      await sendEvent(tester, {'event': 'seek', 'position': 10000});
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

  group('buffering around a seek', () {
    testWidgets('a paused player that reports loaded after a seek is not '
        'left buffering', (tester) async {
      await attachView(tester);
      await sendEvent(tester, {'event': 'pause'});
      expect(controller.activityState, PlayerActivityState.paused);

      // Android after seekTo on a paused player (from a Gigaset log): the
      // time update already says buffering, then buffering, the seek, and
      // READY ("loaded") 30 ms later. Then nothing: a paused player sends
      // no time updates.
      await sendEvent(tester, {
        'event': 'timeUpdate',
        'position': 0,
        'duration': 163600,
        'bufferedPosition': 0,
        'isBuffering': true,
      });
      await sendEvent(tester, {'event': 'buffering'});
      await sendEvent(tester, {'event': 'seek', 'position': 0});
      await sendEvent(tester, {'event': 'loaded', 'duration': 163600});
      expect(controller.activityState, PlayerActivityState.loaded);

      // The buffering debounce must not flip it back after the fact.
      await tester.pump(const Duration(seconds: 1));
      expect(controller.activityState, PlayerActivityState.loaded);
    });
  });

  group('seek while paused', () {
    // A loaded video the viewer never played, then seeked: both platforms
    // must end paused. Apps map loaded to "not started yet" (Huddle shows
    // the saved resume position then), so a seeked video can't stay loaded.
    Future<void> loadPaused(WidgetTester tester) async {
      await attachView(tester);
      await sendEvent(tester, {'event': 'loaded', 'duration': 163600});
      expect(controller.activityState, PlayerActivityState.loaded);
    }

    testWidgets('Android: READY after the seek reports paused', (tester) async {
      await loadPaused(tester);
      final states = <PlayerActivityState>[];
      final sub = controller.playerStateStream.listen(states.add);

      // ExoPlayer: BUFFERING (the time update says so too), the seek, then
      // READY with playWhenReady false. Only the first READY of a source
      // is "loaded"; this one is "pause".
      await controller.seekTo(const Duration(seconds: 60));
      await sendEvent(tester, {
        'event': 'timeUpdate',
        'position': 60000,
        'duration': 163600,
        'bufferedPosition': 60000,
        'isBuffering': true,
      });
      await sendEvent(tester, {'event': 'buffering'});
      await sendEvent(tester, {'event': 'seek', 'position': 60000});
      await sendEvent(tester, {'event': 'pause'});
      expect(controller.activityState, PlayerActivityState.paused);

      // The buffering debounce doesn't flip it back afterwards.
      await tester.pump(const Duration(seconds: 1));
      expect(controller.activityState, PlayerActivityState.paused);
      expect(states, isNot(contains(PlayerActivityState.playing)));
      expect(states, isNot(contains(PlayerActivityState.buffering)));
      unawaited(sub.cancel());
    });

    testWidgets('iOS: playbackLikelyToKeepUp after the seek reports paused', (
      tester,
    ) async {
      await loadPaused(tester);

      // AVPlayer: the seek completes, the buffer is likely to keep up again
      // and the paused player reports "pause".
      await controller.seekTo(const Duration(seconds: 60));
      await sendEvent(tester, {'event': 'seek', 'position': 60000});
      await sendEvent(tester, {
        'event': 'timeUpdate',
        'position': 60000,
        'duration': 163600,
        'bufferedPosition': 70000,
        'isBuffering': false,
      });
      await sendEvent(tester, {'event': 'pause'});
      expect(controller.activityState, PlayerActivityState.paused);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.activityState, PlayerActivityState.paused);
    });

    testWidgets('a slow seek on a paused video still shows buffering', (
      tester,
    ) async {
      await loadPaused(tester);
      await controller.seekTo(const Duration(seconds: 60));
      await sendEvent(tester, {'event': 'buffering'});
      // A blip is held back...
      expect(controller.activityState, PlayerActivityState.loaded);
      // ...a real wait is not.
      await tester.pump(const Duration(milliseconds: 700));
      expect(controller.activityState, PlayerActivityState.buffering);

      await sendEvent(tester, {'event': 'pause'});
      expect(controller.activityState, PlayerActivityState.paused);
    });

    testWidgets('Android: a playing seek goes straight back to playing', (
      tester,
    ) async {
      await loadPaused(tester);
      await sendEvent(tester, {'event': 'play'});
      final states = <PlayerActivityState>[];
      final sub = controller.playerStateStream.listen(states.add);

      // ExoPlayer: BUFFERING (isPlaying false, no pause sent), then READY
      // with playWhenReady true: no event for READY, onIsPlayingChanged
      // sends "play". The button never shows paused or loaded.
      await controller.seekTo(const Duration(seconds: 60));
      await sendEvent(tester, {'event': 'buffering'});
      await sendEvent(tester, {'event': 'seek', 'position': 60000});
      await sendEvent(tester, {'event': 'play'});
      await tester.pump(const Duration(seconds: 1));

      expect(controller.activityState, PlayerActivityState.playing);
      expect(states.where((s) => s != PlayerActivityState.playing), isEmpty);
      unawaited(sub.cancel());
    });
  });

  group('completed', () {
    Future<void> playToEnd(WidgetTester tester) async {
      await attachView(tester);
      await sendEvent(tester, {'event': 'loaded', 'duration': 60000});
      await sendEvent(tester, {'event': 'play'});
      // Both platforms: playback stops at the end, then completed.
      await sendEvent(tester, {'event': 'pause'});
      await sendEvent(tester, {'event': 'completed'});
      expect(controller.activityState, PlayerActivityState.completed);
    }

    testWidgets('Android: the rewind after the end keeps completed', (
      tester,
    ) async {
      await playToEnd(tester);
      // ExoPlayer seekTo(0) + pause(): the time update at 0 says
      // buffering, BUFFERING, then READY with playWhenReady false.
      await sendEvent(tester, {
        'event': 'timeUpdate',
        'position': 0,
        'duration': 60000,
        'bufferedPosition': 0,
        'isBuffering': true,
      });
      await sendEvent(tester, {'event': 'buffering'});
      await sendEvent(tester, {'event': 'pause'});
      await sendEvent(tester, {'event': 'pause'});
      await tester.pump(const Duration(seconds: 1));
      expect(controller.activityState, PlayerActivityState.completed);
    });

    testWidgets('iOS: the rewind after the end keeps completed', (
      tester,
    ) async {
      await playToEnd(tester);
      // AVPlayer seek(to: .zero) + pause(): playbackLikelyToKeepUp reports
      // "pause" again once the start is buffered.
      await sendEvent(tester, {
        'event': 'timeUpdate',
        'position': 0,
        'duration': 60000,
        'bufferedPosition': 10000,
        'isBuffering': false,
      });
      await sendEvent(tester, {'event': 'pause'});
      await tester.pump(const Duration(seconds: 1));
      expect(controller.activityState, PlayerActivityState.completed);
    });

    testWidgets('a seek after the end ends paused', (tester) async {
      await playToEnd(tester);
      await controller.seekTo(const Duration(seconds: 20));
      await sendEvent(tester, {'event': 'buffering'});
      await sendEvent(tester, {'event': 'seek', 'position': 20000});
      await sendEvent(tester, {'event': 'pause'});
      expect(controller.activityState, PlayerActivityState.paused);
    });

    testWidgets('replay leaves completed', (tester) async {
      await playToEnd(tester);
      await controller.play();
      await sendEvent(tester, {'event': 'buffering'});
      expect(controller.activityState, PlayerActivityState.buffering);
      await sendEvent(tester, {'event': 'play'});
      expect(controller.activityState, PlayerActivityState.playing);
    });

    testWidgets('a native play (remote control) leaves completed', (
      tester,
    ) async {
      await playToEnd(tester);
      await sendEvent(tester, {'event': 'play'});
      expect(controller.activityState, PlayerActivityState.playing);
      // And completed no longer sticks.
      await sendEvent(tester, {'event': 'pause'});
      expect(controller.activityState, PlayerActivityState.paused);
    });

    testWidgets('a new load leaves completed', (tester) async {
      await playToEnd(tester);
      await controller.load(url: 'https://example.com/next.mp4', force: true);
      expect(controller.activityState, PlayerActivityState.loaded);
    });
  });

  group('live streams', () {
    Future<void> sendLive(WidgetTester tester, {required int positionMs}) =>
        sendEvent(tester, {
          'event': 'timeUpdate',
          'position': positionMs,
          'duration': 120000,
          'bufferedPosition': positionMs,
          'isBuffering': false,
          'isLive': true,
        });

    testWidgets('timeUpdate isLive drives isLive, its stream and the offset', (
      tester,
    ) async {
      await attachView(tester);
      final emitted = <bool>[];
      final sub = controller.isLiveStream.listen(emitted.add);

      expect(controller.isLive, isFalse);
      await sendLive(tester, positionMs: 90000);

      expect(controller.isLive, isTrue);
      expect(controller.duration, const Duration(minutes: 2));
      expect(controller.liveEdgeOffset, const Duration(seconds: 30));
      expect(emitted, [true]);
      // Not awaited: the cancel future never completes in the fake-async
      // zone, which would hang the test.
      unawaited(sub.cancel());
    });

    testWidgets('a VOD update without the flag keeps it, a new load clears '
        'it', (tester) async {
      await attachView(tester);
      await sendLive(tester, positionMs: 1000);
      // Older native builds send no isLive: keep the last known value.
      await sendPosition(tester, 2000);
      expect(controller.isLive, isTrue);

      await controller.load(url: 'https://example.com/vod.mp4', force: true);
      expect(controller.isLive, isFalse);
      expect(controller.liveEdgeOffset, Duration.zero);
    });

    testWidgets('seekToLiveEdge calls the platform for the primary view', (
      tester,
    ) async {
      await attachView(tester);
      await controller.seekToLiveEdge();

      final call = calls.lastWhere((c) => c.method == 'seekToLiveEdge');
      expect((call.arguments as Map)['viewId'], viewId);
    });
  });

  group('seek', () {
    testWidgets('position updates from before a seek are dropped', (
      tester,
    ) async {
      await attachView(tester);
      await sendPosition(tester, 10000);

      await controller.seekTo(const Duration(seconds: 30));
      // Shown right away, before native confirms.
      expect(controller.currentPosition, const Duration(seconds: 30));

      // A tick sent before the seek arrives late: ignored.
      await sendPosition(tester, 10500);
      expect(controller.currentPosition, const Duration(seconds: 30));

      // The first tick near the target is taken, and so is everything after.
      await sendPosition(tester, 30400);
      expect(controller.currentPosition, const Duration(milliseconds: 30400));
      await sendPosition(tester, 12000);
      expect(controller.currentPosition, const Duration(seconds: 12));
    });

    testWidgets('a new load forgets a pending seek', (tester) async {
      await attachView(tester);
      await controller.seekTo(const Duration(seconds: 30));
      await controller.load(url: 'https://example.com/other.mp4', force: true);

      await sendPosition(tester, 1000);
      expect(controller.currentPosition, const Duration(seconds: 1));
    });

    testWidgets('a playing video stays playing through a seek', (tester) async {
      await attachView(tester);
      await sendEvent(tester, {'event': 'play'});
      final states = <PlayerActivityState>[];
      final sub = controller.playerStateStream.listen(states.add);

      // Scrubbing: the native player blips between seeks.
      await controller.seekTo(const Duration(seconds: 30));
      await sendEvent(tester, {'event': 'pause'});
      await controller.seekTo(const Duration(seconds: 31));
      await sendEvent(tester, {'event': 'buffering'});
      await sendEvent(tester, {'event': 'loading'});
      await sendEvent(tester, {'event': 'play'});
      await tester.pump(const Duration(seconds: 1));

      expect(controller.activityState, PlayerActivityState.playing);
      expect(states.where((s) => s != PlayerActivityState.playing), isEmpty);
      unawaited(sub.cancel());
    });

    testWidgets('buffering reported by position updates is held too', (
      tester,
    ) async {
      await attachView(tester);
      await sendEvent(tester, {'event': 'play'});
      final states = <PlayerActivityState>[];
      final sub = controller.playerStateStream.listen(states.add);

      await controller.seekTo(const Duration(seconds: 30));
      Future<void> tick(int ms, {required bool buffering}) =>
          sendEvent(tester, {
            'event': 'timeUpdate',
            'position': ms,
            'duration': 60000,
            'bufferedPosition': ms,
            'isBuffering': buffering,
          });
      await tick(30000, buffering: true);
      await tester.pump(const Duration(milliseconds: 450));
      await tick(30100, buffering: false);
      await sendEvent(tester, {'event': 'play'});
      await tester.pump(const Duration(seconds: 1));

      expect(states.where((s) => s != PlayerActivityState.playing), isEmpty);
      unawaited(sub.cancel());
    });

    testWidgets('a stall after a seek still shows as buffering', (
      tester,
    ) async {
      await attachView(tester);
      await sendEvent(tester, {'event': 'play'});

      await controller.seekTo(const Duration(seconds: 30));
      await sendEvent(tester, {'event': 'buffering'});
      expect(controller.activityState, PlayerActivityState.playing);

      await tester.pump(const Duration(milliseconds: 700));
      expect(controller.activityState, PlayerActivityState.buffering);
    });

    testWidgets('pausing during a seek pauses right away', (tester) async {
      await attachView(tester);
      await sendEvent(tester, {'event': 'play'});

      await controller.seekTo(const Duration(seconds: 30));
      await controller.pause();
      await sendEvent(tester, {'event': 'pause'});
      expect(controller.activityState, PlayerActivityState.paused);
    });
  });
}

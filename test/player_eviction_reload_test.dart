import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the transparent re-load after an iOS total-player LRU eviction
/// (HAB-783 backstop: [NativeVideoPlayerConfig.iosMaxTotalPlayers]).
///
/// Contract under test:
/// 1. A `playerEvicted` event on the controller-scoped channel marks the
///    controller as needing a re-load; the NEXT play() re-loads the last
///    source at the reported position (forced load, then play) instead of
///    no-oping against the torn-down native player.
/// 2. The re-load replays the original request (same url + headers) with
///    `startAtMs` set to the eviction position.
/// 3. The flag is one-shot: a subsequent play() goes straight through, and a
///    play() without a prior load never triggers a re-load.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');

  late List<MethodCall> calls;
  MockStreamHandlerEventSink? controllerSink;

  setUp(() {
    calls = <MethodCall>[];
    controllerSink = null;
    // Make the constructor's channel-setup retry loop effectively
    // synchronous in tests.
    NativeVideoPlayerController.controllerChannelRetryDelays = const [
      Duration.zero,
      Duration.zero,
      Duration.zero,
    ];
  });

  tearDown(() {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig();
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  /// Mocks the shared method channel, recording every [MethodCall].
  void mockMethodChannel() {
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      if (call.method == 'getAvailableQualities') return <Object?>[];
      return null;
    });
  }

  /// Mocks the native StreamHandler for `native_video_player_controller_[id]`,
  /// capturing the sink so tests can push controller-scoped events (the
  /// channel `playerEvicted` arrives on).
  void mockControllerStream(int id) {
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_controller_$id'),
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          controllerSink = events;
        },
      ),
    );
  }

  /// Mocks the per-view EventChannel `native_video_player_[viewId]`.
  void mockViewStream(int viewId) {
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_$viewId'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  }

  /// Creates a controller with one registered platform view and a captured
  /// controller-channel sink. Must run inside `tester.runAsync`.
  Future<NativeVideoPlayerController> pumpControllerWithView(
    WidgetTester tester, {
    required int controllerId,
    required int viewId,
  }) async {
    final context = tester.element(find.byType(SizedBox));
    mockMethodChannel();
    mockControllerStream(controllerId);
    mockViewStream(viewId);

    final controller = NativeVideoPlayerController(id: controllerId);
    await controller.debugControllerChannelSetup;
    await Future<void>.delayed(Duration.zero);
    await controller.onPlatformViewCreated(viewId, context);
    // The per-view subscription has a small internal initial delay.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(controllerSink, isNotNull);
    return controller;
  }

  group('player eviction re-load', () {
    testWidgets('next play() re-loads the last source at the saved position', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());

      await tester.runAsync(() async {
        final controller = await pumpControllerWithView(
          tester,
          controllerId: 71,
          viewId: 710,
        );

        await controller.load(
          url: 'https://example.com/video.m3u8',
          headers: {'Referer': 'https://example.com'},
        );

        // Native evicts this controller's player under the LRU cap.
        controllerSink!.success(<String, Object?>{
          'event': 'playerEvicted',
          'positionMs': 5250,
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));

        calls.clear();
        await controller.play();

        final methods = calls.map((c) => c.method).toList();
        expect(methods, containsAllInOrder(<String>['load', 'play']));

        final reload = calls.firstWhere((c) => c.method == 'load');
        final args = Map<Object?, Object?>.from(reload.arguments as Map);
        expect(args['url'], 'https://example.com/video.m3u8');
        expect(args['startAtMs'], 5250);
        expect(args['headers'], {'Referer': 'https://example.com'});

        // One-shot: the next play() goes straight through.
        calls.clear();
        await controller.play();
        expect(calls.map((c) => c.method), <String>['play']);

        await controller.dispose();
      });
    });

    testWidgets('play() without a prior load never re-loads', (tester) async {
      await tester.pumpWidget(const SizedBox());

      await tester.runAsync(() async {
        final controller = await pumpControllerWithView(
          tester,
          controllerId: 72,
          viewId: 720,
        );

        // Eviction before anything was loaded: nothing to restore.
        controllerSink!.success(<String, Object?>{
          'event': 'playerEvicted',
          'positionMs': 0,
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));

        calls.clear();
        await controller.play();
        expect(calls.map((c) => c.method), <String>['play']);

        await controller.dispose();
      });
    });
  });
}

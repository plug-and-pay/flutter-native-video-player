import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the load/buffering watchdog (HAB-767: infinite spinner).
///
/// Contract under test:
/// 1. A player stuck in a load-pipeline state (initializing/loading) longer
///    than [NativeVideoPlayerConfig.loadTimeout] is surfaced as a regular
///    error: the activity state becomes [PlayerActivityState.error] and the
///    activity listeners receive an event with the same shape a real native
///    error produces (`{'event': 'error', 'message': ...}`).
/// 2. The watchdog disarms when the native side reports progress ('loaded',
///    'play', ...) — no phantom error after a successful load.
/// 3. The buffering watchdog is opt-in via
///    [NativeVideoPlayerConfig.bufferingTimeout] (disabled by default) and
///    best-effort pauses the pipeline when it fires.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');

  late List<String> log;
  MockStreamHandlerEventSink? viewSink;

  setUp(() {
    log = <String>[];
    viewSink = null;
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

  /// Mocks the shared method channel; every call is recorded as
  /// `method:<name>` in [log].
  void mockMethodChannel() {
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      log.add('method:${call.method}');
      if (call.method == 'getAvailableQualities') return <Object?>[];
      return null;
    });
  }

  /// Mocks the native StreamHandler for `native_video_player_controller_[id]`.
  void mockControllerStream(int id) {
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_controller_$id'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  }

  /// Mocks the per-view EventChannel `native_video_player_[viewId]`,
  /// capturing the event sink so tests can push native player events.
  void mockViewStream(int viewId) {
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_$viewId'),
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          viewSink = events;
        },
      ),
    );
  }

  /// Flushes the constructor's async channel setup.
  Future<void> flushSetup(NativeVideoPlayerController controller) async {
    await controller.debugControllerChannelSetup;
    await Future<void>.delayed(Duration.zero);
  }

  /// Creates a controller with one registered platform view whose event
  /// sink is captured in [viewSink]. Must run inside `tester.runAsync`.
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
    await flushSetup(controller);
    await controller.onPlatformViewCreated(viewId, context);
    // The per-view subscription has a small internal initial delay.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(viewSink, isNotNull);
    return controller;
  }

  group('load watchdog', () {
    test('surfaces a stalled initialize as a native-shaped error', () async {
      NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
        loadTimeout: Duration(milliseconds: 80),
      );
      mockMethodChannel();
      mockControllerStream(61);

      final controller = NativeVideoPlayerController(id: 61);
      await flushSetup(controller);

      final activityEvents = <PlayerActivityEvent>[];
      controller.addActivityListener(activityEvents.add);

      // The platform view never arrives: initialize() stays pending and the
      // state sits at initializing — the infinite-spinner scenario.
      unawaited(controller.initialize());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.activityState, PlayerActivityState.initializing);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(controller.activityState, PlayerActivityState.error);
      expect(
        activityEvents.map((e) => e.state),
        contains(PlayerActivityState.error),
      );
      final errorEvent = activityEvents.lastWhere(
        (e) => e.state == PlayerActivityState.error,
      );
      // Same data shape as a real native error: a single 'message' entry.
      expect(errorEvent.data, {'message': 'Load timed out after 80ms'});

      await controller.dispose();
    });

    testWidgets('disarms when the native load completes', (tester) async {
      await tester.pumpWidget(const SizedBox());

      await tester.runAsync(() async {
        NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
          loadTimeout: Duration(milliseconds: 80),
        );
        final controller = await pumpControllerWithView(
          tester,
          controllerId: 62,
          viewId: 620,
        );

        final activityEvents = <PlayerActivityEvent>[];
        controller.addActivityListener(activityEvents.add);

        viewSink!.success(<String, Object?>{'event': 'loading'});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(controller.activityState, PlayerActivityState.loading);

        // Native finishes loading before the timeout: the watchdog must be
        // cancelled and no error may fire afterwards.
        viewSink!.success(<String, Object?>{'event': 'loaded', 'duration': 1000});
        await Future<void>.delayed(const Duration(milliseconds: 250));

        expect(controller.activityState, isNot(PlayerActivityState.error));
        expect(
          activityEvents.map((e) => e.state),
          isNot(contains(PlayerActivityState.error)),
        );

        await controller.dispose();
      });
    });
  });

  group('buffering watchdog', () {
    /// Drives the player into the (debounced) buffering state via the same
    /// timeUpdate events the native side sends.
    Future<void> enterBuffering(NativeVideoPlayerController controller) async {
      viewSink!.success(<String, Object?>{'event': 'play'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.activityState, PlayerActivityState.playing);

      viewSink!.success(<String, Object?>{
        'event': 'timeUpdate',
        'position': 1000,
        'duration': 10000,
        'bufferedPosition': 1000,
        'isBuffering': true,
      });
      // Buffering is debounced by 400ms before it becomes the state.
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(controller.activityState, PlayerActivityState.buffering);
    }

    testWidgets('is disabled by default', (tester) async {
      await tester.pumpWidget(const SizedBox());

      await tester.runAsync(() async {
        final controller = await pumpControllerWithView(
          tester,
          controllerId: 63,
          viewId: 630,
        );

        await enterBuffering(controller);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(controller.activityState, PlayerActivityState.buffering);

        await controller.dispose();
      });
    });

    testWidgets('when opted in, fires and best-effort pauses', (tester) async {
      await tester.pumpWidget(const SizedBox());

      await tester.runAsync(() async {
        NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
          bufferingTimeout: Duration(milliseconds: 100),
        );
        final controller = await pumpControllerWithView(
          tester,
          controllerId: 64,
          viewId: 640,
        );

        final activityEvents = <PlayerActivityEvent>[];
        controller.addActivityListener(activityEvents.add);

        await enterBuffering(controller);
        await Future<void>.delayed(const Duration(milliseconds: 250));

        expect(controller.activityState, PlayerActivityState.error);
        final errorEvent = activityEvents.lastWhere(
          (e) => e.state == PlayerActivityState.error,
        );
        expect(errorEvent.data, {
          'message': 'Buffering timed out after 100ms',
        });
        // The watchdog quiesces the stalled pipeline.
        expect(log, contains('method:pause'));

        await controller.dispose();
      });
    });
  });
}

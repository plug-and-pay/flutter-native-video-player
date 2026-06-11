import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lifecycle tests for the controller-level EventChannel
/// (`native_video_player_controller_$id`).
///
/// Contract under test (the fix for the MissingPluginException reported in
/// GitHub issue #31):
/// 1. The controller asks the native side to register the channel's
///    StreamHandler (`setupControllerEventChannel` on the shared
///    `native_video_player` MethodChannel) and only calls
///    `receiveBroadcastStream().listen()` AFTER the native ack.
/// 2. If the native side never acks (plugin not registered), the controller
///    gives up silently — no `listen` envelope is sent and no FlutterError is
///    reported.
/// 3. Disposal happens in order: Dart cancels the subscription (native
///    onCancel) → `teardownControllerEventChannel` → native player disposal
///    (`disposeController` when no platform view ever provided a method
///    channel).
/// 4. `releaseResources()` keeps the subscription alive (PiP/AirPlay events
///    must survive view disposal).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');

  late List<String> log;
  late List<FlutterErrorDetails> flutterErrors;
  FlutterExceptionHandler? originalOnError;
  MockStreamHandlerEventSink? controllerSink;

  setUp(() {
    log = <String>[];
    flutterErrors = <FlutterErrorDetails>[];
    controllerSink = null;
    originalOnError = FlutterError.onError;
    FlutterError.onError = flutterErrors.add;
    // Make the setup retry loop effectively synchronous in tests.
    NativeVideoPlayerController.controllerChannelRetryDelays = const [
      Duration.zero,
      Duration.zero,
      Duration.zero,
    ];
  });

  tearDown(() {
    FlutterError.onError = originalOnError;
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

  /// Mocks the native StreamHandler for `native_video_player_controller_[id]`,
  /// recording onListen/onCancel and capturing the event sink.
  void mockControllerStream(int id) {
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_controller_$id'),
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          log.add('onListen');
          controllerSink = events;
        },
        onCancel: (arguments) => log.add('onCancel'),
      ),
    );
  }

  /// Mocks the per-view EventChannel `native_video_player_[viewId]` so that
  /// `onPlatformViewCreated` doesn't pollute tests with activation errors.
  void mockViewStream(int viewId) {
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_$viewId'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  }

  /// Flushes the constructor's async channel setup (plain `test` zone only;
  /// in `testWidgets` use pumps instead).
  Future<void> flushSetup(NativeVideoPlayerController controller) async {
    await controller.debugControllerChannelSetup;
    // One extra microtask hop for the listen() that follows the ack.
    await Future<void>.delayed(Duration.zero);
  }

  group('controller event channel setup', () {
    test('native handler registration precedes listen', () async {
      mockMethodChannel();
      mockControllerStream(5);

      final controller = NativeVideoPlayerController(id: 5);
      await flushSetup(controller);

      final relevant = log
          .where(
            (e) => e == 'method:setupControllerEventChannel' || e == 'onListen',
          )
          .toList();
      expect(relevant, ['method:setupControllerEventChannel', 'onListen']);
      expect(flutterErrors, isEmpty);

      await controller.dispose();
    });

    test(
      'no FlutterError and no listen attempt when native side is absent',
      () async {
        // Nothing mocked: the shared method channel and the event channel both
        // behave as if the plugin is not registered.
        var listenAttempts = 0;
        messenger.setMockMessageHandler('native_video_player_controller_42', (
          message,
        ) async {
          listenAttempts++;
          return null; // null reply == MissingPluginException on the caller
        });

        final controller = NativeVideoPlayerController(id: 42);
        await flushSetup(controller);

        expect(
          listenAttempts,
          0,
          reason: 'listen must not be attempted without a native ack',
        );
        expect(
          flutterErrors,
          isEmpty,
          reason: 'constructing a controller must not report a FlutterError',
        );

        await controller.dispose();
        messenger.setMockMessageHandler(
          'native_video_player_controller_42',
          null,
        );
      },
    );

    test('controller events flow after setup', () async {
      mockMethodChannel();
      mockControllerStream(6);

      final controller = NativeVideoPlayerController(id: 6);
      final controlEvents = <PlayerControlEvent>[];
      controller.addControlListener(controlEvents.add);
      await flushSetup(controller);
      expect(controllerSink, isNotNull);

      controllerSink!.success(<String, Object?>{'event': 'pipStart'});
      await Future<void>.delayed(Duration.zero);

      expect(controller.isPipEnabled, isTrue);
      expect(
        controlEvents.map((e) => e.state),
        contains(PlayerControlState.pipStarted),
      );

      controllerSink!.success(<String, Object?>{'event': 'pipStop'});
      await Future<void>.delayed(Duration.zero);
      expect(controller.isPipEnabled, isFalse);

      await controller.dispose();
    });
  });

  group('disposal ordering', () {
    test('cancel precedes teardown precedes native dispose', () async {
      mockMethodChannel();
      mockControllerStream(7);

      final controller = NativeVideoPlayerController(id: 7);
      await flushSetup(controller);

      log.clear();
      await controller.dispose();

      final relevant = log
          .where(
            (e) =>
                e == 'onCancel' ||
                e == 'method:teardownControllerEventChannel' ||
                e == 'method:disposeController',
          )
          .toList();
      expect(relevant, [
        'onCancel',
        'method:teardownControllerEventChannel',
        'method:disposeController',
      ]);
    });

    test('double dispose tears down only once', () async {
      mockMethodChannel();
      mockControllerStream(8);

      final controller = NativeVideoPlayerController(id: 8);
      await flushSetup(controller);

      await controller.dispose();
      await controller.dispose();

      expect(
        log.where((e) => e == 'method:teardownControllerEventChannel').length,
        1,
      );
      expect(log.where((e) => e == 'onCancel').length, 1);
    });

    test('dispose before setup completes never listens', () async {
      final setupGate = Completer<void>();
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        log.add('method:${call.method}');
        if (call.method == 'setupControllerEventChannel') {
          await setupGate.future;
        }
        return null;
      });
      mockControllerStream(9);

      final controller = NativeVideoPlayerController(id: 9);
      final disposed = controller.dispose();
      setupGate.complete();
      await disposed;
      await Future<void>.delayed(Duration.zero);

      expect(log, isNot(contains('onListen')));
      expect(flutterErrors, isEmpty);
    });

    test('recreate with the same controller ID works', () async {
      mockMethodChannel();
      mockControllerStream(11);

      final first = NativeVideoPlayerController(id: 11);
      await flushSetup(first);
      await first.dispose();

      // New native registration cycle for the same ID.
      mockControllerStream(11);
      final second = NativeVideoPlayerController(id: 11);
      await flushSetup(second);

      expect(
        log.where((e) => e == 'method:setupControllerEventChannel').length,
        2,
      );
      expect(log.where((e) => e == 'onListen').length, 2);

      controllerSink!.success(<String, Object?>{'event': 'pipStart'});
      await Future<void>.delayed(Duration.zero);
      expect(second.isPipEnabled, isTrue);
      expect(first.isPipEnabled, isFalse);

      await second.dispose();
    });
  });

  group('releaseResources', () {
    test('keeps the controller event subscription alive', () async {
      mockMethodChannel();
      mockControllerStream(12);

      final controller = NativeVideoPlayerController(id: 12);
      await flushSetup(controller);

      await controller.releaseResources();

      expect(
        log,
        isNot(contains('onCancel')),
        reason: 'releaseResources must not cancel the controller channel',
      );

      // PiP events still flow with zero platform views.
      controllerSink!.success(<String, Object?>{'event': 'pipStart'});
      await Future<void>.delayed(Duration.zero);
      expect(controller.isPipEnabled, isTrue);

      await controller.dispose();
      expect(log, contains('onCancel'));
    });
  });

  group('dispose player release', () {
    testWidgets(
      'dispose releases the controller even when the view dispose hits NO_VIEW',
      (tester) async {
        // The view-routed 'dispose' races platform-view teardown when a feed
        // tile unmounts (NO_VIEW) — dropping it silently leaked one native
        // player per disposed controller (observed as an OOM on a Galaxy S21
        // after a few six-player feed visits). disposeController must always
        // run as the authoritative release.
        await tester.pumpWidget(const SizedBox());
        final context = tester.element(find.byType(SizedBox));

        await tester.runAsync(() async {
          messenger.setMockMethodCallHandler(methodChannel, (call) async {
            log.add('method:${call.method}');
            if (call.method == 'dispose') {
              throw PlatformException(
                code: 'NO_VIEW',
                message: 'No view found for method call',
              );
            }
            if (call.method == 'getAvailableQualities') return <Object?>[];
            return null;
          });
          mockControllerStream(14);
          mockViewStream(412);

          final controller = NativeVideoPlayerController(id: 14);
          await flushSetup(controller);

          await controller.onPlatformViewCreated(412, context);
          await Future<void>.delayed(const Duration(milliseconds: 100));

          await controller.dispose();

          expect(
            log,
            contains('method:dispose'),
            reason: 'the view-routed dispose should still be attempted',
          );
          expect(
            log,
            contains('method:disposeController'),
            reason:
                'disposeController must run as the authoritative release '
                'even though the view dispose failed',
          );
          expect(flutterErrors, isEmpty);
        });
      },
    );
  });

  group('platform view safety net', () {
    testWidgets('onPlatformViewCreated sets up the channel if setup failed', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final context = tester.element(find.byType(SizedBox));

      // The platform-view path uses real timers (retry delays, per-view
      // subscribe delay), so run with real async instead of the fake clock.
      await tester.runAsync(() async {
        // Native absent during construction: a null reply is what the engine
        // sends for an unregistered channel and is decoded as a
        // MissingPluginException by the caller.
        messenger.setMockMessageHandler(
          'native_video_player',
          (message) async => null,
        );

        final controller = NativeVideoPlayerController(id: 13);
        await controller.debugControllerChannelSetup;
        await Future<void>.delayed(Duration.zero);
        expect(log, isNot(contains('onListen')));

        // Plugin becomes available (e.g. attach raced the constructor) and a
        // platform view is created.
        mockMethodChannel();
        mockControllerStream(13);
        mockViewStream(101);

        await controller.onPlatformViewCreated(101, context);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(log, contains('onListen'));
        expect(flutterErrors, isEmpty);

        await controller.dispose();
      });
    });
  });
}

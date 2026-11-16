import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// `deferNativePlayer`: an unused tile shows its Flutter layers (overlay)
/// over black and creates no platform view; the first use creates it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pluginChannel = MethodChannel('native_video_player');
  final calls = <String>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(pluginChannel, (call) async {
      calls.add(call.method);
      return null;
    });
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_controller_7'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(pluginChannel, null);
  });

  Widget host(NativeVideoPlayerController controller) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 225,
        child: NativeVideoPlayer(
          controller: controller,
          overlayBuilder: (context, controller) =>
              const Center(child: Text('controls')),
        ),
      ),
    ),
  );

  testWidgets(
    'an unused deferred controller builds no platform view but shows the overlay',
    (tester) async {
      final controller = NativeVideoPlayerController(
        id: 7,
        deferNativePlayer: true,
      );
      await tester.pumpWidget(host(controller));
      await controller.initialize();
      await tester.pump();

      expect(find.byType(UiKitView), findsNothing);
      expect(find.text('controls'), findsOneWidget);
      expect(controller.hasNativePlayer, isFalse);
      expect(controller.activityState, PlayerActivityState.initialized);
      expect(calls, isNot(contains('createTextureView')));

      await tester.pumpWidget(const SizedBox());
      await controller.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'an unused deferred player fills loose constraints like a platform view',
    (tester) async {
      // Apps put the player in a Stack (loose constraints); the placeholder
      // must take the whole slot, or the overlay on top is laid out at 0x0.
      final controller = NativeVideoPlayerController(
        id: 7,
        deferNativePlayer: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 225,
                child: Stack(
                  children: [
                    NativeVideoPlayer(
                      controller: controller,
                      overlayBuilder: (context, controller) =>
                          const Center(child: Text('controls')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.getSize(find.byType(NativeVideoPlayer)),
        const Size(400, 225),
      );
      expect(tester.getSize(find.text('controls')).width, greaterThan(0));

      await tester.pumpWidget(const SizedBox());
      await controller.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'an unused deferred player sends its current state to the overlay',
    (tester) async {
      // A native view re-sends duration, PiP availability, etc. when it
      // attaches; controls built on those streams need the same first values
      // without one (e.g. a "0:00 / 1:00" label and the PiP button).
      final controller = NativeVideoPlayerController(
        id: 7,
        deferNativePlayer: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 225,
              child: NativeVideoPlayer(
                controller: controller,
                overlayBuilder: (context, controller) => Column(
                  children: [
                    StreamBuilder<Duration>(
                      // Through an async* wrapper, like a Riverpod stream
                      // provider: it subscribes a microtask after the build.
                      stream: () async* {
                        yield* controller.durationStream;
                      }(),
                      builder: (context, snapshot) => Text(
                        snapshot.hasData ? 'duration known' : 'no duration',
                      ),
                    ),
                    StreamBuilder<bool>(
                      stream: controller.isPipAvailableStream,
                      builder: (context, snapshot) =>
                          Text(snapshot.hasData ? 'pip known' : 'no pip'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(Duration.zero);
      await tester.pump();

      expect(find.text('duration known'), findsOneWidget);
      expect(find.text('pip known'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await controller.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'an unused deferred player takes PiP availability from the controller channel',
    (tester) async {
      // The PiP button depends on it, and there is no view to ask yet.
      messenger.setMockStreamHandler(
        const EventChannel('native_video_player_controller_8'),
        MockStreamHandler.inline(
          onListen: (arguments, events) => events.success(<String, Object>{
            'event': 'pipAvailabilityChanged',
            'isAvailable': true,
          }),
        ),
      );
      final controller = NativeVideoPlayerController(
        id: 8,
        deferNativePlayer: true,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(controller.isPipAvailable, isTrue);
      await controller.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('first use builds the platform view', (tester) async {
    final controller = NativeVideoPlayerController(
      id: 7,
      deferNativePlayer: true,
    );
    await tester.pumpWidget(host(controller));
    await controller.initialize();
    await tester.pump();
    expect(find.byType(UiKitView), findsNothing);

    // load() asks for the native player; it waits for the view, which this
    // test environment never finishes creating, so it isn't awaited here.
    Object? loadError;
    final Future<void> loading = controller
        .load(url: 'https://x/v.m3u8')
        .catchError((Object e) => loadError = e);
    await tester.pump();

    expect(controller.hasNativePlayer, isTrue);
    expect(find.byType(UiKitView), findsOneWidget);
    expect(find.text('controls'), findsOneWidget);

    // Without a native view, first use gives up after its timeout with a
    // clear error instead of hanging.
    await tester.pump(const Duration(seconds: 11));
    await loading;
    expect(loadError, isA<StateError>());

    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('without the option the platform view is built right away', (
    tester,
  ) async {
    final controller = NativeVideoPlayerController(id: 7);
    await tester.pumpWidget(host(controller));
    await tester.pump();

    expect(controller.hasNativePlayer, isTrue);
    expect(find.byType(UiKitView), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  test('AirPlay picker and detection work without any player view', () async {
    AirPlayStateManager.debugIsIOSOverride = true;
    try {
      await AirPlayStateManager.instance.showAirPlayPicker();
      await AirPlayStateManager.instance.init();
      expect(
        calls,
        containsAll(<String>['showAirPlayPicker', 'startAirPlayDetection']),
      );
    } finally {
      AirPlayStateManager.debugIsIOSOverride = null;
    }
  });
}

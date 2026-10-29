import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1x1 transparent PNG, a poster frame the test image codec can decode.
final Uint8List _poster = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Tests for the iOS platform view leaving the scene while a route covers
/// it, the poster frame capture, and the fullscreen flight.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NativeVideoPlayerController controller;
  const methodChannel = MethodChannel('native_video_player');
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
          calls.add(call);
          return call.method == 'captureFrame' ? _poster : null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('native_video_player_controller_1'),
          MockStreamHandler.inline(onListen: (arguments, events) {}),
        );
    controller = NativeVideoPlayerController(id: 1);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    controller.dispose();
  });

  /// Whether the platform view is painted: it sits in a Visibility while
  /// covering is possible.
  bool platformViewVisible(WidgetTester tester, Type viewType) {
    final Finder visibility = find.ancestor(
      of: find.byType(viewType),
      matching: find.byType(Visibility),
    );
    if (visibility.evaluate().isEmpty) return true;
    return tester.widget<Visibility>(visibility.first).visible;
  }

  Widget app() => MaterialApp(
    home: Builder(
      builder: (BuildContext context) => Scaffold(
        body: Column(
          children: [
            SizedBox(
              height: 200,
              child: NativeVideoPlayer(controller: controller),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('next page')),
                ),
              ),
              child: const Text('push'),
            ),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(content: Text('dialog')),
              ),
              child: const Text('dialog'),
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets(
    'iOS: the platform view leaves the scene while a page route covers it',
    (WidgetTester tester) async {
      await tester.pumpWidget(app());
      expect(platformViewVisible(tester, UiKitView), isTrue);

      await tester.tap(find.text('push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Hidden from the first transition frame on, poster painted instead.
      expect(platformViewVisible(tester, UiKitView), isFalse);
      expect(find.byType(UiKitView), findsOneWidget);

      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('next page'))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Still hidden while the page slides off it.
      expect(platformViewVisible(tester, UiKitView), isFalse);

      await tester.pumpAndSettle();
      expect(platformViewVisible(tester, UiKitView), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('iOS: a dialog over the player leaves the platform view alone', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(app());

    await tester.tap(find.text('dialog'));
    await tester.pumpAndSettle();

    expect(find.text('dialog'), findsWidgets);
    expect(platformViewVisible(tester, UiKitView), isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Android: the platform view is never hidden for a route', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(app());

    await tester.tap(find.text('push'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(platformViewVisible(tester, PlatformViewLink), isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    "Android: a page's native view exists only while the page is not moving",
    (WidgetTester tester) async {
      late BuildContext homeContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              homeContext = context;
              return const Scaffold(body: Text('home'));
            },
          ),
        ),
      );

      Navigator.of(homeContext).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: SizedBox(
              height: 200,
              child: NativeVideoPlayer(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Being pushed: black that moves with the page, no native view yet.
      expect(find.byType(PlatformViewLink), findsNothing);

      await tester.pumpAndSettle();
      expect(find.byType(PlatformViewLink), findsOneWidget);

      Navigator.of(homeContext).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Popped: released right away, not left at full opacity.
      expect(find.byType(PlatformViewLink), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('capturePosterFrame keeps the frame and asks the given view', (
    WidgetTester tester,
  ) async {
    expect(controller.posterFrame, isNull);

    final Uint8List? frame = await controller.capturePosterFrame(
      7,
      maxWidth: 640,
    );

    expect(frame, _poster);
    expect(controller.posterFrame, _poster);
    final MethodCall call = calls.singleWhere(
      (MethodCall c) => c.method == 'captureFrame',
    );
    expect(call.arguments, <String, Object>{'viewId': 7, 'maxWidth': 640});
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('capturePosterFrame keeps the last frame when a capture fails', (
    WidgetTester tester,
  ) async {
    await controller.capturePosterFrame(7);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          methodChannel,
          (MethodCall call) async => null,
        );

    expect(await controller.capturePosterFrame(7), _poster);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  group('FullscreenHeroTransition', () {
    const Rect inline = Rect.fromLTWH(20, 100, 360, 200);
    const Size screen = Size(800, 600);

    FullscreenHeroFlight flight({Rect? inlineNow}) => FullscreenHeroFlight(
      poster: _poster,
      startRect: inline,
      inlineRect: () => inlineNow ?? inline,
      capturePoster: () async => _poster,
    );

    Widget host(Animation<double> animation, FullscreenHeroFlight flight) =>
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: screen),
            child: FullscreenHeroTransition(
              animation: animation,
              flight: flight,
              child: const ColoredBox(
                color: Colors.red,
                child: Text('live page'),
              ),
            ),
          ),
        );

    Rect posterRect(WidgetTester tester) => tester.getRect(find.byType(Image));

    bool pageVisible(WidgetTester tester) => tester
        .widget<Visibility>(
          find.ancestor(
            of: find.text('live page'),
            matching: find.byType(Visibility),
          ),
        )
        .visible;

    AnimationController controllerAt(double value) => AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 350),
      value: value,
    );

    Future<void> useScreen(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(screen);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }

    testWidgets('grows the frame from the inline rect, then shows the page', (
      WidgetTester tester,
    ) async {
      final animation = controllerAt(0);
      addTearDown(animation.dispose);
      await useScreen(tester);

      await tester.pumpWidget(host(animation, flight()));
      expect(posterRect(tester), inline);
      expect(pageVisible(tester), isFalse);

      animation.forward();
      animation.value = 0.5;
      await tester.pump();
      expect(
        posterRect(tester),
        Rect.lerp(
          inline,
          Offset.zero & screen,
          Curves.fastOutSlowIn.transform(0.5),
        ),
      );
      expect(pageVisible(tester), isFalse);

      animation.value = 1;
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(pageVisible(tester), isTrue);
    });

    testWidgets('flies the live texture and releases it when a leg ends', (
      WidgetTester tester,
    ) async {
      final animation = controllerAt(0);
      addTearDown(animation.dispose);
      await useScreen(tester);
      final List<int> released = <int>[];
      final FullscreenHeroFlight live = FullscreenHeroFlight(
        poster: _poster,
        startRect: inline,
        inlineRect: () => inline,
        capturePoster: () async => _poster,
        liveTextureId: 5,
        createLiveTexture: () async => 6,
        disposeLiveTexture: released.add,
      );

      await tester.pumpWidget(host(animation, live));
      animation.forward();
      animation.value = 0.5;
      await tester.pump();
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 5);

      animation.value = 1;
      await tester.pump();
      expect(released, <int>[5]);
      expect(live.liveTextureId, isNull);
      expect(find.byType(Texture), findsNothing);
    });

    testWidgets('reports the way back when it starts', (
      WidgetTester tester,
    ) async {
      final animation = controllerAt(1);
      addTearDown(animation.dispose);
      await useScreen(tester);
      var returns = 0;
      final FullscreenHeroFlight f = FullscreenHeroFlight(
        poster: _poster,
        startRect: inline,
        inlineRect: () => inline,
        capturePoster: () async => _poster,
        onReturn: () => returns++,
      );

      await tester.pumpWidget(host(animation, f));
      expect(returns, 0);
      animation.reverse();
      await tester.pump();
      expect(returns, 1);
      animation.stop();
    });

    testWidgets('reports landing only near the end of the way back', (
      WidgetTester tester,
    ) async {
      final animation = controllerAt(1);
      addTearDown(animation.dispose);
      await useScreen(tester);
      var landings = 0;
      final FullscreenHeroFlight f = FullscreenHeroFlight(
        poster: _poster,
        startRect: inline,
        inlineRect: () => inline,
        capturePoster: () async => _poster,
        onLanding: () => landings++,
      );

      await tester.pumpWidget(host(animation, f));
      animation.reverse();
      animation.value = 0.5;
      await tester.pump();
      expect(landings, 0);

      animation.value = 0.02;
      await tester.pump();
      expect(landings, 1);
      animation.stop();
    });

    testWidgets('closes into where the inline player is now', (
      WidgetTester tester,
    ) async {
      const Rect moved = Rect.fromLTWH(40, 300, 360, 200);
      final animation = controllerAt(1);
      addTearDown(animation.dispose);
      await useScreen(tester);

      await tester.pumpWidget(host(animation, flight(inlineNow: moved)));
      expect(pageVisible(tester), isTrue);

      animation.reverse();
      animation.value = 0;
      await tester.pump();
      expect(posterRect(tester), moved);
      expect(pageVisible(tester), isFalse);
    });

    testWidgets('closes from where a swipe dismissed the page', (
      WidgetTester tester,
    ) async {
      const Rect dragged = Rect.fromLTWH(60, 200, 680, 510);
      final animation = controllerAt(1);
      addTearDown(animation.dispose);
      await useScreen(tester);
      final FullscreenHeroFlight f = flight()
        ..dismissedFromRect = dragged
        ..dismissedBackdropOpacity = 0.5;

      await tester.pumpWidget(host(animation, f));
      animation.reverse();
      animation.value = 0.999999;
      await tester.pump();
      final Rect rect = posterRect(tester);
      expect(rect.left, closeTo(dragged.left, 0.01));
      expect(rect.top, closeTo(dragged.top, 0.01));
      expect(rect.width, closeTo(dragged.width, 0.01));
    });
  });
}

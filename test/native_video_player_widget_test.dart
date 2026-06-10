import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NativeVideoPlayerController controller;
  late MethodChannel methodChannel;

  setUp(() {
    // Mocks must be installed BEFORE the controller is constructed: the
    // constructor already talks to the platform to register the controller
    // event channel.
    methodChannel = const MethodChannel('native_video_player');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'load':
              return null;
            case 'play':
              return null;
            case 'pause':
              return null;
            default:
              return null;
          }
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('native_video_player_controller_1'),
          MockStreamHandler.inline(onListen: (arguments, events) {}),
        );

    controller = NativeVideoPlayerController(
      id: 1,
      autoPlay: true,
      mediaInfo: NativeVideoPlayerMediaInfo(
        title: 'Test Video',
        subtitle: 'Test Subtitle',
        artworkUrl: 'https://example.com/artwork.jpg',
      ),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    controller.dispose();
  });

  testWidgets('NativeVideoPlayer widget creates and initializes correctly', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NativeVideoPlayer(controller: controller)),
      ),
    );

    expect(find.byType(NativeVideoPlayer), findsOneWidget);
  });

  testWidgets(
    'NativeVideoPlayer widget handles platform view creation',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NativeVideoPlayer(controller: controller)),
        ),
      );

      await tester.pumpAndSettle();

      // Android uses hybrid composition via PlatformViewLink (not AndroidView)
      expect(find.byType(PlatformViewLink), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'NativeVideoPlayer widget handles platform view creation on iOS',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NativeVideoPlayer(controller: controller)),
        ),
      );

      await tester.pumpAndSettle();

      // Verify platform view is created
      expect(find.byType(UiKitView), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'NativeVideoPlayer widget shows unsupported platform message',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NativeVideoPlayer(controller: controller)),
        ),
      );

      await tester.pumpAndSettle();

      // Verify unsupported platform message is shown
      expect(find.text('Only iOS and Android are supported'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('NativeVideoPlayer widget disposes correctly', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NativeVideoPlayer(controller: controller)),
      ),
    );

    await tester.pumpAndSettle();

    // Rebuild without the widget to trigger disposal
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );

    // Verify no errors during disposal
    expect(tester.takeException(), isNull);
  });
}

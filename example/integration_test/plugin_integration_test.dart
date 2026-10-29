// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late NativeVideoPlayerController controller;

  setUp(() {
    controller = NativeVideoPlayerController(
      id: 1,
      autoPlay: true,
      mediaInfo: NativeVideoPlayerMediaInfo(
        title: 'Integration Test Video',
        subtitle: 'Test HLS Stream',
        artworkUrl: 'https://example.com/artwork.jpg',
      ),
    );
  });

  tearDown(() async {
    await controller.dispose();
  });

  testWidgets('Full video playback flow test', (WidgetTester tester) async {
    // Build widget
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NativeVideoPlayer(controller: controller)),
      ),
    );

    await tester.pumpAndSettle();

    // Initialize and load video
    await controller.initialize();
    await controller.load(
      url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    );

    // Wait for video to load. With autoPlay, playback may already have
    // started by the time load() returns.
    await tester.pumpAndSettle();
    expect(
      controller.activityState,
      anyOf(PlayerActivityState.loaded, PlayerActivityState.playing),
    );
    expect(controller.duration, greaterThan(Duration.zero));

    // Test playback controls
    await controller.play();
    await tester.pumpAndSettle();

    await controller.pause();
    await tester.pumpAndSettle();

    await controller.seekTo(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await controller.setVolume(0.5);
    await tester.pumpAndSettle();

    // Test quality selection if available
    if (controller.qualities.isNotEmpty) {
      final quality = controller.qualities.first;
      await controller.setQuality(quality);
      await tester.pumpAndSettle();
    }

    // Test fullscreen
    await controller.enterFullScreen();
    await tester.pumpAndSettle();

    await controller.exitFullScreen();
    await tester.pumpAndSettle();
  });

  testWidgets('Video player event handling test', (WidgetTester tester) async {
    final List<PlayerActivityEvent> receivedActivityEvents = [];
    final List<PlayerControlEvent> receivedControlEvents = [];

    // Build widget
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NativeVideoPlayer(controller: controller)),
      ),
    );

    await tester.pumpAndSettle();

    // Add event listeners
    controller.addActivityListener(
      (event) => receivedActivityEvents.add(event),
    );
    controller.addControlListener((event) => receivedControlEvents.add(event));

    // Initialize and load video
    await controller.initialize();
    await controller.load(
      url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    );

    await tester.pumpAndSettle();

    // Trigger some events
    await controller.play();
    await tester.pumpAndSettle();

    await controller.pause();
    await tester.pumpAndSettle();

    // Verify we received some events
    expect(receivedActivityEvents, isNotEmpty);
  });

  testWidgets('Video player error handling test', (WidgetTester tester) async {
    // Build widget
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NativeVideoPlayer(controller: controller)),
      ),
    );

    await tester.pumpAndSettle();

    // Initialize and try to load invalid URL
    await controller.initialize();

    // The native load rejects an unreachable host.
    await expectLater(
      controller.load(url: 'https://invalid-url/video.m3u8'),
      throwsA(isA<PlatformException>()),
    );

    await tester.pumpAndSettle();
    expect(controller.activityState, PlayerActivityState.error);
  });

  testWidgets('Picture-in-Picture test', (WidgetTester tester) async {
    // Replaces the setUp controller; tearDown only disposes this one.
    await controller.dispose();
    controller = NativeVideoPlayerController(
      id: 1,
      autoPlay: true,
      allowsPictureInPicture: true,
      canStartPictureInPictureAutomatically: true,
      mediaInfo: NativeVideoPlayerMediaInfo(
        title: 'PiP Test Video',
        subtitle: 'Test HLS Stream',
        artworkUrl: 'https://example.com/artwork.jpg',
      ),
    );

    // Build widget
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NativeVideoPlayer(controller: controller)),
      ),
    );

    await tester.pumpAndSettle();

    // Initialize and load video
    await controller.initialize();
    await controller.load(
      url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    );

    await tester.pumpAndSettle();

    // Start playback
    await controller.play();
    await tester.pumpAndSettle();

    // Note: We can't actually test PiP mode in integration tests
    // as it requires user interaction, but we can verify the setup
    expect(controller.creationParams['allowsPictureInPicture'], isTrue);
    expect(
      controller.creationParams['canStartPictureInPictureAutomatically'],
      isTrue,
    );
  });
}

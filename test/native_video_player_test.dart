import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Core controller tests against a fully mocked platform side.
///
/// Mocks are installed BEFORE the controller is constructed (the constructor
/// already talks to the platform to set up the controller event channel), and
/// platform-view creation is simulated via [NativeVideoPlayerController.onPlatformViewCreated]
/// so that `initialize()` completes like it does in a real app.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');
  const controllerId = 1;
  const platformViewId = 1;

  late NativeVideoPlayerController controller;

  void installMocks() {
    messenger.setMockMethodCallHandler(methodChannel, (
      MethodCall methodCall,
    ) async {
      switch (methodCall.method) {
        case 'getAvailableQualities':
          return [
            {'label': '1080p', 'url': 'https://example.com/video_1080p.m3u8'},
            {'label': '720p', 'url': 'https://example.com/video_720p.m3u8'},
          ];
        default:
          return null;
      }
    });
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_controller_$controllerId'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_$platformViewId'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  }

  /// Simulates the platform view having been created so `initialize()` and
  /// `load()` work like in a real app.
  Future<void> attachPlatformView(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    final BuildContext context = tester.element(find.byType(SizedBox));
    await controller.onPlatformViewCreated(platformViewId, context);
    await controller.initialize();
    // Let the per-view event subscription (10ms retry delay) attach.
    await tester.pump(const Duration(milliseconds: 100));
  }

  setUp(() {
    installMocks();
    controller = NativeVideoPlayerController(
      id: controllerId,
      autoPlay: true,
      mediaInfo: NativeVideoPlayerMediaInfo(
        title: 'Test Video',
        subtitle: 'Test Subtitle',
        artworkUrl: 'https://example.com/artwork.jpg',
      ),
    );
  });

  tearDown(() async {
    await controller.dispose();
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  group('NativeVideoPlayerController initialization', () {
    test('should initialize correctly', () async {
      expect(controller.id, equals(1));
      expect(controller.autoPlay, isTrue);
      expect(controller.mediaInfo, isNotNull);
      expect(controller.mediaInfo?.title, equals('Test Video'));
      expect(controller.activityState.isLoaded, isFalse);
      expect(controller.url, isNull);
    });

    test('should not be loaded before load() is called', () {
      expect(controller.activityState.isLoaded, isFalse);
    });
  });

  group('NativeVideoPlayerController loading', () {
    testWidgets('should load video correctly', (tester) async {
      await attachPlatformView(tester);
      await controller.load(url: 'https://example.com/video.m3u8');
      expect(controller.activityState.isLoaded, isTrue);
      expect(controller.url, equals('https://example.com/video.m3u8'));
    });

    test('should throw if load() is called before initialize()', () async {
      expect(
        () => controller.load(url: 'https://example.com/video.m3u8'),
        throwsException,
      );
    });

    testWidgets('should load with headers', (tester) async {
      await attachPlatformView(tester);
      await controller.load(
        url: 'https://example.com/video.m3u8',
        headers: {'Referer': 'https://example.com'},
      );
      expect(controller.activityState.isLoaded, isTrue);
    });
  });

  group('NativeVideoPlayerController playback controls', () {
    testWidgets('should run playback commands without errors', (tester) async {
      await attachPlatformView(tester);
      await controller.load(url: 'https://example.com/video.m3u8');

      await controller.play();
      await controller.pause();
      await controller.seekTo(const Duration(seconds: 30));
      await controller.setVolume(0.5);
      await controller.setSpeed(1.5);
    });
  });

  group('NativeVideoPlayerController quality control', () {
    testWidgets('should fetch available qualities', (tester) async {
      await attachPlatformView(tester);
      await controller.load(url: 'https://example.com/video.m3u8');

      expect(controller.qualities.length, equals(2));
      expect(controller.qualities.first.label, equals('1080p'));
      expect(controller.qualities.last.label, equals('720p'));
    });

    testWidgets('should set quality', (tester) async {
      await attachPlatformView(tester);
      await controller.load(url: 'https://example.com/video.m3u8');

      final quality = controller.qualities.first;
      await controller.setQuality(quality);
    });
  });

  group('NativeVideoPlayerController fullscreen control', () {
    testWidgets('should enter and exit fullscreen', (tester) async {
      await attachPlatformView(tester);
      await controller.load(url: 'https://example.com/video.m3u8');

      expect(controller.isFullScreen, isFalse);
      await controller.enterFullScreen();
      expect(controller.isFullScreen, isTrue);
      await controller.exitFullScreen();
      expect(controller.isFullScreen, isFalse);
    });

    testWidgets('should toggle fullscreen', (tester) async {
      await attachPlatformView(tester);
      await controller.load(url: 'https://example.com/video.m3u8');

      expect(controller.isFullScreen, isFalse);
      await controller.toggleFullScreen();
      expect(controller.isFullScreen, isTrue);
      await controller.toggleFullScreen();
      expect(controller.isFullScreen, isFalse);
    });
  });

  group('NativeVideoPlayerController event handling', () {
    testWidgets('should handle player events', (tester) async {
      final receivedEvents = <PlayerActivityEvent>[];
      await attachPlatformView(tester);
      controller.addActivityListener(receivedEvents.add);

      await messenger.handlePlatformMessage(
        'native_video_player_$platformViewId',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'play',
          'position': 0,
        }),
        (ByteData? data) {},
      );
      await tester.pump();

      expect(receivedEvents.length, equals(1));
      expect(receivedEvents.first.state, equals(PlayerActivityState.playing));
    });
  });
}

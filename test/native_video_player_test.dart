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

  /// Records every command sent over the shared MethodChannel so tests can
  /// assert the Dart→native wire contract (e.g. that setQuality forwards
  /// width/height/bitrate, which the native quality-capping fix relies on).
  final List<MethodCall> methodCalls = <MethodCall>[];

  void installMocks() {
    messenger.setMockMethodCallHandler(methodChannel, (
      MethodCall methodCall,
    ) async {
      methodCalls.add(methodCall);
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
    methodCalls.clear();
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

    testWidgets('setQuality forwards width/height/bitrate to native', (
      tester,
    ) async {
      // The native quality fix caps the video track using these fields
      // (preferredMaximumResolution / setMaxVideoSize + bitrate), so they
      // MUST reach native. Resolution-style labels ("1920x1080") are what the
      // native HLS parsers emit, and fromMap parses width/height from them.
      await attachPlatformView(tester);
      await controller.load(url: 'https://example.com/video.m3u8');

      final quality = NativeVideoPlayerQuality.fromMap(<String, dynamic>{
        'label': '1920x1080',
        'url': 'https://example.com/video_1080p.m3u8',
        'bitrate': 5000000,
        'isAuto': false,
      });
      await controller.setQuality(quality);

      final setCall = methodCalls.lastWhere((c) => c.method == 'setQuality');
      final sent = (setCall.arguments as Map)['quality'] as Map;
      expect(sent['width'], equals(1920));
      expect(sent['height'], equals(1080));
      expect(sent['bitrate'], equals(5000000));
      expect(sent['isAuto'], isFalse);
    });

    testWidgets('setQuality(auto) forwards isAuto:true to native', (
      tester,
    ) async {
      await attachPlatformView(tester);
      await controller.load(url: 'https://example.com/video.m3u8');

      await controller.setQuality(NativeVideoPlayerQuality.auto());

      final setCall = methodCalls.lastWhere((c) => c.method == 'setQuality');
      final sent = (setCall.arguments as Map)['quality'] as Map;
      expect(sent['isAuto'], isTrue);
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

    testWidgets(
      'emits selected quality from a flat native qualityChange event',
      (tester) async {
        await attachPlatformView(tester);

        // Native sends the selected quality's fields flat in the event map
        // (url/label/isAuto) — regression test for qualityChangedStream staying
        // silent when the handler only accepted a nested 'quality' key.
        final next = controller.qualityChangedStream.first.timeout(
          const Duration(seconds: 3),
        );

        await messenger.handlePlatformMessage(
          'native_video_player_$platformViewId',
          const StandardMethodCodec().encodeSuccessEnvelope({
            'event': 'qualityChange',
            'url': 'https://example.com/video_720p.m3u8',
            'label': '720p',
            'isAuto': false,
          }),
          (ByteData? data) {},
        );
        await tester.pump();

        final quality = await next;
        expect(quality.label, equals('720p'));
        expect(quality.isAuto, isFalse);
      },
    );

    testWidgets('emits Auto from a flat native qualityChange event', (
      tester,
    ) async {
      await attachPlatformView(tester);

      final next = controller.qualityChangedStream.first.timeout(
        const Duration(seconds: 3),
      );

      await messenger.handlePlatformMessage(
        'native_video_player_$platformViewId',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'qualityChange',
          'url': '',
          'label': 'Auto',
          'isAuto': true,
        }),
        (ByteData? data) {},
      );
      await tester.pump();

      final quality = await next;
      expect(quality.label, equals('Auto'));
      expect(quality.isAuto, isTrue);
    });

    testWidgets('emits selected quality from a nested qualityChange event', (
      tester,
    ) async {
      // Backward compatibility: synthetic control events nest the quality under
      // a 'quality' key. The handler must still accept that shape.
      await attachPlatformView(tester);

      final next = controller.qualityChangedStream.first.timeout(
        const Duration(seconds: 3),
      );

      await messenger.handlePlatformMessage(
        'native_video_player_$platformViewId',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'qualityChange',
          'quality': {
            'url': 'https://example.com/video_1080p.m3u8',
            'label': '1080p',
            'isAuto': false,
          },
        }),
        (ByteData? data) {},
      );
      await tester.pump();

      final quality = await next;
      expect(quality.label, equals('1080p'));
      expect(quality.isAuto, isFalse);
    });
  });

  group('NativeVideoPlayerQuality model', () {
    test('fromMap parses width/height from a resolution label', () {
      final q = NativeVideoPlayerQuality.fromMap(<String, dynamic>{
        'label': '1920x1080',
        'url': 'https://example.com/1080p.m3u8',
        'bitrate': 5000000,
        'isAuto': false,
      });
      expect(q.width, equals(1920));
      expect(q.height, equals(1080));
      expect(q.bitrate, equals(5000000));
      expect(q.isAuto, isFalse);
    });

    test('toMap carries the fields the native quality cap reads', () {
      final map = const NativeVideoPlayerQuality(
        label: '1280x720',
        url: 'https://example.com/720p.m3u8',
        bitrate: 2500000,
        width: 1280,
        height: 720,
      ).toMap();
      expect(map['width'], equals(1280));
      expect(map['height'], equals(720));
      expect(map['bitrate'], equals(2500000));
      expect(map['isAuto'], isFalse);
    });

    test('auto() is flagged isAuto', () {
      expect(NativeVideoPlayerQuality.auto().isAuto, isTrue);
    });
  });
}

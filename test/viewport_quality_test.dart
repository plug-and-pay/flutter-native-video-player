import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the viewport-based quality capping config
/// (NativeVideoPlayerConfig.qualityForViewportSize).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');

  setUp(() {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig();
    messenger.setMockMethodCallHandler(methodChannel, (call) async => null);
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_controller_77'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });

  tearDown(() {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig();
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  test('disabled by default and off in creationParams', () async {
    expect(NativeVideoPlayerConfig.global.qualityForViewportSize, isFalse);

    final controller = NativeVideoPlayerController(id: 77);
    expect(controller.creationParams['qualityForViewport'], isFalse);
    await controller.dispose();
  });

  test('enabled flag is plumbed into creationParams', () async {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      qualityForViewportSize: true,
    );

    final controller = NativeVideoPlayerController(id: 77);
    expect(controller.creationParams['qualityForViewport'], isTrue);
    await controller.dispose();
  });

  test('viewportCapHeadroom defaults to 1.5 and is plumbed when set', () async {
    expect(NativeVideoPlayerConfig.global.viewportCapHeadroom, 1.5);

    final byDefault = NativeVideoPlayerController(id: 77);
    expect(byDefault.creationParams['viewportCapHeadroom'], 1.5);
    await byDefault.dispose();

    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      qualityForViewportSize: true,
      viewportCapHeadroom: 1.0,
    );
    final lossy = NativeVideoPlayerController(id: 77);
    expect(lossy.creationParams['viewportCapHeadroom'], 1.0);
    await lossy.dispose();
  });

  test('config copy keeps other fields independent', () {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      maxConcurrentPlayingPlayers: 3,
      qualityForViewportSize: true,
    );
    expect(NativeVideoPlayerConfig.global.maxConcurrentPlayingPlayers, 3);
    expect(NativeVideoPlayerConfig.global.qualityForViewportSize, isTrue);
  });

  test(
    'prioritizeActivePlayback defaults off and is plumbed when set',
    () async {
      expect(NativeVideoPlayerConfig.global.prioritizeActivePlayback, isFalse);

      final off = NativeVideoPlayerController(id: 77);
      expect(off.creationParams['prioritizeActivePlayback'], isFalse);
      await off.dispose();

      NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
        prioritizeActivePlayback: true,
      );
      final on = NativeVideoPlayerController(id: 77);
      expect(on.creationParams['prioritizeActivePlayback'], isTrue);
      await on.dispose();
    },
  );

  test('lightweightInlineViews defaults off and is plumbed when set', () async {
    expect(NativeVideoPlayerConfig.global.lightweightInlineViews, isFalse);

    final off = NativeVideoPlayerController(id: 77);
    expect(off.creationParams['lightweightInlineViews'], isFalse);
    await off.dispose();

    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      lightweightInlineViews: true,
    );
    final on = NativeVideoPlayerController(id: 77);
    expect(on.creationParams['lightweightInlineViews'], isTrue);
    await on.dispose();
  });
}

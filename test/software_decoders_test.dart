import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the opt-in Android software-decoder mode
/// (NativeVideoPlayerConfig.androidForceSoftwareDecoders).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');

  setUp(() {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig();
    messenger.setMockMethodCallHandler(methodChannel, (call) async => null);
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_controller_88'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });

  tearDown(() {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig();
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  test('disabled by default and plumbed into creationParams', () async {
    expect(
      NativeVideoPlayerConfig.global.androidForceSoftwareDecoders,
      isFalse,
    );

    final off = NativeVideoPlayerController(id: 88);
    expect(off.creationParams['androidForceSoftwareDecoders'], isFalse);
    await off.dispose();

    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      androidForceSoftwareDecoders: true,
    );
    final on = NativeVideoPlayerController(id: 88);
    expect(on.creationParams['androidForceSoftwareDecoders'], isTrue);
    await on.dispose();
  });
}

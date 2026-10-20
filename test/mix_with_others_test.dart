import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the opt-in audio mixing with other apps
/// (NativeVideoPlayerController.mixWithOthers).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');

  setUp(() {
    messenger.setMockMethodCallHandler(methodChannel, (call) async => null);
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_controller_89'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  test('disabled by default and plumbed into creationParams', () async {
    final off = NativeVideoPlayerController(id: 89);
    expect(off.mixWithOthers, isFalse);
    expect(off.creationParams['mixWithOthers'], isFalse);
    await off.dispose();

    final on = NativeVideoPlayerController(id: 89, mixWithOthers: true);
    expect(on.creationParams['mixWithOthers'], isTrue);
    await on.dispose();
  });
}

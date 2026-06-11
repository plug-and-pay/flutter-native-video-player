import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the Android texture rendering config
/// (NativeVideoPlayerConfig.androidTextureMode) and the videoSize model.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig();
  });

  tearDown(() {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig();
  });

  test('androidTextureMode defaults off', () {
    expect(NativeVideoPlayerConfig.global.androidTextureMode, isFalse);

    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      androidTextureMode: true,
    );
    expect(NativeVideoPlayerConfig.global.androidTextureMode, isTrue);
  });

  test('NativeVideoPlayerVideoSize aspect ratio handles rotation', () {
    const landscape = NativeVideoPlayerVideoSize(width: 1920, height: 1080);
    expect(landscape.aspectRatio, closeTo(16 / 9, 0.001));

    const rotated = NativeVideoPlayerVideoSize(
      width: 1920,
      height: 1080,
      rotationCorrection: 90,
    );
    expect(rotated.aspectRatio, closeTo(9 / 16, 0.001));

    const upsideDown = NativeVideoPlayerVideoSize(
      width: 1280,
      height: 720,
      rotationCorrection: 180,
    );
    expect(upsideDown.aspectRatio, closeTo(16 / 9, 0.001));
  });
}

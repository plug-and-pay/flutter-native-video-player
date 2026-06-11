import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the opt-in Android disk cache config
/// (NativeVideoPlayerConfig.androidEnableDiskCache) and the
/// NativeVideoPlayerCache.precache entry point.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');
  final methodCalls = <MethodCall>[];

  setUp(() {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig();
    methodCalls.clear();
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      methodCalls.add(call);
      if (call.method == 'precacheVideo') return true;
      return null;
    });
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_controller_88'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });

  tearDown(() {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  test('disabled by default and plumbed into creationParams', () async {
    expect(NativeVideoPlayerConfig.global.androidEnableDiskCache, isFalse);

    final off = NativeVideoPlayerController(id: 88);
    expect(off.creationParams['androidEnableDiskCache'], isFalse);
    expect(off.creationParams['androidDiskCacheMaxBytes'], 100 * 1024 * 1024);
    await off.dispose();

    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      androidEnableDiskCache: true,
      androidDiskCacheMaxBytes: 5 * 1024 * 1024,
    );
    final on = NativeVideoPlayerController(id: 88);
    expect(on.creationParams['androidEnableDiskCache'], isTrue);
    expect(on.creationParams['androidDiskCacheMaxBytes'], 5 * 1024 * 1024);
    await on.dispose();
  });

  test('precache sends url, headers and budgets on Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      androidEnableDiskCache: true,
      androidPrecacheBytes: 1024,
      androidDiskCacheMaxBytes: 2048,
    );

    final ok = await NativeVideoPlayerCache.precache(
      'https://example.com/video.m3u8',
      headers: {'Referer': 'https://example.com'},
    );

    expect(ok, isTrue);
    expect(
      methodCalls,
      contains(
        isA<MethodCall>()
            .having((c) => c.method, 'method', 'precacheVideo')
            .having(
              (c) => c.arguments,
              'arguments',
              allOf(
                containsPair('url', 'https://example.com/video.m3u8'),
                containsPair('headers', {'Referer': 'https://example.com'}),
                containsPair('precacheBytes', 1024),
                containsPair('cacheMaxBytes', 2048),
              ),
            ),
      ),
    );
  });

  test('precache maxBytes overrides the config budget', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      androidEnableDiskCache: true,
    );

    await NativeVideoPlayerCache.precache(
      'https://example.com/clip.mp4',
      maxBytes: 9999,
    );

    expect(
      methodCalls,
      contains(
        isA<MethodCall>()
            .having((c) => c.method, 'method', 'precacheVideo')
            .having(
              (c) => c.arguments,
              'arguments',
              containsPair('precacheBytes', 9999),
            ),
      ),
    );
  });

  test('precache is gated: flag off or non-Android makes no call', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final flagOff = await NativeVideoPlayerCache.precache(
      'https://example.com/video.m3u8',
    );
    expect(flagOff, isFalse);
    expect(methodCalls, isEmpty);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      androidEnableDiskCache: true,
    );
    final wrongPlatform = await NativeVideoPlayerCache.precache(
      'https://example.com/video.m3u8',
    );
    expect(wrongPlatform, isFalse);
    expect(methodCalls, isEmpty);
  });
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:better_native_video_player/src/models/native_video_player_media_info.dart';
import 'package:better_native_video_player/src/models/native_video_player_quality.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('native_video_player');
  final List<MethodCall> methodCalls = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          methodCalls.add(methodCall);
          switch (methodCall.method) {
            case 'load':
              return null;
            case 'play':
              return null;
            case 'pause':
              return null;
            case 'seekTo':
              return null;
            case 'setVolume':
              return null;
            case 'setSpeed':
              return null;
            case 'setEmbeddedTextScale':
              return null;
            case 'setQuality':
              return null;
            case 'getAvailableQualities':
              return [
                {
                  'label': '1080p',
                  'url': 'https://example.com/video_1080p.m3u8',
                },
                {'label': '720p', 'url': 'https://example.com/video_720p.m3u8'},
              ];
            case 'enterFullScreen':
              return null;
            case 'exitFullScreen':
              return null;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    methodCalls.clear();
  });

  test('load method sends correct parameters', () async {
    const String url = 'https://example.com/video.m3u8';
    final Map<String, String> headers = {'Referer': 'https://example.com'};
    final NativeVideoPlayerMediaInfo mediaInfo = NativeVideoPlayerMediaInfo(
      title: 'Test Video',
      subtitle: 'Test Subtitle',
      artworkUrl: 'https://example.com/artwork.jpg',
    );

    await channel.invokeMethod<void>('load', {
      'url': url,
      'headers': headers,
      'mediaInfo': mediaInfo.toMap(),
      'viewId': 1,
      'autoPlay': true,
    });

    expect(
      methodCalls,
      contains(
        isA<MethodCall>()
            .having((c) => c.method, 'method', 'load')
            .having((c) => c.arguments, 'arguments', containsPair('url', url)),
      ),
    );
  });

  test('play method is called correctly', () async {
    await channel.invokeMethod<void>('play');
    expect(
      methodCalls,
      contains(isA<MethodCall>().having((c) => c.method, 'method', 'play')),
    );
  });

  test('pause method is called correctly', () async {
    await channel.invokeMethod<void>('pause');
    expect(
      methodCalls,
      contains(isA<MethodCall>().having((c) => c.method, 'method', 'pause')),
    );
  });

  test('seekTo method sends correct position', () async {
    const int position = 30000; // 30 seconds in milliseconds
    await channel.invokeMethod<void>('seekTo', position);
    expect(
      methodCalls,
      contains(
        isA<MethodCall>()
            .having((c) => c.method, 'method', 'seekTo')
            .having((c) => c.arguments, 'arguments', position),
      ),
    );
  });

  test('setVolume method sends correct value', () async {
    const double volume = 0.5;
    await channel.invokeMethod<void>('setVolume', volume);
    expect(
      methodCalls,
      contains(
        isA<MethodCall>()
            .having((c) => c.method, 'method', 'setVolume')
            .having((c) => c.arguments, 'arguments', volume),
      ),
    );
  });

  test('setSpeed method sends correct value', () async {
    const double speed = 1.5;
    await channel.invokeMethod<void>('setSpeed', speed);
    expect(
      methodCalls,
      contains(
        isA<MethodCall>()
            .having((c) => c.method, 'method', 'setSpeed')
            .having((c) => c.arguments, 'arguments', speed),
      ),
    );
  });

  test('setEmbeddedTextScale method sends correct value', () async {
    const double scale = 1.5;
    await channel.invokeMethod<void>('setEmbeddedTextScale', {
      'viewId': 1,
      'scale': scale,
    });
    expect(
      methodCalls,
      contains(
        isA<MethodCall>()
            .having((c) => c.method, 'method', 'setEmbeddedTextScale')
            .having(
              (c) => c.arguments,
              'arguments',
              containsPair('scale', scale),
            ),
      ),
    );
  });

  test('setQuality method sends correct quality', () async {
    final NativeVideoPlayerQuality quality = NativeVideoPlayerQuality(
      label: '1080p',
      url: 'https://example.com/video_1080p.m3u8',
    );
    await channel.invokeMethod<void>('setQuality', quality.toMap());
    expect(
      methodCalls,
      contains(
        isA<MethodCall>()
            .having((c) => c.method, 'method', 'setQuality')
            .having((c) => c.arguments, 'arguments', quality.toMap()),
      ),
    );
  });

  test('getAvailableQualities returns correct list', () async {
    final List<dynamic>? result = await channel.invokeMethod<List<dynamic>>(
      'getAvailableQualities',
    );
    expect(result, isNotNull);
    expect(result!.length, equals(2));
    expect(result.first, containsPair('label', '1080p'));
    expect(result.last, containsPair('label', '720p'));
  });

  test('enterFullScreen sends correct viewId', () async {
    const int viewId = 1;
    await channel.invokeMethod<void>('enterFullScreen', {'viewId': viewId});
    expect(
      methodCalls,
      contains(
        isA<MethodCall>()
            .having((c) => c.method, 'method', 'enterFullScreen')
            .having(
              (c) => c.arguments,
              'arguments',
              containsPair('viewId', viewId),
            ),
      ),
    );
  });

  test('exitFullScreen sends correct viewId', () async {
    const int viewId = 1;
    await channel.invokeMethod<void>('exitFullScreen', {'viewId': viewId});
    expect(
      methodCalls,
      contains(
        isA<MethodCall>()
            .having((c) => c.method, 'method', 'exitFullScreen')
            .having(
              (c) => c.arguments,
              'arguments',
              containsPair('viewId', viewId),
            ),
      ),
    );
  });
}

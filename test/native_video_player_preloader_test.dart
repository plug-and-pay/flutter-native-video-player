import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<List<String>> sent = <List<String>>[];
  final List<Map<String, String>?> sentHeaders = <Map<String, String>?>[];

  setUp(() {
    sent.clear();
    sentHeaders.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('native_video_player'), (
          MethodCall call,
        ) async {
          if (call.method == 'setPreloadWindow') {
            final List<dynamic> items =
                (call.arguments as Map<dynamic, dynamic>)['items']
                    as List<dynamic>;
            sent.add(
              items
                  .map(
                    (dynamic i) =>
                        (i as Map<dynamic, dynamic>)['url'] as String,
                  )
                  .toList(),
            );
            for (final dynamic i in items) {
              final Map<dynamic, dynamic>? h =
                  (i as Map<dynamic, dynamic>)['headers']
                      as Map<dynamic, dynamic>?;
              sentHeaders.add(h?.cast<String, String>());
            }
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('native_video_player'),
          null,
        );
  });

  List<NativeVideoPlayerPreloadItem> items(
    int n, {
    Set<int> drm = const <int>{},
  }) => List<NativeVideoPlayerPreloadItem>.generate(
    n,
    (int i) => NativeVideoPlayerPreloadItem(
      url: 'https://x/$i.m3u8',
      isDrm: drm.contains(i),
    ),
  );

  List<String> urls(List<NativeVideoPlayerPreloadItem> w) =>
      w.map((NativeVideoPlayerPreloadItem i) => i.url).toList();

  test('window is the next two, then the previous one', () {
    final NativeVideoPlayerPreloader p = NativeVideoPlayerPreloader();
    expect(urls(p.windowFor(items(10), 5)), <String>[
      'https://x/6.m3u8',
      'https://x/7.m3u8',
      'https://x/4.m3u8',
    ]);
  });

  test('window is clipped at both ends of the list', () {
    final NativeVideoPlayerPreloader p = NativeVideoPlayerPreloader();
    expect(urls(p.windowFor(items(10), 0)), <String>[
      'https://x/1.m3u8',
      'https://x/2.m3u8',
    ]);
    expect(urls(p.windowFor(items(10), 9)), <String>['https://x/8.m3u8']);
    expect(p.windowFor(const <NativeVideoPlayerPreloadItem>[], 3), isEmpty);
  });

  test('DRM items and the current URL are never preloaded', () {
    final NativeVideoPlayerPreloader p = NativeVideoPlayerPreloader();
    expect(urls(p.windowFor(items(10, drm: <int>{6}), 5)), <String>[
      'https://x/7.m3u8',
      'https://x/4.m3u8',
    ]);
    final List<NativeVideoPlayerPreloadItem> repeated =
        <NativeVideoPlayerPreloadItem>[
          const NativeVideoPlayerPreloadItem(url: 'a'),
          const NativeVideoPlayerPreloadItem(url: 'a'),
          const NativeVideoPlayerPreloadItem(url: 'b'),
        ];
    expect(urls(p.windowFor(repeated, 0)), <String>['b']);
  });

  test('the window moves with swipes and only changes are sent', () async {
    final NativeVideoPlayerPreloader p = NativeVideoPlayerPreloader();
    final List<NativeVideoPlayerPreloadItem> list = items(10);
    await p.setWindow(list, 0);
    await p.setWindow(list, 0); // unchanged: no call
    await p.setWindow(list, 1);
    expect(sent, <List<String>>[
      <String>['https://x/1.m3u8', 'https://x/2.m3u8'],
      <String>['https://x/2.m3u8', 'https://x/3.m3u8', 'https://x/0.m3u8'],
    ]);
  });

  test(
    'the window never holds more than three items over many swipes',
    () async {
      final NativeVideoPlayerPreloader p = NativeVideoPlayerPreloader();
      final List<NativeVideoPlayerPreloadItem> list = items(60);
      for (int i = 0; i < 50; i++) {
        await p.setWindow(list, i);
        expect(
          p.window.length,
          lessThanOrEqualTo(NativeVideoPlayerPreloader.maxWindow),
        );
      }
      expect(sent.every((List<String> w) => w.length <= 3), isTrue);
    },
  );

  test('headers are passed to the platform', () async {
    final NativeVideoPlayerPreloader p = NativeVideoPlayerPreloader();
    await p.setWindow(const <NativeVideoPlayerPreloadItem>[
      NativeVideoPlayerPreloadItem(url: 'a'),
      NativeVideoPlayerPreloadItem(
        url: 'b',
        headers: <String, String>{'Authorization': 'Bearer t'},
      ),
    ], 0);
    expect(sentHeaders, <Map<String, String>?>[
      <String, String>{'Authorization': 'Bearer t'},
    ]);
  });

  test('dispose clears the native window and ignores later calls', () async {
    final NativeVideoPlayerPreloader p = NativeVideoPlayerPreloader();
    await p.setWindow(items(5), 0);
    await p.dispose();
    await p.setWindow(items(5), 2);
    expect(sent.last, isEmpty);
    expect(sent.length, 2);
  });

  test('a failing platform call does not throw', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('native_video_player'),
          (MethodCall call) async => throw PlatformException(code: 'x'),
        );
    final NativeVideoPlayerPreloader p = NativeVideoPlayerPreloader();
    await expectLater(p.setWindow(items(5), 0), completes);
  });

  test('items with equal URL and headers are equal', () {
    expect(
      const NativeVideoPlayerPreloadItem(
        url: 'a',
        headers: <String, String>{'k': 'v'},
      ),
      const NativeVideoPlayerPreloadItem(
        url: 'a',
        headers: <String, String>{'k': 'v'},
      ),
    );
    expect(
      const NativeVideoPlayerPreloadItem(
        url: 'a',
        headers: <String, String>{'k': 'v'},
      ),
      isNot(const NativeVideoPlayerPreloadItem(url: 'a')),
    );
  });
}

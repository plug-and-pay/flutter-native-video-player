import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// One controller shown on two screens (a feed tile and the post page it
/// opens): Dart fullscreen must open from, fly out of and land back in the
/// view on the page on top, not the one still mounted underneath.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');

  late NativeVideoPlayerController controller;
  var testSeq = 0;
  late int controllerId;

  setUp(() {
    testSeq++;
    controllerId = 6600 + testSeq;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      return call.method == 'getAvailableQualities' ? <Object?>[] : null;
    });
  });

  tearDown(() async {
    await controller.dispose().timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  void mockChannels(List<int> viewIds) {
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_controller_$controllerId'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
    for (final viewId in viewIds) {
      messenger.setMockStreamHandler(
        EventChannel('native_video_player_$viewId'),
        MockStreamHandler.inline(onListen: (arguments, events) {}),
      );
    }
  }

  /// Page A with a player slot, then page B pushed on top with another.
  Future<(BuildContext, BuildContext)> pumpTwoPages(WidgetTester tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox(key: ValueKey('feed-tile'))),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const Scaffold(body: SizedBox(key: ValueKey('post-player'))),
      ),
    );
    await tester.pumpAndSettle();
    return (
      tester.element(
        find.byKey(const ValueKey('feed-tile'), skipOffstage: false),
      ),
      tester.element(find.byKey(const ValueKey('post-player'))),
    );
  }

  testWidgets('the view on the page on top wins over the earlier one', (
    tester,
  ) async {
    final feedView = 7700 + testSeq * 10, postView = feedView + 1;
    mockChannels([feedView, postView]);
    controller = NativeVideoPlayerController(id: controllerId);
    final (feedContext, postContext) = await pumpTwoPages(tester);

    // The feed tile attached first, as it does in an app.
    await controller.onPlatformViewCreated(feedView, feedContext);
    await controller.onPlatformViewCreated(postView, postContext);
    await tester.pump(const Duration(milliseconds: 100));

    expect(identical(controller.debugFullscreenContext, postContext), isTrue);
  });

  testWidgets('the top page wins even when its view attached first', (
    tester,
  ) async {
    final feedView = 7700 + testSeq * 10, postView = feedView + 1;
    mockChannels([feedView, postView]);
    controller = NativeVideoPlayerController(id: controllerId);
    final (feedContext, postContext) = await pumpTwoPages(tester);

    // Android creates a covered page's view late, so order isn't reliable.
    await controller.onPlatformViewCreated(postView, postContext);
    await controller.onPlatformViewCreated(feedView, feedContext);
    await tester.pump(const Duration(milliseconds: 100));

    expect(identical(controller.debugFullscreenContext, postContext), isTrue);
  });

  testWidgets('back on the first page, its own view is used again', (
    tester,
  ) async {
    final feedView = 7700 + testSeq * 10, postView = feedView + 1;
    mockChannels([feedView, postView]);
    controller = NativeVideoPlayerController(id: controllerId);
    final (feedContext, postContext) = await pumpTwoPages(tester);
    await controller.onPlatformViewCreated(feedView, feedContext);
    await controller.onPlatformViewCreated(postView, postContext);
    await tester.pump(const Duration(milliseconds: 100));

    // Leaving the post disposes its view.
    Navigator.of(postContext).pop();
    await tester.pumpAndSettle();
    controller.onPlatformViewDisposed(postView);

    expect(identical(controller.debugFullscreenContext, feedContext), isTrue);
  });
}

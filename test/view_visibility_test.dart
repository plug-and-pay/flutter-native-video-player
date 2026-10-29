import 'package:better_native_video_player/src/platform/view_visibility.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A closing PiP window only flies back into a fully visible player (iOS):
/// the native side asks over `native_video_player/visibility`, and the
/// widget answers from the clips it is painted under.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ScrollController scroll = ScrollController();
  const GlobalObjectKey tile = GlobalObjectKey('tile');

  Future<void> pumpFeed(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Feed')),
          body: ListView(
            controller: scroll,
            children: [
              const SizedBox(height: 300),
              SizedBox(key: tile, height: 200),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
  }

  bool visible() => ViewVisibility.isFullyVisible(tile.currentContext!);

  testWidgets('a tile on screen is fully visible', (tester) async {
    await pumpFeed(tester);
    expect(visible(), isTrue);
  });

  testWidgets('a tile half under the app bar is not', (tester) async {
    await pumpFeed(tester);
    scroll.jumpTo(400);
    await tester.pump();
    expect(visible(), isFalse);
  });

  testWidgets('a tile scrolled off screen but still built is not', (
    tester,
  ) async {
    await pumpFeed(tester);
    scroll.jumpTo(550);
    await tester.pump();
    expect(tile.currentContext, isNotNull);
    expect(visible(), isFalse);
  });

  testWidgets('a tile cut off at the bottom of the screen is not', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          children: [
            const SizedBox(height: 500),
            SizedBox(key: tile, height: 200),
          ],
        ),
      ),
    );
    expect(visible(), isFalse);
  });

  testWidgets('answers the native query by view id', (tester) async {
    await pumpFeed(tester);
    ViewVisibility.register(7, tile.currentContext!, controllerId: 70);

    Future<Object?> ask(int viewId) async {
      final ByteData? reply = await tester.binding.defaultBinaryMessenger
          .handlePlatformMessage(
            'native_video_player/visibility',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('isViewFullyVisible', <String, Object?>{
                'viewId': viewId,
              }),
            ),
            null,
          );
      return const StandardMethodCodec().decodeEnvelope(reply!);
    }

    expect(await ask(7), isTrue);
    expect(await ask(8), isFalse);

    ViewVisibility.unregister(7, tile.currentContext!);
    expect(await ask(7), isFalse);
  });
}

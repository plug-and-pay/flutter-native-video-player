import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('HLS qualities reach controller.qualities', (tester) async {
    final controller = NativeVideoPlayerController(id: 7, autoPlay: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NativeVideoPlayer(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    await controller.initialize();
    await controller.load(
      url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    );
    // ignore: avoid_print
    print(
      'QUALITIES_AFTER_LOAD=${controller.qualities.map((q) => q.label).toList()}',
    );

    for (var i = 0; i < 40 && controller.qualities.length <= 1; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    // ignore: avoid_print
    print(
      'QUALITIES_LATER=${controller.qualities.map((q) => q.label).toList()}',
    );
    expect(controller.qualities.length, greaterThan(2));
    await controller.dispose();
  });
}

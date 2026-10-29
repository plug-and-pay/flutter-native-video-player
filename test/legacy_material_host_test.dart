import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart' as legacy;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The player is built on `material_ui`, but apps still on the SDK's
/// `package:flutter/material.dart` must keep working: their theme colours the
/// progress bar and their ink widgets work in Dart fullscreen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');
  const controllerId = 9100;

  const Color hostPrimary = Color(0xFF00AA55);
  const Color hostActiveTrack = Color(0xFFAA0055);

  setUp(() {
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      return call.method == 'getAvailableQualities' ? <Object?>[] : null;
    });
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_controller_$controllerId'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });

  tearDown(() => messenger.setMockMethodCallHandler(methodChannel, null));

  Widget progressBar() => const NativeVideoPlayerProgressBar(
    position: Duration(seconds: 10),
    duration: Duration(seconds: 60),
  );

  Color playedColorOf(WidgetTester tester) {
    final CustomPaint chapterBar = tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(NativeVideoPlayerProgressBar),
            matching: find.byType(CustomPaint),
          ),
        )
        .firstWhere(
          (CustomPaint paint) =>
              paint.painter.runtimeType.toString() == '_ChapterBarPainter',
        );
    return (chapterBar.painter as dynamic).playedColor as Color;
  }

  Widget overlayWithInk(BuildContext context, NativeVideoPlayerController _) =>
      Align(
        child: legacy.InkWell(
          onTap: () {},
          child: const SizedBox.square(dimension: 48),
        ),
      );

  group('app on the SDK Material library', () {
    testWidgets('the progress bar takes the SDK slider theme', (tester) async {
      await tester.pumpWidget(
        legacy.MaterialApp(
          theme: legacy.ThemeData(
            colorScheme: const legacy.ColorScheme.light(primary: hostPrimary),
            sliderTheme: const legacy.SliderThemeData(
              activeTrackColor: hostActiveTrack,
            ),
          ),
          home: legacy.Scaffold(body: progressBar()),
        ),
      );

      expect(playedColorOf(tester), hostActiveTrack);
    });

    testWidgets('the progress bar falls back to the SDK primary', (
      tester,
    ) async {
      await tester.pumpWidget(
        legacy.MaterialApp(
          theme: legacy.ThemeData(
            colorScheme: const legacy.ColorScheme.light(primary: hostPrimary),
          ),
          home: legacy.Scaffold(body: progressBar()),
        ),
      );

      expect(playedColorOf(tester), hostPrimary);
    });

    testWidgets('SDK ink widgets work in Dart fullscreen', (tester) async {
      final controller = NativeVideoPlayerController(id: controllerId);
      addTearDown(
        () => controller.dispose().timeout(
          const Duration(seconds: 1),
          onTimeout: () {},
        ),
      );

      await tester.pumpWidget(
        legacy.MaterialApp(
          home: FullscreenVideoPlayer(
            controller: controller,
            overlayBuilder: overlayWithInk,
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(legacy.InkWell), findsOneWidget);
    });
  });

  group('app on material_ui', () {
    testWidgets('the progress bar takes the material_ui slider theme', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: const ColorScheme.light(primary: hostPrimary),
            sliderTheme: const SliderThemeData(
              activeTrackColor: hostActiveTrack,
            ),
          ),
          home: Scaffold(body: progressBar()),
        ),
      );

      expect(playedColorOf(tester), hostActiveTrack);
    });

    testWidgets('material_ui ink widgets work in Dart fullscreen', (
      tester,
    ) async {
      final controller = NativeVideoPlayerController(id: controllerId);
      addTearDown(
        () => controller.dispose().timeout(
          const Duration(seconds: 1),
          onTimeout: () {},
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: FullscreenVideoPlayer(
            controller: controller,
            overlayBuilder: (context, _) => Align(
              child: InkWell(
                onTap: () {},
                child: const SizedBox.square(dimension: 48),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(InkWell), findsOneWidget);
    });
  });

  testWidgets('an app with the compatibility bridge reads material_ui', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: const ColorScheme.light(primary: hostPrimary),
        ),
        builder: (context, child) =>
            // ignore: deprecated_member_use
            MaterialUiCompatibilityBridge(child: child!),
        home: Scaffold(body: progressBar()),
      ),
    );

    expect(playedColorOf(tester), hostPrimary);
  });
}

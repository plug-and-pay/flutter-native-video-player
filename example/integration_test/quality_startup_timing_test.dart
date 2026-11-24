import 'dart:convert';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Startup timing on a real device or simulator: from `load()` until the
/// player is ready, until playback has advanced (first frames shown), and
/// until the quality list has arrived. Prints one JSON line per run
/// (`TIMING {...}`); compare medians across builds.
///
/// `flutter test integration_test/quality_startup_timing_test.dart -d DEVICE_ID`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const Map<String, String> streams = <String, String>{
    'mux-x36xhzz': 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    // Signed variant URLs (?cdn=…&expires=…&signature=…) and a separate
    // audio group, like Vimeo and Bunny token URLs.
    'mux-signed':
        'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
  };
  const int runsPerStream = 10;

  int controllerId = 900;

  for (final MapEntry<String, String> stream in streams.entries) {
    testWidgets('startup timing: ${stream.key}', (tester) async {
      for (int run = 0; run < runsPerStream; run++) {
        final NativeVideoPlayerController controller =
            NativeVideoPlayerController(id: controllerId++, autoPlay: true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: NativeVideoPlayer(controller: controller)),
          ),
        );
        await tester.pumpAndSettle();
        await controller.initialize();

        final Stopwatch stopwatch = Stopwatch()..start();
        int? readyMs, playingMs, qualitiesMs;
        int? qualitiesAtReady;

        final Future<void> loading = controller.load(url: stream.value);

        while (stopwatch.elapsedMilliseconds < 15000 &&
            (readyMs == null || playingMs == null || qualitiesMs == null)) {
          final PlayerActivityState state = controller.activityState;
          if (readyMs == null &&
              (state == PlayerActivityState.loaded ||
                  state == PlayerActivityState.playing)) {
            readyMs = stopwatch.elapsedMilliseconds;
            qualitiesAtReady = controller.qualities.length;
          }

          if (playingMs == null && controller.currentPosition > Duration.zero) {
            playingMs = stopwatch.elapsedMilliseconds;
          }

          if (qualitiesMs == null && controller.qualities.length > 1) {
            qualitiesMs = stopwatch.elapsedMilliseconds;
          }

          await tester.pump(const Duration(milliseconds: 10));
        }

        await loading;
        // ignore: avoid_print
        print(
          'TIMING ${jsonEncode(<String, Object?>{'stream': stream.key, 'run': run, 'readyMs': readyMs, 'playingMs': playingMs, 'qualitiesMs': qualitiesMs, 'qualitiesAtReady': qualitiesAtReady, 'qualities': controller.qualities.map((q) => q.label).toList()})}',
        );
        expect(controller.qualities.length, greaterThan(1));

        await controller.dispose();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    });
  }
}

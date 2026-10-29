import 'package:better_native_video_player/src/platform/pip_restore.dart';
import 'package:better_native_video_player/src/platform/view_visibility.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The PiP window's "back to app" button (iOS): the native side asks over
/// `native_video_player/pip`, the app's handler opens the video's screen,
/// and the answer comes once a player of the controller is fully visible,
/// so the window flies into it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const int controllerId = 42;
  final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();

  /// Stands in for a NativeVideoPlayer: registers itself like the widget's
  /// platform view does.
  Widget player(int viewId) => Builder(
    builder: (BuildContext context) {
      ViewVisibility.register(viewId, context, controllerId: controllerId);
      return const SizedBox(height: 200);
    },
  );

  Future<void> pumpApp(WidgetTester tester, {required Widget home}) =>
      tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: home));

  /// Sends the native side's request; resolves with Dart's answer.
  Future<Object?> requestRestore(WidgetTester tester) async {
    final ByteData? reply = await tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(
          'native_video_player/pip',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('restoreUserInterface', <String, Object?>{
              'controllerId': controllerId,
            }),
          ),
          null,
        );
    return const StandardMethodCodec().decodeEnvelope(reply!);
  }

  tearDown(() => PipRestore.setHandler(controllerId, null));

  testWidgets('a player under a pushed page is not fully visible', (
    tester,
  ) async {
    await pumpApp(tester, home: Scaffold(body: player(1)));
    expect(ViewVisibility.isControllerFullyVisible(controllerId), isTrue);

    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(ViewVisibility.isControllerFullyVisible(controllerId), isFalse);
  });

  testWidgets('without a handler the answer is false right away', (
    tester,
  ) async {
    await pumpApp(tester, home: Scaffold(body: player(1)));
    // Another controller's handler installs the channel handler.
    PipRestore.setHandler(controllerId + 1, () {});
    expect(await requestRestore(tester), isFalse);
    PipRestore.setHandler(controllerId + 1, null);
  });

  testWidgets('the answer waits until the opened screen shows the player', (
    tester,
  ) async {
    await pumpApp(tester, home: const Scaffold());
    var calls = 0;
    PipRestore.setHandler(controllerId, () {
      calls++;
      // Not awaited: a push completes when the route is popped.
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => Scaffold(body: player(2))),
      );
    });

    Object? answer = 'pending';
    requestRestore(tester).then((Object? value) => answer = value);
    await tester.pump();
    expect(calls, 1);
    // Mid-transition the page is still sliding in.
    await tester.pump(const Duration(milliseconds: 100));
    expect(answer, 'pending');

    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  testWidgets('without a visible player the answer is false after the wait', (
    tester,
  ) async {
    await pumpApp(tester, home: const Scaffold());
    PipRestore.setHandler(controllerId, () {});

    Object? answer = 'pending';
    requestRestore(tester).then((Object? value) => answer = value);
    await tester.pump();
    await tester.pump(PipRestore.visibleTimeout);
    await tester.pump(const Duration(milliseconds: 50));
    expect(answer, isFalse);
  });

  testWidgets('clearHandler leaves a newer handler in place', (tester) async {
    await pumpApp(tester, home: Scaffold(body: player(1)));
    void first() {}
    void second() {}
    PipRestore.setHandler(controllerId, first);
    PipRestore.setHandler(controllerId, second);
    PipRestore.clearHandler(controllerId, first);
    expect(await requestRestore(tester), isTrue);
  });
}

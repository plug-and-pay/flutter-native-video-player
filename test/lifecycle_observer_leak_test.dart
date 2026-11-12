import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// On Android every controller registers an app-lifecycle observer (to hide
/// the overlay before automatic PiP). Before 1.9.0 it was never removed, so
/// the binding kept every controller ever created alive and kept calling
/// into disposed ones.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    NativeVideoPlayerController.debugUseAndroidLifecycleObserver = true;
    messenger.setMockMethodCallHandler(
      const MethodChannel('native_video_player'),
      (call) async => null,
    );
  });

  tearDown(() {
    NativeVideoPlayerController.debugUseAndroidLifecycleObserver = null;
    messenger.setMockMethodCallHandler(
      const MethodChannel('native_video_player'),
      null,
    );
  });

  test('dispose removes the lifecycle observer', () async {
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_controller_501'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
    final controller = NativeVideoPlayerController(id: 501);
    expect(controller.debugHasLifecycleObserver, isTrue);

    await controller.dispose();

    expect(controller.debugHasLifecycleObserver, isFalse);
  });

  test(
    'a lifecycle change after dispose does not reach the controller',
    () async {
      messenger.setMockStreamHandler(
        const EventChannel('native_video_player_controller_502'),
        MockStreamHandler.inline(onListen: (arguments, events) {}),
      );
      final controller = NativeVideoPlayerController(id: 502);
      await controller.dispose();

      // Would throw "Cannot add new events after calling close" if a disposed
      // controller still received lifecycle callbacks.
      TestWidgetsFlutterBinding.instance
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
}

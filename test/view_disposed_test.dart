import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart side must notify the native side when a platform view is
/// disposed: on iOS the per-view EventChannel handler strongly retains the
/// native view, and the `viewDisposed` call is what releases it so the view
/// can deallocate.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');
  final methodCalls = <MethodCall>[];

  setUp(() {
    methodCalls.clear();
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      methodCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  test(
    'onPlatformViewDisposed notifies the native side with the viewId',
    () async {
      messenger.setMockStreamHandler(
        const EventChannel('native_video_player_controller_91'),
        MockStreamHandler.inline(onListen: (arguments, events) {}),
      );
      final controller = NativeVideoPlayerController(id: 91);

      controller.onPlatformViewDisposed(417);

      // The notification is sequenced after the event-subscription cancel;
      // give the microtask chain and channel roundtrip a beat to complete.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        methodCalls,
        contains(
          isA<MethodCall>()
              .having((c) => c.method, 'method', 'viewDisposed')
              .having(
                (c) => c.arguments,
                'arguments',
                containsPair('viewId', 417),
              ),
        ),
      );

      await controller.dispose();
    },
  );
}

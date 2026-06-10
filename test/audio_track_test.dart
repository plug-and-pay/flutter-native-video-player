import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Audio track selection (issues #23/#16) against a mocked platform side.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');

  late List<MethodCall> calls;
  late NativeVideoPlayerController controller;

  setUp(() {
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getAvailableAudioTracks':
          return [
            {
              'index': 0,
              'language': 'en',
              'displayName': 'English',
              'isSelected': true,
            },
            {
              'index': 1,
              'language': 'en',
              'displayName': 'English (audio description)',
              'isSelected': false,
            },
            {
              'index': 2,
              'language': 'nl',
              'displayName': 'Nederlands',
              'isSelected': false,
            },
          ];
        case 'getAvailableQualities':
          return <Object?>[];
        default:
          return null;
      }
    });
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_controller_88'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
    messenger.setMockStreamHandler(
      const EventChannel('native_video_player_101'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
    controller = NativeVideoPlayerController(id: 88);
  });

  tearDown(() async {
    await controller.dispose();
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  Future<void> attachView(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    final BuildContext context = tester.element(find.byType(SizedBox));
    await controller.onPlatformViewCreated(101, context);
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('getAvailableAudioTracks parses the platform list', (
    tester,
  ) async {
    await attachView(tester);
    final tracks = await controller.getAvailableAudioTracks();

    expect(tracks, hasLength(3));
    expect(tracks[0].isSelected, isTrue);
    expect(tracks[1].displayName, 'English (audio description)');
    expect(tracks[1].language, 'en');
    expect(tracks[2].language, 'nl');
  });

  testWidgets('setAudioTrack sends the track map with the view id', (
    tester,
  ) async {
    await attachView(tester);
    await controller.setAudioTrack(
      const NativeVideoPlayerAudioTrack(
        index: 2,
        language: 'nl',
        displayName: 'Nederlands',
      ),
    );

    final call = calls.lastWhere((c) => c.method == 'setAudioTrack');
    final args = call.arguments as Map<dynamic, dynamic>;
    expect(args['viewId'], 101);
    expect((args['track'] as Map<dynamic, dynamic>)['index'], 2);
  });

  test('without a platform view the API degrades gracefully', () async {
    expect(await controller.getAvailableAudioTracks(), isEmpty);
    // No throw expected:
    await controller.setAudioTrack(
      const NativeVideoPlayerAudioTrack(
        index: 0,
        language: 'en',
        displayName: 'English',
      ),
    );
  });
}

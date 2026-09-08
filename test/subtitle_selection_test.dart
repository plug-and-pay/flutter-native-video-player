import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app's subtitle choice must survive a new platform view attaching to
/// the shared player (Dart fullscreen host, second inline view): the
/// controller re-sends its last `setSubtitleTrack` to the platform, and the
/// track payload round-trips `source` so listeners can tell sidecar and
/// embedded selections apart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');

  late List<MethodCall> calls;
  NativeVideoPlayerController? controller;

  var testSeq = 0;
  late int controllerId;
  late int viewId;

  setUp(() {
    testSeq++;
    controllerId = 8800 + testSeq;
    viewId = 9900 + testSeq * 2;
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getAvailableQualities':
          return <Object?>[];
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    await controller?.dispose().timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  Future<void> attachView(WidgetTester tester, int id) async {
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_$id'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
    final BuildContext context = tester.element(find.byType(SizedBox));
    await controller!.onPlatformViewCreated(id, context);
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> createController(WidgetTester tester) async {
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_controller_$controllerId'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
    controller = NativeVideoPlayerController(id: controllerId);
    await tester.pumpWidget(const SizedBox());
    await attachView(tester, viewId);
  }

  List<MethodCall> subtitleCalls() =>
      calls.where((c) => c.method == 'setSubtitleTrack').toList();

  int trackIndexOf(MethodCall call) =>
      ((call.arguments as Map)['track'] as Map)['index'] as int;

  group('NativeVideoPlayerSubtitleTrack payload', () {
    test('round-trips source', () {
      const track = NativeVideoPlayerSubtitleTrack(
        index: 1,
        language: 'nl',
        displayName: 'Nederlands',
        source: SubtitleTrackSource.sidecar,
      );

      final decoded = NativeVideoPlayerSubtitleTrack.fromMap(track.toMap());

      expect(decoded.source, SubtitleTrackSource.sidecar);
      expect(decoded.index, 1);
      expect(decoded.language, 'nl');
    });

    test('payloads without source decode as embedded', () {
      final decoded = NativeVideoPlayerSubtitleTrack.fromMap(<String, dynamic>{
        'index': 0,
        'language': 'en',
        'displayName': 'English',
        'isSelected': true,
      });

      expect(decoded.source, SubtitleTrackSource.embedded);
      expect(decoded.isSelected, isTrue);
    });
  });

  group('subtitle choice survives a new platform view', () {
    testWidgets('re-sends "off" to the platform', (tester) async {
      await createController(tester);
      await controller!.load(url: 'https://example.com/v.m3u8');
      await controller!.setSubtitleTrack(NativeVideoPlayerSubtitleTrack.off());
      expect(subtitleCalls(), hasLength(1));

      await attachView(tester, viewId + 1);

      final resent = subtitleCalls();
      expect(resent, hasLength(2));
      expect(trackIndexOf(resent.last), -1);
    });

    testWidgets('re-sends an embedded track to the platform', (tester) async {
      await createController(tester);
      await controller!.load(url: 'https://example.com/v.m3u8');
      await controller!.setSubtitleTrack(
        const NativeVideoPlayerSubtitleTrack(
          index: 2,
          language: 'nl',
          displayName: 'Nederlands',
        ),
      );

      await attachView(tester, viewId + 1);

      expect(trackIndexOf(subtitleCalls().last), 2);
    });

    testWidgets('keeps the native track off for a sidecar selection', (
      tester,
    ) async {
      await createController(tester);
      await controller!.load(
        url: 'https://example.com/v.m3u8',
        sidecarSubtitles: const <NativeVideoPlayerSidecarSubtitle>[
          NativeVideoPlayerSidecarSubtitle.content(
            'WEBVTT\n\n00:00.000 --> 00:01.000\nHallo\n',
            language: 'nl',
            label: 'Nederlands',
          ),
        ],
      );
      await controller!.setSubtitleTrack(
        const NativeVideoPlayerSubtitleTrack(
          index: 0,
          language: 'nl',
          displayName: 'Nederlands',
          source: SubtitleTrackSource.sidecar,
        ),
      );
      final callsBefore = subtitleCalls().length;

      await attachView(tester, viewId + 1);

      final resent = subtitleCalls();
      expect(resent.length, callsBefore + 1);
      expect(trackIndexOf(resent.last), -1);
    });

    testWidgets('does not re-send when nothing was chosen', (tester) async {
      await createController(tester);
      await controller!.load(url: 'https://example.com/v.m3u8');

      await attachView(tester, viewId + 1);

      expect(subtitleCalls(), isEmpty);
    });

    testWidgets('a new load forgets the previous choice', (tester) async {
      await createController(tester);
      await controller!.load(url: 'https://example.com/a.m3u8');
      await controller!.setSubtitleTrack(NativeVideoPlayerSubtitleTrack.off());
      await controller!.load(url: 'https://example.com/b.m3u8', force: true);
      final callsBefore = subtitleCalls().length;

      await attachView(tester, viewId + 1);

      expect(subtitleCalls().length, callsBefore);
    });
  });
}

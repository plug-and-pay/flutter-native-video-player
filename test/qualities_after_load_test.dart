import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The quality list reaching `controller.qualities` / `qualitiesStream`.
///
/// iOS reads the HLS master playlist a moment after the item is ready, so
/// `getAvailableQualities` right after `load()` answers `[]` and the list
/// arrives later with a `qualityChange` event. Android can do the same when
/// it falls back to fetching the playlist itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('native_video_player');

  MockStreamHandlerEventSink? viewSink;

  /// What native answers to `getAvailableQualities`.
  List<Map<String, Object?>> nativeQualities = <Map<String, Object?>>[];

  const Map<String, Object?> auto = <String, Object?>{
    'label': 'Auto',
    'url': 'https://example.com/360.m3u8',
    'isAuto': true,
  };
  const Map<String, Object?> q360 = <String, Object?>{
    'label': '640x360',
    'url': 'https://example.com/360.m3u8',
    'bitrate': 800000,
    'width': 640,
    'height': 360,
    'isAuto': false,
  };
  const Map<String, Object?> q720 = <String, Object?>{
    'label': '1280x720',
    'url': 'https://example.com/720.m3u8',
    'bitrate': 2500000,
    'width': 1280,
    'height': 720,
    'isAuto': false,
  };

  Map<String, Object?> qualitiesLoadedEvent(
    List<Map<String, Object?>> qualities,
  ) => <String, Object?>{
    'event': 'qualityChange',
    'url': auto['url'],
    'label': 'Auto',
    'isAuto': true,
    'qualities': qualities,
  };

  setUp(() {
    viewSink = null;
    nativeQualities = <Map<String, Object?>>[];
    NativeVideoPlayerController.controllerChannelRetryDelays = const [
      Duration.zero,
      Duration.zero,
      Duration.zero,
    ];
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  Future<NativeVideoPlayerController> pumpControllerWithView(
    WidgetTester tester, {
    required int controllerId,
    required int viewId,
  }) async {
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == 'load') {
        viewSink!.success(<String, Object?>{'event': 'loaded'});
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (call.method == 'getAvailableQualities') return nativeQualities;
      return null;
    });
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_controller_$controllerId'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
    messenger.setMockStreamHandler(
      EventChannel('native_video_player_$viewId'),
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          viewSink = events;
        },
      ),
    );

    final controller = NativeVideoPlayerController(id: controllerId);
    await controller.debugControllerChannelSetup;
    await controller.onPlatformViewCreated(
      viewId,
      tester.element(find.byType(SizedBox)),
    );
    await controller.initialize();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(viewSink, isNotNull);
    return controller;
  }

  testWidgets(
    'qualities that arrive after load reach qualities and the stream',
    (tester) async {
      await tester.pumpWidget(const SizedBox());

      await tester.runAsync(() async {
        final controller = await pumpControllerWithView(
          tester,
          controllerId: 81,
          viewId: 810,
        );

        await controller.load(url: 'https://example.com/video.m3u8');
        expect(controller.qualities, isEmpty);

        final Future<List<NativeVideoPlayerQuality>> streamed =
            controller.qualitiesStream.first;
        viewSink!.success(
          qualitiesLoadedEvent(<Map<String, Object?>>[auto, q360, q720]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(controller.qualities.map((q) => q.label), <String>[
          'Auto',
          '640x360',
          '1280x720',
        ]);
        expect(controller.qualities.last.height, 720);
        expect((await streamed).map((q) => q.label), <String>[
          'Auto',
          '640x360',
          '1280x720',
        ]);
        await controller.dispose();
      });
    },
  );

  testWidgets('the selected quality still reaches qualityChangedStream', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());

    await tester.runAsync(() async {
      final controller = await pumpControllerWithView(
        tester,
        controllerId: 82,
        viewId: 820,
      );
      await controller.load(url: 'https://example.com/video.m3u8');

      final Future<NativeVideoPlayerQuality> selected =
          controller.qualityChangedStream.first;
      viewSink!.success(
        qualitiesLoadedEvent(<Map<String, Object?>>[auto, q360]),
      );

      expect((await selected).isAuto, isTrue);
      await controller.dispose();
    });
  });

  testWidgets('a quality change without a list keeps the known qualities', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());

    await tester.runAsync(() async {
      final controller = await pumpControllerWithView(
        tester,
        controllerId: 83,
        viewId: 830,
      );
      nativeQualities = <Map<String, Object?>>[auto, q360, q720];
      await controller.load(url: 'https://example.com/video.m3u8');
      expect(controller.qualities, hasLength(3));

      // What setQuality makes native send: the pick, no list.
      viewSink!.success(<String, Object?>{'event': 'qualityChange', ...q360});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.qualities, hasLength(3));
      await controller.dispose();
    });
  });

  testWidgets('a different video drops the previous video\'s qualities', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());

    await tester.runAsync(() async {
      final controller = await pumpControllerWithView(
        tester,
        controllerId: 84,
        viewId: 840,
      );
      nativeQualities = <Map<String, Object?>>[auto, q360, q720];
      await controller.load(url: 'https://example.com/first.m3u8');
      expect(controller.qualities, hasLength(3));

      nativeQualities = <Map<String, Object?>>[];
      await controller.load(url: 'https://example.com/second.mp4');

      expect(controller.qualities, isEmpty);
      await controller.dispose();
    });
  });

  testWidgets('reloading the same video keeps its qualities', (tester) async {
    await tester.pumpWidget(const SizedBox());

    await tester.runAsync(() async {
      final controller = await pumpControllerWithView(
        tester,
        controllerId: 85,
        viewId: 850,
      );
      await controller.load(url: 'https://example.com/video.m3u8');
      viewSink!.success(
        qualitiesLoadedEvent(<Map<String, Object?>>[auto, q360, q720]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Native answers [] again: its list only comes with the next event.
      await controller.load(url: 'https://example.com/video.m3u8', force: true);

      expect(controller.qualities, hasLength(3));
      await controller.dispose();
    });
  });

  testWidgets('a resolution listed twice shows once, at its highest bitrate', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());

    await tester.runAsync(() async {
      final controller = await pumpControllerWithView(
        tester,
        controllerId: 86,
        viewId: 860,
      );
      await controller.load(url: 'https://example.com/video.m3u8');

      // An HEVC and an AVC rendition of 720p, as multi-codec playlists list.
      final Map<String, Object?> q720Hevc = <String, Object?>{
        ...q720,
        'url': 'https://example.com/720-hevc.m3u8',
        'bitrate': 1600000,
      };
      viewSink!.success(
        qualitiesLoadedEvent(<Map<String, Object?>>[
          auto,
          q360,
          q720Hevc,
          q720,
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.qualities.map((q) => q.label), <String>[
        'Auto',
        '640x360',
        '1280x720',
      ]);
      expect(controller.qualities.last.bitrate, 2500000);
      await controller.dispose();
    });
  });
}

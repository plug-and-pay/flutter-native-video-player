import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:material_ui/material_ui.dart';

/// Vertical reels feed (scenario C) showing [NativeVideoPlayerPreloader].
///
/// Each page loads its video only when it becomes the current page, like a
/// reels feed that doesn't want every neighbour streaming. With preloading
/// on, the next two and the previous video are preloaded, so a swipe starts
/// from buffered data. The readout shows the time from the swipe settling to
/// the video playing, split by preloaded and cold starts, and every
/// measurement is also printed as `PERF_REELS_TTFF <preloaded|cold> <index> <ms>`.
///
/// Pass `--dart-define=REELS_MEDIA_BASE=http://host:port/path` to play
/// `<base>/hls/v<NN>/master.m3u8` (NN = 01…40) from your own server instead of
/// the public test streams, so every reel is a distinct URL.
class ReelsScreen extends StatefulWidget {
  const ReelsScreen({super.key});

  @override
  State<ReelsScreen> createState() => _ReelsScreenState();
}

class _ReelsScreenState extends State<ReelsScreen> {
  static const String _mediaBase = String.fromEnvironment('REELS_MEDIA_BASE');

  static const List<String> _publicStreams = <String>[
    'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
    'https://test-streams.mux.dev/tos_ismc/main.m3u8',
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8',
    'https://media.w3.org/2010/05/sintel/trailer.mp4',
  ];

  late final List<NativeVideoPlayerPreloadItem> _items = _mediaBase.isNotEmpty
      ? List<NativeVideoPlayerPreloadItem>.generate(
          40,
          (int i) => NativeVideoPlayerPreloadItem(
            url:
                '$_mediaBase/hls/v${(i + 1).toString().padLeft(2, '0')}/master.m3u8',
          ),
        )
      : _publicStreams
            .map((String url) => NativeVideoPlayerPreloadItem(url: url))
            .toList();

  final NativeVideoPlayerPreloader _preloader = NativeVideoPlayerPreloader();
  bool _preload = true;
  int _current = 0;

  // What the preloader held before the current page became current, so
  // each start can be labelled preloaded or cold.
  Set<String> _windowBeforeSwipe = <String>{};

  final List<int> _preloadedTimes = <int>[];
  final List<int> _coldTimes = <int>[];
  String _last = '–';

  // Android preloads into the disk cache, so this screen turns it on while
  // it is open (the showcase app has it on anyway; the dev harness doesn't).
  late final NativeVideoPlayerConfig _previousConfig =
      NativeVideoPlayerConfig.global;

  @override
  void initState() {
    super.initState();
    if (!_previousConfig.androidEnableDiskCache) {
      // The dev harness runs with the default config; same plus the cache.
      NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
        androidEnableDiskCache: true,
      );
    }
    _moveWindow(0);
  }

  @override
  void dispose() {
    unawaited(_preloader.dispose());
    NativeVideoPlayerConfig.global = _previousConfig;
    super.dispose();
  }

  void _moveWindow(int index) {
    _windowBeforeSwipe = _preloader.window
        .map((NativeVideoPlayerPreloadItem i) => i.url)
        .toSet();
    _current = index;
    if (_preload) {
      unawaited(_preloader.setWindow(_items, index));
    }
  }

  void _togglePreload(bool value) {
    setState(() => _preload = value);
    if (value) {
      unawaited(_preloader.setWindow(_items, _current));
    } else {
      unawaited(_preloader.clear());
    }
  }

  void _onStarted(int index, int ms) {
    final bool preloaded = _windowBeforeSwipe.contains(_items[index].url);
    // ignore: avoid_print
    print('PERF_REELS_TTFF ${preloaded ? 'preloaded' : 'cold'} $index $ms');
    if (!mounted) return;
    setState(() {
      (preloaded ? _preloadedTimes : _coldTimes).add(ms);
      _last = '$ms ms (${preloaded ? 'preloaded' : 'cold'})';
    });
  }

  static String _median(List<int> values) {
    if (values.isEmpty) return '–';
    final List<int> sorted = List<int>.of(values)..sort();
    return '${sorted[sorted.length ~/ 2]} ms (n=${values.length})';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Reels'),
        actions: <Widget>[
          const Center(child: Text('Preload')),
          Switch(
            key: const ValueKey<String>('reels_preload_switch'),
            value: _preload,
            onChanged: _togglePreload,
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          PageView.builder(
            key: const ValueKey<String>('reels_page_view'),
            scrollDirection: Axis.vertical,
            itemCount: _items.length,
            onPageChanged: (int index) => setState(() => _moveWindow(index)),
            itemBuilder: (BuildContext context, int index) => _ReelPage(
              key: ValueKey<String>('reel_$index'),
              index: index,
              url: _items[index].url,
              active: index == _current,
              onStarted: (int ms) => _onStarted(index, ms),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 24,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: DefaultTextStyle(
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          'Reel ${_current + 1}/${_items.length}',
                          key: const ValueKey<String>('reels_index'),
                        ),
                        Text(
                          'Last start: $_last',
                          key: const ValueKey<String>('reels_ttff_last'),
                        ),
                        Text(
                          'Preloaded median: ${_median(_preloadedTimes)}',
                          key: const ValueKey<String>('reels_ttff_preloaded'),
                        ),
                        Text(
                          'Cold median: ${_median(_coldTimes)}',
                          key: const ValueKey<String>('reels_ttff_cold'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReelPage extends StatefulWidget {
  const _ReelPage({
    required this.index,
    required this.url,
    required this.active,
    required this.onStarted,
    super.key,
  });

  final int index;
  final String url;
  final bool active;
  final void Function(int ms) onStarted;

  @override
  State<_ReelPage> createState() => _ReelPageState();
}

class _ReelPageState extends State<_ReelPage> {
  late final NativeVideoPlayerController _controller =
      NativeVideoPlayerController(
        id: 7000 + widget.index,
        autoPlay: false,
        showNativeControls: false,
        canStartPictureInPictureAutomatically: false,
        // Nothing native exists until the page becomes current.
        deferNativePlayer: true,
      );

  bool _loaded = false;
  Stopwatch? _startWatch;
  StreamSubscription<PlayerActivityState>? _stateSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_controller.initialize());
    _stateSubscription = _controller.playerStateStream.listen((
      PlayerActivityState state,
    ) {
      final Stopwatch? watch = _startWatch;
      if (state == PlayerActivityState.playing && watch != null) {
        _startWatch = null;
        widget.onStarted(watch.elapsedMilliseconds);
      }
    });
    if (widget.active) unawaited(_start());
  }

  @override
  void didUpdateWidget(_ReelPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      unawaited(_start());
    } else if (!widget.active && oldWidget.active) {
      _startWatch = null;
      unawaited(_controller.pause());
    }
  }

  Future<void> _start() async {
    _startWatch = Stopwatch()..start();
    try {
      if (!_loaded) {
        _loaded = true;
        await _controller.load(url: widget.url);
      }
      if (mounted && widget.active) await _controller.play();
    } catch (e) {
      debugPrint('Reel ${widget.index} failed to start: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_stateSubscription?.cancel());
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: NativeVideoPlayer(controller: _controller),
        ),
      ),
    );
  }
}

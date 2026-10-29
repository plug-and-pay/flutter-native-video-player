import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

/// Repro for route transitions and fullscreen over a playing video:
/// `flutter run -t lib/transition_repro.dart`. Page A has a video below
/// some text; "Open page B" pushes a page with its own video at the top, so
/// page B slides over page A's video (iOS used to draw that video on top of
/// page B mid-transition). The overlay's button opens Dart fullscreen.
void main() {
  // `--dart-define=ANDROID_TEXTURE=true`: inline players render as Flutter
  // textures on Android instead of hybrid-composition platform views.
  if (const String.fromEnvironment('ANDROID_TEXTURE') == 'true') {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      androidTextureMode: true,
    );
  }
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: _TabShell()),
  );
}

/// Like a tab app (Huddle's feed): page A lives in a nested navigator under
/// a bottom bar, and page B is pushed on the root navigator, over the bar.
class _TabShell extends StatelessWidget {
  const _TabShell();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Navigator(
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => const _PageA()),
      ),
      bottomNavigationBar: NavigationBar(
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Feed'),
          NavigationDestination(icon: Icon(Icons.school), label: 'Resources'),
        ],
      ),
    );
  }
}

/// `--dart-define=AUTO=true`: steps through every case on its own with
/// animations slowed down, for devices that can only be watched (screenshots
/// over USB), not tapped.
const bool _auto = String.fromEnvironment('AUTO') == 'true';

/// `--dart-define=AUTO=pip`: opens the feed and runs the PiP steps on its
/// own (PiP needs a real device; the simulator has none).
const bool _autoPip = String.fromEnvironment('AUTO') == 'pip';

/// The inline players' clip, which the fullscreen flight lands into.
const BorderRadius _inlineRadius = BorderRadius.all(Radius.circular(16));

const String _hlsUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
const String _mp4Url = 'https://media.w3.org/2010/05/sintel/trailer.mp4';

class _PageA extends StatefulWidget {
  const _PageA();

  @override
  State<_PageA> createState() => _PageAState();
}

class _PageAState extends State<_PageA> {
  final NativeVideoPlayerController _shared = NativeVideoPlayerController(
    id: 101,
    autoPlay: true,
    lockToLandscape: false,
    fullscreenFlightBorderRadius: _inlineRadius,
  );

  @override
  void initState() {
    super.initState();
    if (_auto) {
      timeDilation = 10;
      unawaited(_runSteps());
    }
    if (_autoPip) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const _Feed())),
      );
    }
  }

  Future<void> _runSteps() async {
    Future<void> step(String name, Duration wait) async {
      debugPrint('REPRO_STEP $name');
      await Future<void>.delayed(wait);
    }

    const settle = Duration(seconds: 12);
    await step('loading', const Duration(seconds: 8));
    for (final bool shared in [false, true]) {
      if (!mounted) return;
      unawaited(
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(
            builder: (_) => _PageB(shared: shared ? _shared : null),
          ),
        ),
      );
      await step('push${shared ? '_shared' : ''}', settle);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await step('pop${shared ? '_shared' : ''}', settle);
    }
    unawaited(_shared.enterFullScreen());
    await step('fullscreen_enter', settle);
    unawaited(_shared.exitFullScreen());
    await step('fullscreen_exit', settle);
    debugPrint('REPRO_STEP done');
  }

  @override
  void dispose() {
    _shared.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Page A')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(
            height: 160,
            child: Text(
              'Page A text above the video. Push page B and watch whether '
              "this page's video stays under it while it slides in.",
              style: TextStyle(fontSize: 18),
            ),
          ),
          _Player(controller: _shared, url: _hlsUrl),
          const SizedBox(height: 24),
          ElevatedButton(
            key: const ValueKey('open_page_b'),
            onPressed: () => Navigator.of(
              context,
              rootNavigator: true,
            ).push(MaterialPageRoute<void>(builder: (_) => const _PageB())),
            child: const Text('Open page B'),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            key: const ValueKey('slow_animations'),
            title: const Text('Slow animations (x10)'),
            value: timeDilation > 1,
            onChanged: (slow) => setState(() => timeDilation = slow ? 10 : 1),
          ),
          ElevatedButton(
            key: const ValueKey('open_feed'),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const _Feed())),
            child: const Text('Open feed (PiP)'),
          ),
          ElevatedButton(
            key: const ValueKey('open_page_b_shared'),
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(builder: (_) => _PageB(shared: _shared)),
            ),
            child: const Text('Open page B (same video)'),
          ),
        ],
      ),
    );
  }
}

class _PageB extends StatelessWidget {
  const _PageB({this.shared});

  /// Page A's controller: page B then shows the same video (one shared
  /// native player, two views), like a feed post opened in its detail page.
  final NativeVideoPlayerController? shared;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(title: const Text('Page B')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (shared != null)
            _Player(controller: shared!, url: _hlsUrl)
          else
            const _Player(id: 102, url: _mp4Url),
          const SizedBox(height: 24),
          const Text('Page B content', style: TextStyle(fontSize: 22)),
          const SizedBox(height: 400),
        ],
      ),
    );
  }
}

/// A scrolling feed of players with PiP allowed (auto and manual), like
/// Huddle's: PiP must start from the tile where it is, wherever the feed
/// has scrolled it to, and the tile keeps scrolling while PiP is open.
class _Feed extends StatefulWidget {
  const _Feed();

  @override
  State<_Feed> createState() => _FeedState();
}

class _FeedState extends State<_Feed> {
  final ScrollController _scroll = ScrollController();
  late final List<NativeVideoPlayerController> _controllers = List.generate(
    6,
    (int index) => NativeVideoPlayerController(
      id: 201 + index,
      lockToLandscape: false,
      fullscreenFlightBorderRadius: _inlineRadius,
    ),
  );
  String _step = '';

  @override
  void initState() {
    super.initState();
    if (_autoPip) unawaited(_runPipSteps());
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _runPipSteps() async {
    Future<void> step(String name, int seconds) async {
      debugPrint('REPRO_STEP $name');
      if (mounted) setState(() => _step = name);
      await Future<void>.delayed(Duration(seconds: seconds));
    }

    Future<void> scrollTo(double offset) => _scroll.animateTo(
      offset,
      duration: const Duration(seconds: 2),
      curve: Curves.easeInOut,
    );

    final NativeVideoPlayerController tile = _controllers[1];
    await step('1 loading', 6);
    await scrollTo(250);
    unawaited(tile.play());
    await step('2 tile 2 plays', 4);
    unawaited(tile.enterPictureInPicture());
    await step('3 PiP started from tile 2', 5);
    await scrollTo(1100);
    await step('4 scrolled down while PiP is open', 4);
    await scrollTo(250);
    await step('5 scrolled back', 4);
    if (!mounted) return;
    unawaited(
      Navigator.of(
        context,
        rootNavigator: true,
      ).push(MaterialPageRoute<void>(builder: (_) => const _PageB())),
    );
    await step('6 page B over the feed, PiP open', 5);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    await step('7 page B closed', 4);
    await scrollTo(700);
    await step('8 tile 2 half scrolled off, closing PiP', 2);
    unawaited(tile.exitPictureInPicture());
    await step('9 PiP closed: window should fly to tile 2', 5);
    await scrollTo(250);
    unawaited(tile.play());
    await step('10 PRESS HOME NOW (auto PiP), then come back', 15);
    await step('done', 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_step.isEmpty ? 'Feed' : _step)),
      body: ListView.separated(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        itemCount: 6,
        separatorBuilder: (_, _) => const SizedBox(
          height: 140,
          child: Center(child: Text('post text between the videos')),
        ),
        itemBuilder: (_, int index) => _Player(
          key: ValueKey(201 + index),
          controller: _controllers[index],
          url: index.isEven ? _hlsUrl : _mp4Url,
        ),
      ),
    );
  }
}

class _Player extends StatefulWidget {
  const _Player({required this.url, this.id, this.controller, super.key});

  final int? id;
  final String url;

  /// An existing controller (shared with another page); this widget then
  /// neither loads nor disposes it beyond the first load.
  final NativeVideoPlayerController? controller;

  @override
  State<_Player> createState() => _PlayerState();
}

class _PlayerState extends State<_Player> {
  late final NativeVideoPlayerController _controller =
      widget.controller ??
      NativeVideoPlayerController(
        id: widget.id!,
        lockToLandscape: false,
        fullscreenFlightBorderRadius: _inlineRadius,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_controller.activityState.isLoaded) return;
      await _controller.initialize();
      await _controller.load(url: widget.url);
    });
  }

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: _inlineRadius,
        child: NativeVideoPlayer(
          controller: _controller,
          overlayBuilder: (context, controller) => _Overlay(controller),
        ),
      ),
    );
  }
}

class _Overlay extends StatelessWidget {
  const _Overlay(this.controller);

  final NativeVideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Center(
          child: StreamBuilder<PlayerActivityState>(
            stream: controller.playerStateStream,
            initialData: controller.activityState,
            builder: (context, snapshot) {
              final playing = snapshot.data == PlayerActivityState.playing;
              return IconButton.filled(
                key: ValueKey('play_${controller.id}'),
                iconSize: 36,
                onPressed: () =>
                    playing ? controller.pause() : controller.play(),
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              );
            },
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          child: IconButton.filled(
            key: ValueKey('pip_${controller.id}'),
            onPressed: controller.enterPictureInPicture,
            icon: const Icon(Icons.picture_in_picture_alt),
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: IconButton.filled(
            key: ValueKey('fullscreen_${controller.id}'),
            onPressed: controller.toggleFullScreen,
            icon: const Icon(Icons.fullscreen),
          ),
        ),
      ],
    );
  }
}

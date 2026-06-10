import 'dart:async';
import 'dart:convert';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

import 'perf_hud.dart';

/// List → detail navigation with a SHARED controller (B5 scenario).
///
/// The detail route mounts a second `NativeVideoPlayer` on the same
/// controller; playback must continue without reinitialization, black frames,
/// or audio gaps. The automated loop logs `PERF_NAVLOOP:{...}` with the
/// playback position at each step so monotonicity is assertable from logs.
class NavLoopScreen extends StatefulWidget {
  const NavLoopScreen({super.key});

  static const int controllerId = 9100;

  @override
  State<NavLoopScreen> createState() => _NavLoopScreenState();
}

class _NavLoopScreenState extends State<NavLoopScreen> {
  late final NativeVideoPlayerController _controller;
  bool _loopRunning = false;

  @override
  void initState() {
    super.initState();
    _controller = NativeVideoPlayerController(
      id: NavLoopScreen.controllerId,
      autoPlay: true,
      lockToLandscape: false,
      showNativeControls: false,
      mediaInfo: const NativeVideoPlayerMediaInfo(
        title: 'Nav loop video',
        subtitle: 'Shared-controller continuity test',
      ),
    );
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _controller.initialize();
      await _controller.load(
        url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
      );
    } catch (e) {
      debugPrint('NavLoopScreen load error: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _logPosition(String step, int iteration) {
    debugPrint(
      'PERF_NAVLOOP:${jsonEncode(<String, Object>{'iter': iteration, 'step': step, 'pos': _controller.currentPosition.inMilliseconds, 'state': _controller.activityState.name})}',
    );
  }

  Future<void> _openDetail() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _NavLoopDetailScreen(controller: _controller),
      ),
    );
  }

  Future<void> _runLoop(int iterations) async {
    if (_loopRunning) return;
    setState(() => _loopRunning = true);
    for (var i = 1; i <= iterations; i++) {
      if (!mounted) return;
      _logPosition('beforePush', i);
      final popped = _openDetail();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return;
      _logPosition('onDetail', i);
      Navigator.of(context).pop();
      await popped;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return;
      _logPosition('afterPop', i);
    }
    if (mounted) setState(() => _loopRunning = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nav loop (shared ID)')),
      body: Column(
        children: [
          const PerfHud(dumpLabel: 'nav_loop'),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: NativeVideoPlayer(controller: _controller),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: StreamBuilder<Duration>(
              stream: _controller.positionStream,
              initialData: _controller.currentPosition,
              builder: (context, snapshot) => Text(
                'position: ${(snapshot.data ?? Duration.zero).inSeconds}s',
                key: const ValueKey('nav_position_label'),
              ),
            ),
          ),
          ElevatedButton(
            key: const ValueKey('nav_open_detail'),
            onPressed: _openDetail,
            child: const Text('Open detail (same controller)'),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            key: const ValueKey('nav_loop_x10'),
            onPressed: _loopRunning ? null : () => _runLoop(10),
            child: Text(_loopRunning ? 'Loop running…' : 'Run loop ×10'),
          ),
        ],
      ),
    );
  }
}

class _NavLoopDetailScreen extends StatelessWidget {
  const _NavLoopDetailScreen({required this.controller});

  final NativeVideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detail (same controller)'),
        leading: BackButton(key: const ValueKey('nav_back')),
      ),
      body: Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            color: Colors.black,
            child: NativeVideoPlayer(controller: controller),
          ),
        ),
      ),
    );
  }
}

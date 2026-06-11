import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

import 'perf_hud.dart';

/// PiP entry/exit harness (B8 scenario).
///
/// Android PiP requires Dart fullscreen mode (custom overlay), so this screen
/// uses an overlay-enabled player and exposes buttons for fullscreen → PiP.
/// iOS supports inline PiP directly.
class PipScreen extends StatefulWidget {
  const PipScreen({super.key});

  static const int controllerId = 9400;

  @override
  State<PipScreen> createState() => _PipScreenState();
}

class _PipScreenState extends State<PipScreen> {
  late final NativeVideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = NativeVideoPlayerController(
      id: PipScreen.controllerId,
      autoPlay: true,
      lockToLandscape: false,
      showNativeControls: false,
      // Manual-PiP testbed: with automatic PiP off, iosTextureMode applies
      // to this tile, so 'Enter PiP' exercises the texture→platform-view
      // live swap. (Automatic PiP is covered by the gallery cards.)
      canStartPictureInPictureAutomatically: false,
      mediaInfo: const NativeVideoPlayerMediaInfo(
        title: 'PiP test video',
        subtitle: 'Picture-in-Picture harness',
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
      debugPrint('PipScreen load error: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PiP harness')),
      body: Column(
        children: [
          const PerfHud(dumpLabel: 'pip'),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: NativeVideoPlayer(
                controller: _controller,
                overlayBuilder: (context, controller) => const SizedBox(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: StreamBuilder<bool>(
              stream: _controller.isPipEnabledStream,
              initialData: false,
              builder: (context, snapshot) => Text(
                'PiP active: ${snapshot.data}',
                key: const ValueKey('pip_state_label'),
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                key: const ValueKey('pip_enter_fullscreen'),
                onPressed: () => _controller.enterFullScreen(),
                child: const Text('Enter fullscreen'),
              ),
              ElevatedButton(
                key: const ValueKey('pip_enter'),
                onPressed: () async {
                  final ok = await _controller.enterPictureInPicture();
                  debugPrint('PERF_PIP:{"enter":$ok}');
                },
                child: const Text('Enter PiP'),
              ),
              ElevatedButton(
                key: const ValueKey('pip_exit'),
                onPressed: () async {
                  final ok = await _controller.exitPictureInPicture();
                  debugPrint('PERF_PIP:{"exit":$ok}');
                },
                child: const Text('Exit PiP'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

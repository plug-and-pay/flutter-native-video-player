import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

import '../../models/video_item.dart';
import 'perf_hud.dart';
import 'stress_player_tile.dart';

/// N simultaneous autoplay players (B2 scenario).
///
/// All players are mounted at once (scrollable if they don't fit) and start
/// playing automatically, mixing HLS and MP4 sources.
class StressFeedScreen extends StatefulWidget {
  const StressFeedScreen({required this.playerCount, super.key});

  final int playerCount;

  @override
  State<StressFeedScreen> createState() => _StressFeedScreenState();
}

class _StressFeedScreenState extends State<StressFeedScreen> {
  // Fresh controller IDs per screen visit so perf runs never race a previous
  // visit's in-flight dispose of the same controller ID (the same-ID
  // reattachment path is exercised deliberately by the nav-loop and
  // lifecycle-stress screens instead).
  static int _visitCounter = 0;

  late final List<VideoItem> _videos;
  final Map<int, NativeVideoPlayerController> _controllers = {};
  final Map<int, PlayerActivityState> _states = {};
  final ValueNotifier<int> _playingCount = ValueNotifier<int>(0);
  bool _naiveRebuilds = false;

  @override
  void initState() {
    super.initState();
    _videos = VideoItem.getStressVideos(
      widget.playerCount,
      idOffset: 20000 + (_visitCounter++ * 10),
    );
  }

  void _onControllerCreated(NativeVideoPlayerController controller) {
    _controllers[controller.id] = controller;
    controller.addActivityListener((event) {
      _states[controller.id] = event.state;
      _playingCount.value = _states.values
          .where((s) => s == PlayerActivityState.playing)
          .length;
    });
  }

  @override
  void dispose() {
    _playingCount.dispose();
    super.dispose();
  }

  Future<void> _setAllPlaying(bool playing) async {
    for (final controller in _controllers.values) {
      if (playing) {
        await controller.play();
      } else {
        await controller.pause();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Stress feed (N=${widget.playerCount})'),
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: _playingCount,
            builder: (context, count, _) => Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  'playing: $count',
                  key: const ValueKey('stress_feed_playing_count'),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          PerfHud(dumpLabel: 'stress_feed_n${widget.playerCount}'),
          Row(
            children: [
              TextButton(
                key: const ValueKey('feed_play_all'),
                onPressed: () => _setAllPlaying(true),
                child: const Text('Play all'),
              ),
              TextButton(
                key: const ValueKey('feed_pause_all'),
                onPressed: () => _setAllPlaying(false),
                child: const Text('Pause all'),
              ),
              const Spacer(),
              const Text('naive', style: TextStyle(fontSize: 12)),
              Switch(
                key: const ValueKey('feed_toggle_card_mode'),
                value: _naiveRebuilds,
                onChanged: (value) => setState(() => _naiveRebuilds = value),
              ),
            ],
          ),
          // All tiles are mounted eagerly (no ListView laziness): this screen
          // measures N players ACTUALLY running simultaneously.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (var index = 0; index < _videos.length; index++)
                    StressPlayerTile(
                      key: ValueKey('stress_feed_player_$index'),
                      video: _videos[index],
                      index: index,
                      naiveRebuilds: _naiveRebuilds,
                      onControllerCreated: _onControllerCreated,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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

  /// Copies the global config with the given overrides (the config class is
  /// immutable and has no copyWith; this keeps the toggles independent).
  NativeVideoPlayerConfig _copyGlobalConfig({
    int? maxConcurrentPlayingPlayers,
    bool clearMaxConcurrent = false,
    bool? qualityForViewportSize,
    bool? lightweightInlineViews,
    bool? androidEnableDiskCache,
    bool? prioritizeActivePlayback,
    bool? androidTextureMode,
    bool? iosTextureMode,
  }) {
    final global = NativeVideoPlayerConfig.global;
    return NativeVideoPlayerConfig(
      maxConcurrentPlayingPlayers: clearMaxConcurrent
          ? null
          : maxConcurrentPlayingPlayers ?? global.maxConcurrentPlayingPlayers,
      qualityForViewportSize:
          qualityForViewportSize ?? global.qualityForViewportSize,
      lightweightInlineViews:
          lightweightInlineViews ?? global.lightweightInlineViews,
      androidEnableDiskCache:
          androidEnableDiskCache ?? global.androidEnableDiskCache,
      prioritizeActivePlayback:
          prioritizeActivePlayback ?? global.prioritizeActivePlayback,
      androidTextureMode: androidTextureMode ?? global.androidTextureMode,
      iosTextureMode: iosTextureMode ?? global.iosTextureMode,
    );
  }

  Future<void> _precacheStressVideos() async {
    var warmed = 0;
    for (final video in _videos) {
      if (await NativeVideoPlayerCache.precache(video.url)) {
        warmed++;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Precached $warmed/${_videos.length} videos'),
        duration: const Duration(seconds: 1),
      ),
    );
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
          // Horizontally scrollable: the toggle row no longer fits on
          // narrower phones.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
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
                const Text('vp', style: TextStyle(fontSize: 12)),
                // Viewport quality capping. Applies at platform-view creation:
                // toggle, then leave and re-enter this screen.
                Switch(
                  key: const ValueKey('feed_toggle_viewport_cap'),
                  value: NativeVideoPlayerConfig.global.qualityForViewportSize,
                  onChanged: (value) => setState(() {
                    NativeVideoPlayerConfig.global = _copyGlobalConfig(
                      qualityForViewportSize: value,
                    );
                  }),
                ),
                const Text('cap 2', style: TextStyle(fontSize: 12)),
                Switch(
                  key: const ValueKey('feed_set_cap_2'),
                  value:
                      NativeVideoPlayerConfig
                          .global
                          .maxConcurrentPlayingPlayers !=
                      null,
                  onChanged: (value) => setState(() {
                    NativeVideoPlayerConfig.global = _copyGlobalConfig(
                      maxConcurrentPlayingPlayers: value ? 2 : null,
                      clearMaxConcurrent: !value,
                    );
                  }),
                ),
                const Text('light', style: TextStyle(fontSize: 12)),
                // Lightweight views (Tier 2). Applies at platform-view
                // creation: toggle, then leave and re-enter this screen.
                Switch(
                  key: const ValueKey('feed_toggle_light_views'),
                  value: NativeVideoPlayerConfig.global.lightweightInlineViews,
                  onChanged: (value) => setState(() {
                    NativeVideoPlayerConfig.global = _copyGlobalConfig(
                      lightweightInlineViews: value,
                    );
                  }),
                ),
                const Text('naive', style: TextStyle(fontSize: 12)),
                Switch(
                  key: const ValueKey('feed_toggle_card_mode'),
                  value: _naiveRebuilds,
                  onChanged: (value) => setState(() => _naiveRebuilds = value),
                ),
                const Text('tex', style: TextStyle(fontSize: 12)),
                // Texture rendering (Tier 4, both platforms). Applies at
                // view creation: toggle, then leave and re-enter. Note: the
                // stress tiles allow automatic PiP, so on iOS they keep
                // platform views unless auto PiP is off for the controller.
                Switch(
                  key: const ValueKey('feed_toggle_texture'),
                  value:
                      NativeVideoPlayerConfig.global.androidTextureMode ||
                      NativeVideoPlayerConfig.global.iosTextureMode,
                  onChanged: (value) => setState(() {
                    NativeVideoPlayerConfig.global = _copyGlobalConfig(
                      androidTextureMode: value,
                      iosTextureMode: value,
                    );
                  }),
                ),
                const Text('3a', style: TextStyle(fontSize: 12)),
                // Playback prioritization (Tier 3a, Android). Applies at
                // player creation: toggle, then leave and re-enter.
                Switch(
                  key: const ValueKey('feed_toggle_prioritize'),
                  value:
                      NativeVideoPlayerConfig.global.prioritizeActivePlayback,
                  onChanged: (value) => setState(() {
                    NativeVideoPlayerConfig.global = _copyGlobalConfig(
                      prioritizeActivePlayback: value,
                    );
                  }),
                ),
                const Text('cache', style: TextStyle(fontSize: 12)),
                // Android disk cache (Tier 3b). Applies at platform-view
                // creation: toggle, then leave and re-enter this screen.
                Switch(
                  key: const ValueKey('feed_toggle_disk_cache'),
                  value: NativeVideoPlayerConfig.global.androidEnableDiskCache,
                  onChanged: (value) => setState(() {
                    NativeVideoPlayerConfig.global = _copyGlobalConfig(
                      androidEnableDiskCache: value,
                    );
                  }),
                ),
                TextButton(
                  key: const ValueKey('feed_precache'),
                  onPressed: _precacheStressVideos,
                  child: const Text('Precache'),
                ),
              ],
            ),
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

import 'package:flutter/material.dart';

import '../../models/video_item.dart';
import 'perf_hud.dart';
import 'stress_player_tile.dart';

/// Long lazy feed of players for fling-scroll jank measurement (B3 scenario).
///
/// `ListView.builder` disposes off-screen tiles, so fast scrolling exercises
/// rapid controller create/dispose cycles exactly like a real feed.
class ScrollFeedScreen extends StatelessWidget {
  const ScrollFeedScreen({super.key});

  static const int itemCount = 30;

  @override
  Widget build(BuildContext context) {
    final videos = VideoItem.getStressVideos(itemCount, idOffset: 9500);
    return Scaffold(
      appBar: AppBar(title: const Text('Scroll feed (30 players)')),
      body: Column(
        children: [
          const PerfHud(dumpLabel: 'scroll_feed'),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('scroll_feed_list'),
              itemCount: videos.length,
              itemBuilder: (context, index) => StressPlayerTile(
                key: ValueKey('scroll_feed_card_$index'),
                video: videos[index],
                index: index,
                onControllerCreated: (_) {},
              ),
            ),
          ),
        ],
      ),
    );
  }
}

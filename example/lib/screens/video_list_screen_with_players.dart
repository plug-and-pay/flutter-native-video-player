import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../widgets/video_player_card.dart';
import 'video_detail_screen_full.dart';
import 'subtitle_example_screen.dart';

class VideoListScreenWithPlayers extends StatelessWidget {
  const VideoListScreenWithPlayers({super.key});

  @override
  Widget build(BuildContext context) {
    final videos = VideoItem.getSampleVideos();

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        title: const Text(
          'Video Gallery',
          style: TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.closed_caption,
              color: Colors.black87,
            ),
            tooltip: 'Subtitle Examples',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SubtitleExampleScreen(),
                ),
              );
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: Colors.grey[200], height: 1),
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 16),
        itemCount: videos.length,
        addAutomaticKeepAlives: false,
        itemBuilder: (context, index) {
          final video = videos[index];
          // Use custom overlay for the first video to demonstrate inline custom controls or last
          final notUseCustomOverlay = index == 1;

          return VideoPlayerCard(
            key: ValueKey(video.id),
            video: video,
            useCustomOverlay: !notUseCustomOverlay,
            shouldShowVideo:
                index <
                videos.length - 2, // Show video only for the last 2 items
            onTap: (controller) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => VideoDetailScreenFull(
                    video: video,
                    controller: controller,
                    useCustomOverlay: !notUseCustomOverlay,
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // Test FAB - this should NOT be visible in PiP mode
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('FAB pressed')));
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

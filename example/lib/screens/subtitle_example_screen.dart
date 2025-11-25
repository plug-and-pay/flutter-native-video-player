import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../widgets/custom_video_overlay.dart';

/// Example screen demonstrating subtitle/closed caption support
/// Includes both VOD and Live HLS streams with subtitles
class SubtitleExampleScreen extends StatefulWidget {
  const SubtitleExampleScreen({super.key});

  @override
  State<SubtitleExampleScreen> createState() => _SubtitleExampleScreenState();
}

class _SubtitleExampleScreenState extends State<SubtitleExampleScreen> {
  late NativeVideoPlayerController _controller;
  bool _isLoadingSubtitles = false;
  List<NativeVideoPlayerSubtitleTrack> _availableSubtitles = [];

  final video = VideoItem(
    title: 'HLS VOD with Subtitles',
    description: 'Apple\'s Big Buck Bunny with multiple subtitle tracks',
    url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
    id: 1,
    artworkUrl: '',
  );

  @override
  void initState() {
    super.initState();
    _initializeController();
  }

  void _initializeController() {
    _controller = NativeVideoPlayerController(
      id: 999,
      autoPlay: true,
      mediaInfo: NativeVideoPlayerMediaInfo(title: video.title, subtitle: video.description),
    );

    _loadVideo(video.url);

    // Listen for video loaded event to fetch subtitles
    _controller.addActivityListener((event) {
      if (event.state == PlayerActivityState.playing) {
        _loadSubtitles();
      }
    });
  }

  Future<void> _loadVideo(String url) async {
    try {
      await _controller.initialize();
      await _controller.load(url: url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error loading video: $e')));
      }
    }
  }

  Future<void> _loadSubtitles() async {
    if (_isLoadingSubtitles) return;

    setState(() {
      _isLoadingSubtitles = true;
    });

    try {
      // Wait a bit for the video to fully load
      await Future.delayed(const Duration(seconds: 1));

      final subtitles = await _controller.getAvailableSubtitleTracks();

      if (mounted) {
        setState(() {
          _availableSubtitles = subtitles;
          _isLoadingSubtitles = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingSubtitles = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // App Bar
            Container(
              color: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Text(
                    'Subtitle Examples',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),

            // Video Player
            Expanded(
              flex: 2,
              child: NativeVideoPlayer(
                controller: _controller,
                overlayBuilder: (context, controller) => CustomVideoOverlay(controller: controller),
              ),
            ),

            // Subtitle Info Section
            Container(
              color: Colors.black87,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.closed_caption, color: Colors.white, size: 24),
                      const SizedBox(width: 12),
                      const Text(
                        'Available Subtitles',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      if (_isLoadingSubtitles)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_availableSubtitles.isEmpty && !_isLoadingSubtitles)
                    Text(
                      'No subtitles available for this video.\n'
                      'Note: Subtitles must be embedded in the HLS stream.',
                      style: TextStyle(color: Colors.grey[400], fontSize: 14),
                    )
                  else if (_availableSubtitles.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _availableSubtitles.map((track) {
                        return Chip(
                          label: Text(track.displayName, style: const TextStyle(fontSize: 12)),
                          backgroundColor: track.isSelected ? Colors.blue : Colors.grey[800],
                          labelStyle: TextStyle(color: track.isSelected ? Colors.white : Colors.grey[300]),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

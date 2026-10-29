import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:material_ui/material_ui.dart';

import '../models/video_item.dart';
import '../widgets/custom_video_overlay.dart';

/// Example screen demonstrating custom overlay with Dart fullscreen
class VideoWithOverlayScreen extends StatefulWidget {
  final VideoItem video;

  const VideoWithOverlayScreen({super.key, required this.video});

  @override
  State<VideoWithOverlayScreen> createState() => _VideoWithOverlayScreenState();
}

class _VideoWithOverlayScreenState extends State<VideoWithOverlayScreen> {
  late NativeVideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    _controller = NativeVideoPlayerController(
      id: widget.video.id,
      autoPlay: false,
      lockToLandscape: false,
      mediaInfo: NativeVideoPlayerMediaInfo(
        title: widget.video.title,
        subtitle: widget.video.description,
      ),
    );

    await _controller.initialize();
    await _controller.load(url: widget.video.url);
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
            // Video Player with Overlay
            AspectRatio(
              aspectRatio: 16 / 9,
              child: NativeVideoPlayer(
                controller: _controller,
                overlayBuilder: (context, controller) {
                  return CustomVideoOverlay(controller: controller);
                },
              ),
            ),

            // Details Section
            Expanded(
              child: Container(
                color: Colors.white,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.video.title,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          widget.video.description,
                          style: TextStyle(
                            fontSize: 15,
                            color: Colors.grey[700],
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Divider(),
                        const SizedBox(height: 16),
                        _buildFeatureList(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Features Demonstrated:',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 12),
        _buildFeatureItem(
          icon: Icons.layers,
          title: 'Custom Overlay',
          description:
              'Flutter-based overlay with custom controls on top of native player',
        ),
        _buildFeatureItem(
          icon: Icons.fullscreen,
          title: 'Dart Fullscreen',
          description: 'Fullscreen handled by Dart with system UI control',
        ),
        _buildFeatureItem(
          icon: Icons.touch_app,
          title: 'Auto-hide Controls',
          description:
              'Controls automatically hide after 3 seconds of inactivity',
        ),
        _buildFeatureItem(
          icon: Icons.play_circle_outline,
          title: 'Native Playback',
          description:
              'Still uses native video player (AVPlayer/ExoPlayer) for optimal performance',
        ),
      ],
    );
  }

  Widget _buildFeatureItem({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: Colors.blue, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

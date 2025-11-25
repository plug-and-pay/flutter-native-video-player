import 'package:flutter/material.dart';
import 'package:better_native_video_player/better_native_video_player.dart';
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

  // Example HLS streams with subtitles
  // Note: Replace these with your own HLS streams that have embedded subtitles
  final List<VideoExample> _videoExamples = [
    VideoExample(
      title: 'HLS VOD with Subtitles',
      subtitle: 'Apple\'s Big Buck Bunny with multiple subtitle tracks',
      url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
      isLive: false,
    ),
    VideoExample(
      title: 'HLS Live Stream Example',
      subtitle: 'Live stream with subtitle support',
      url: 'https://cph-p2p-msl.akamaized.net/hls/live/2000341/test/master.m3u8',
      isLive: true,
    ),
    VideoExample(
      title: 'Sintel with Subtitles',
      subtitle: 'Demo content with multiple languages',
      url: 'https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8',
      isLive: false,
    ),
  ];

  int _currentVideoIndex = 0;

  @override
  void initState() {
    super.initState();
    _initializeController();
  }

  void _initializeController() {
    _controller = NativeVideoPlayerController(
      id: 'subtitle-demo',
      autoPlay: true,
      mediaInfo: NativeVideoPlayerMediaInfo(
        title: _videoExamples[_currentVideoIndex].title,
        subtitle: _videoExamples[_currentVideoIndex].subtitle,
      ),
    );

    _loadVideo(_videoExamples[_currentVideoIndex].url);

    // Listen for video loaded event to fetch subtitles
    _controller.addActivityListener((event, data) {
      if (event == PlayerActivityState.playing) {
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading video: $e')),
        );
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

  void _switchVideo(int index) {
    if (index == _currentVideoIndex) return;

    setState(() {
      _currentVideoIndex = index;
      _availableSubtitles = [];
    });

    _loadVideo(_videoExamples[index].url);
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
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            // Video Player
            Expanded(
              flex: 2,
              child: NativeVideoPlayer(
                controller: _controller,
                overlayBuilder: (context) => CustomVideoOverlay(
                  controller: _controller,
                ),
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
                      const Icon(
                        Icons.closed_caption,
                        color: Colors.white,
                        size: 24,
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'Available Subtitles',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      if (_isLoadingSubtitles)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_availableSubtitles.isEmpty && !_isLoadingSubtitles)
                    Text(
                      'No subtitles available for this video.\n'
                      'Note: Subtitles must be embedded in the HLS stream.',
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 14,
                      ),
                    )
                  else if (_availableSubtitles.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _availableSubtitles.map((track) {
                        return Chip(
                          label: Text(
                            track.displayName,
                            style: const TextStyle(fontSize: 12),
                          ),
                          backgroundColor: track.isSelected
                              ? Colors.blue
                              : Colors.grey[800],
                          labelStyle: TextStyle(
                            color: track.isSelected
                                ? Colors.white
                                : Colors.grey[300],
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),

            // Video Selection Section
            Expanded(
              child: Container(
                color: Colors.grey[900],
                child: ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _videoExamples.length,
                  itemBuilder: (context, index) {
                    final example = _videoExamples[index];
                    final isSelected = index == _currentVideoIndex;

                    return Card(
                      color: isSelected ? Colors.blue[700] : Colors.grey[850],
                      child: ListTile(
                        leading: Icon(
                          example.isLive ? Icons.live_tv : Icons.movie,
                          color: Colors.white,
                        ),
                        title: Text(
                          example.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          example.subtitle,
                          style: TextStyle(
                            color: Colors.grey[300],
                            fontSize: 12,
                          ),
                        ),
                        trailing: isSelected
                            ? const Icon(
                                Icons.play_circle_filled,
                                color: Colors.white,
                              )
                            : const Icon(
                                Icons.play_circle_outline,
                                color: Colors.white70,
                              ),
                        onTap: () => _switchVideo(index),
                      ),
                    );
                  },
                ),
              ),
            ),

            // Instructions
            Container(
              color: Colors.black87,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'How to use subtitles:',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildInstructionItem(
                    '1. Enter fullscreen mode',
                    Icons.fullscreen,
                  ),
                  _buildInstructionItem(
                    '2. Tap the CC (closed caption) button',
                    Icons.closed_caption,
                  ),
                  _buildInstructionItem(
                    '3. Select your preferred subtitle language',
                    Icons.language,
                  ),
                  _buildInstructionItem(
                    '4. Adjust font size as needed',
                    Icons.format_size,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionItem(String text, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: Colors.blue, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Colors.grey[300],
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class VideoExample {
  final String title;
  final String subtitle;
  final String url;
  final bool isLive;

  const VideoExample({
    required this.title,
    required this.subtitle,
    required this.url,
    required this.isLive,
  });
}

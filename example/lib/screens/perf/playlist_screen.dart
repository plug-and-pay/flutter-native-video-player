import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

/// Demo + Marionette harness for [NativeVideoPlayerPlaylist] auto-advance.
/// "Seek to end" lets the harness trigger a `completed` event without
/// waiting out the full video.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  static const int controllerId = 9900;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  late final NativeVideoPlayerController _controller;
  late final NativeVideoPlayerPlaylist _playlist;
  StreamSubscription<int>? _indexSub;
  int _index = -1;

  @override
  void initState() {
    super.initState();
    _controller = NativeVideoPlayerController(
      id: PlaylistScreen.controllerId,
      autoPlay: true,
      lockToLandscape: false,
      showNativeControls: false,
    );
    _playlist = NativeVideoPlayerPlaylist(
      _controller,
      items: const [
        NativeVideoPlayerPlaylistItem(
          url: 'https://media.w3.org/2010/05/sintel/trailer.mp4',
        ),
        NativeVideoPlayerPlaylistItem(
          url: 'https://media.w3.org/2010/05/video/movie_300.mp4',
          startAt: Duration(seconds: 30),
        ),
        NativeVideoPlayerPlaylistItem(
          url:
              'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8',
        ),
      ],
    );
    _indexSub = _playlist.currentIndexStream.listen((index) {
      if (mounted) setState(() => _index = index);
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _controller.initialize();
      await _playlist.start();
    } catch (e) {
      debugPrint('PlaylistScreen start error: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_indexSub?.cancel());
    _playlist.dispose();
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playlist')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: NativeVideoPlayer(controller: _controller),
            ),
          ),
          ListTile(
            title: Text(
              'playlist index: $_index / ${_playlist.items.length - 1}',
              key: const ValueKey('playlist_index'),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                key: const ValueKey('playlist_prev'),
                onPressed: _playlist.previous,
                child: const Text('Previous'),
              ),
              ElevatedButton(
                key: const ValueKey('playlist_next'),
                onPressed: _playlist.next,
                child: const Text('Next'),
              ),
              ElevatedButton(
                key: const ValueKey('playlist_seek_end'),
                onPressed: () => _controller.seekTo(
                  _controller.duration - const Duration(seconds: 1),
                ),
                child: const Text('Seek to end'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

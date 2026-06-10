import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

/// Demo + Marionette harness for alternate audio track selection (#23/#16)
/// using Apple's bipbop-advanced HLS example stream (multiple audio
/// renditions).
class AudioTrackScreen extends StatefulWidget {
  const AudioTrackScreen({super.key});

  static const int controllerId = 9700;

  @override
  State<AudioTrackScreen> createState() => _AudioTrackScreenState();
}

class _AudioTrackScreenState extends State<AudioTrackScreen> {
  late final NativeVideoPlayerController _controller;
  List<NativeVideoPlayerAudioTrack> _tracks = const [];

  @override
  void initState() {
    super.initState();
    _controller = NativeVideoPlayerController(
      id: AudioTrackScreen.controllerId,
      autoPlay: true,
      lockToLandscape: false,
      showNativeControls: false,
    );
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _controller.initialize();
      await _controller.load(
        // Classic Apple bipbop: TWO selectable audio renditions in one group
        // ("BipBop Audio 1"/"BipBop Audio 2") + multi-language subtitles.
        url:
            'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8',
      );
      // Tracks become available once the manifest renditions are known.
      await Future<void>.delayed(const Duration(seconds: 2));
      await _refreshTracks();
    } catch (e) {
      debugPrint('AudioTrackScreen load error: $e');
    }
  }

  Future<void> _refreshTracks() async {
    final tracks = await _controller.getAvailableAudioTracks();
    if (mounted) setState(() => _tracks = tracks);
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Audio tracks')),
      body: ListView(
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
              'Audio tracks: ${_tracks.length}',
              key: const ValueKey('audio_track_count'),
            ),
            trailing: IconButton(
              key: const ValueKey('audio_track_refresh'),
              icon: const Icon(Icons.refresh),
              onPressed: _refreshTracks,
            ),
          ),
          for (var i = 0; i < _tracks.length; i++)
            ListTile(
              key: ValueKey('audio_track_$i'),
              title: Text(_tracks[i].displayName),
              subtitle: Text(_tracks[i].language),
              trailing: _tracks[i].isSelected
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : const Icon(Icons.radio_button_unchecked),
              onTap: () async {
                await _controller.setAudioTrack(_tracks[i]);
                await _refreshTracks();
              },
            ),
        ],
      ),
    );
  }
}

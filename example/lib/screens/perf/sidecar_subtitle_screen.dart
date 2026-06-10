import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Demo + Marionette harness for sidecar (external VTT/SRT) subtitles:
/// bundled English VTT and Dutch SRT sources on an MP4, selectable through
/// the merged track API, with live style/position controls.
class SidecarSubtitleScreen extends StatefulWidget {
  const SidecarSubtitleScreen({super.key});

  static const int controllerId = 9600;

  @override
  State<SidecarSubtitleScreen> createState() => _SidecarSubtitleScreenState();
}

class _SidecarSubtitleScreenState extends State<SidecarSubtitleScreen> {
  late final NativeVideoPlayerController _controller;
  List<NativeVideoPlayerSubtitleTrack> _tracks = const [];
  NativeVideoPlayerSubtitleStyle _style =
      const NativeVideoPlayerSubtitleStyle();

  @override
  void initState() {
    super.initState();
    _controller = NativeVideoPlayerController(
      id: SidecarSubtitleScreen.controllerId,
      autoPlay: true,
      lockToLandscape: false,
      showNativeControls: false,
    );
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _controller.initialize();
      final vtt = await rootBundle.loadString('assets/sample_en.vtt');
      final srt = await rootBundle.loadString('assets/sample_nl.srt');
      await _controller.load(
        url: 'https://media.w3.org/2010/05/sintel/trailer.mp4',
        sidecarSubtitles: [
          NativeVideoPlayerSidecarSubtitle.content(
            vtt,
            language: 'en',
            label: 'English (VTT)',
          ),
          NativeVideoPlayerSidecarSubtitle.content(
            srt,
            language: 'nl',
            label: 'Nederlands (SRT)',
          ),
        ],
      );
      await _refreshTracks();
    } catch (e) {
      debugPrint('SidecarSubtitleScreen load error: $e');
    }
  }

  Future<void> _refreshTracks() async {
    final tracks = await _controller.getAvailableSubtitleTracks();
    if (mounted) setState(() => _tracks = tracks);
  }

  Future<void> _select(NativeVideoPlayerSubtitleTrack track) async {
    await _controller.setSubtitleTrack(track);
    await _refreshTracks();
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sidecarTracks = _tracks
        .where((t) => t.source == SubtitleTrackSource.sidecar)
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Sidecar subtitles')),
      body: ListView(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: NativeVideoPlayer(
                controller: _controller,
                subtitleStyle: _style,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < sidecarTracks.length; i++)
                  ChoiceChip(
                    key: ValueKey('sidecar_select_$i'),
                    label: Text(sidecarTracks[i].displayName),
                    selected: sidecarTracks[i].isSelected,
                    onSelected: (_) => _select(sidecarTracks[i]),
                  ),
                ChoiceChip(
                  key: const ValueKey('sidecar_off'),
                  label: const Text('Off'),
                  selected: !sidecarTracks.any((t) => t.isSelected),
                  onSelected: (_) =>
                      _select(NativeVideoPlayerSubtitleTrack.off()),
                ),
              ],
            ),
          ),
          SwitchListTile(
            key: const ValueKey('subtitle_style_bigger'),
            title: const Text('Large text'),
            value: _style.fontSize > 20,
            onChanged: (big) => setState(() {
              _style = _style.copyWith(fontSize: big ? 26 : 16);
            }),
          ),
          SwitchListTile(
            key: const ValueKey('subtitle_style_top'),
            title: const Text('Show at top'),
            value: _style.alignment == Alignment.topCenter,
            onChanged: (top) => setState(() {
              _style = _style.copyWith(
                alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
                padding: top
                    ? const EdgeInsets.only(top: 24, left: 16, right: 16)
                    : const EdgeInsets.only(bottom: 24, left: 16, right: 16),
              );
            }),
          ),
          SwitchListTile(
            key: const ValueKey('subtitle_style_yellow'),
            title: const Text('Yellow text'),
            value: _style.textColor != const Color(0xFFFFFFFF),
            onChanged: (yellow) => setState(() {
              _style = _style.copyWith(
                textColor: yellow
                    ? const Color(0xFFFFEB3B)
                    : const Color(0xFFFFFFFF),
              );
            }),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ElevatedButton(
                  key: const ValueKey('sidecar_seek_back'),
                  onPressed: () => _controller.seekTo(Duration.zero),
                  child: const Text('Seek 0:00'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  key: const ValueKey('sidecar_seek_10'),
                  onPressed: () =>
                      _controller.seekTo(const Duration(seconds: 10)),
                  child: const Text('Seek 0:10'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

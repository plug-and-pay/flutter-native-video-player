import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// AirPlay caption test bench. Two sources demonstrate the two caption
/// paths over AirPlay:
///
/// - **HLS + embedded tracks** (Apple bipbop): selecting an embedded track
///   travels WITH the stream — the AirPlay receiver (Apple TV) renders the
///   captions itself.
/// - **MP4 + sidecar VTT** (bundled asset or any injected URL): cues are
///   rendered by the plugin's Flutter overlay, which lives on the PHONE —
///   during AirPlay they keep showing here, not on the TV. That is an iOS
///   platform limitation (no client-side way to inject VTT into an
///   AirPlay-ed stream); ship embedded tracks when you need them on the
///   receiver.
class AirPlaySubtitleScreen extends StatefulWidget {
  const AirPlaySubtitleScreen({super.key});

  static const int controllerId = 9800;

  /// HLS stream with embedded WebVTT subtitle renditions (English a.o.).
  static const String hlsUrl =
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8';

  /// Plain MP4 — captions come from the sidecar VTT instead.
  static const String mp4Url =
      'https://media.w3.org/2010/05/sintel/trailer.mp4';

  @override
  State<AirPlaySubtitleScreen> createState() => _AirPlaySubtitleScreenState();
}

class _AirPlaySubtitleScreenState extends State<AirPlaySubtitleScreen> {
  late final NativeVideoPlayerController _controller;
  final TextEditingController _vttUrlField = TextEditingController();
  StreamSubscription<bool>? _airPlaySub;

  List<NativeVideoPlayerSubtitleTrack> _tracks = const [];
  bool _useHls = false;
  bool _airPlayAvailable = false;
  bool _airPlayConnected = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _controller = NativeVideoPlayerController(
      id: AirPlaySubtitleScreen.controllerId,
      autoPlay: true,
      lockToLandscape: false,
      showNativeControls: false,
    );
    _controller.addAirPlayAvailabilityListener(_onAirPlayAvailable);
    _airPlaySub = _controller.isAirplayConnectedStream.listen((connected) {
      if (mounted) setState(() => _airPlayConnected = connected);
    });
    unawaited(_load());
  }

  void _onAirPlayAvailable(bool available) {
    if (mounted) setState(() => _airPlayAvailable = available);
  }

  Future<void> _load() async {
    setState(() => _status = 'loading…');
    try {
      await _controller.initialize();
      if (_useHls) {
        // Embedded tracks come from the stream itself; no sidecars needed.
        await _controller.load(url: AirPlaySubtitleScreen.hlsUrl, force: true);
      } else {
        final vtt = await rootBundle.loadString('assets/sample_en.vtt');
        await _controller.load(
          url: AirPlaySubtitleScreen.mp4Url,
          force: true,
          sidecarSubtitles: [
            NativeVideoPlayerSidecarSubtitle.content(
              vtt,
              language: 'en',
              label: 'English (bundled VTT)',
            ),
          ],
        );
      }
      // Embedded HLS tracks can take a moment to be reported.
      await Future<void>.delayed(const Duration(seconds: 1));
      await _refreshTracks();
      if (mounted) setState(() => _status = null);
    } catch (e) {
      if (mounted) setState(() => _status = 'load failed: $e');
    }
  }

  /// Injects any VTT/SRT by URL into the CURRENT video (post-load API).
  Future<void> _injectVttUrl() async {
    final url = _vttUrlField.text.trim();
    if (url.isEmpty) return;
    try {
      await _controller.setSidecarSubtitles([
        NativeVideoPlayerSidecarSubtitle.url(
          url,
          language: 'en',
          label: 'Injected: ${url.split('/').last}',
        ),
      ]);
      await _refreshTracks();
      if (mounted) setState(() => _status = 'sidecar injected: $url');
    } catch (e) {
      if (mounted) setState(() => _status = 'inject failed: $e');
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
    _controller.removeAirPlayAvailabilityListener(_onAirPlayAvailable);
    unawaited(_airPlaySub?.cancel());
    _vttUrlField.dispose();
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AirPlay + subtitles')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: NativeVideoPlayer(controller: _controller),
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            key: const ValueKey('airplay_source_toggle'),
            segments: const [
              ButtonSegment(value: false, label: Text('MP4 + sidecar VTT')),
              ButtonSegment(value: true, label: Text('HLS + embedded')),
            ],
            selected: {_useHls},
            onSelectionChanged: (selection) {
              setState(() => _useHls = selection.first);
              unawaited(_load());
            },
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                _status!,
                key: const ValueKey('airplay_status'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.airplay,
              color: _airPlayConnected
                  ? Colors.blue
                  : _airPlayAvailable
                  ? null
                  : Colors.grey,
            ),
            title: Text(
              _airPlayConnected
                  ? 'AirPlay: CONNECTED'
                  : _airPlayAvailable
                  ? 'AirPlay: available'
                  : 'AirPlay: no receivers found',
              key: const ValueKey('airplay_state'),
            ),
            trailing: ElevatedButton(
              key: const ValueKey('airplay_picker'),
              onPressed: () => _controller.showAirPlayPicker(),
              child: const Text('AirPlay…'),
            ),
          ),
          const Divider(),
          const Text('Subtitle tracks (embedded + sidecar merged):'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _tracks.length; i++)
                ChoiceChip(
                  key: ValueKey('airplay_track_$i'),
                  label: Text(
                    '${_tracks[i].displayName}'
                    ' [${_tracks[i].source.name}]',
                  ),
                  selected: _tracks[i].isSelected,
                  onSelected: (_) => _select(_tracks[i]),
                ),
              ChoiceChip(
                key: const ValueKey('airplay_track_off'),
                label: const Text('Off'),
                selected: !_tracks.any((t) => t.isSelected),
                onSelected: (_) =>
                    _select(NativeVideoPlayerSubtitleTrack.off()),
              ),
            ],
          ),
          const Divider(),
          TextField(
            key: const ValueKey('airplay_vtt_url'),
            controller: _vttUrlField,
            decoration: const InputDecoration(
              labelText: 'Inject sidecar VTT/SRT by URL into current video',
              hintText: 'https://…/captions.vtt',
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            key: const ValueKey('airplay_inject_vtt'),
            onPressed: _injectVttUrl,
            child: const Text('Inject VTT'),
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'What to expect over AirPlay:\n'
                '• HLS + embedded track → captions render ON the Apple TV '
                '(selection travels with the stream).\n'
                '• Sidecar VTT → cues are a Flutter overlay on the phone; '
                'the receiver shows only the video. This is an iOS platform '
                'limitation — ship embedded tracks when captions must appear '
                'on the TV.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

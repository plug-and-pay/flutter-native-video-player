import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

/// Demo + Marionette harness for the player-feature wave: `load(startAt:)`,
/// A-B playback range, position checkpoints, playback analytics and
/// storyboard parsing. Every readout is keyed so the MCP can assert on it.
class PlayerFeaturesScreen extends StatefulWidget {
  const PlayerFeaturesScreen({super.key});

  static const int controllerId = 9800;

  @override
  State<PlayerFeaturesScreen> createState() => _PlayerFeaturesScreenState();
}

class _PlayerFeaturesScreenState extends State<PlayerFeaturesScreen> {
  late final NativeVideoPlayerController _controller;
  late final PlaybackAnalytics _analytics;
  late final PositionCheckpoints _checkpoints;
  BackgroundPlaybackGuard? _guard;

  final List<String> _analyticsLog = [];
  Duration _position = Duration.zero;
  Duration? _lastCheckpoint;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlaybackAnalyticsEvent>? _analyticsSub;
  bool _pauseInBackground = false;

  static const _storyboardVtt = '''
WEBVTT

00:00:00.000 --> 00:00:10.000
sprite1.jpg#xywh=0,0,160,90

00:00:10.000 --> 00:00:20.000
sprite1.jpg#xywh=160,0,160,90

00:00:20.000 --> 00:00:30.000
sprite2.jpg#xywh=0,0,160,90
''';
  late final StoryboardThumbnails _storyboard = StoryboardThumbnails.parseVtt(
    _storyboardVtt,
    baseUrl: Uri.parse('https://cdn.example.com/sb/board.vtt'),
  );

  @override
  void initState() {
    super.initState();
    _controller = NativeVideoPlayerController(
      id: PlayerFeaturesScreen.controllerId,
      autoPlay: true,
      lockToLandscape: false,
      showNativeControls: false,
    );
    _analytics = PlaybackAnalytics(_controller);
    _analyticsSub = _analytics.events.listen((event) {
      if (!mounted) return;
      setState(() => _analyticsLog.add(event.toString()));
    });
    _checkpoints = PositionCheckpoints(
      _controller,
      interval: const Duration(seconds: 3),
      onCheckpoint: (position) {
        if (mounted) setState(() => _lastCheckpoint = position);
      },
    );
    _positionSub = _controller.positionStream.listen((position) {
      if (mounted) setState(() => _position = position);
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await _controller.initialize();
      // startAt demo: playback must begin around 20s, not at 0.
      await _controller.load(
        url: 'https://media.w3.org/2010/05/sintel/trailer.mp4',
        startAt: const Duration(seconds: 20),
      );
    } catch (e) {
      debugPrint('PlayerFeaturesScreen load error: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_positionSub?.cancel());
    unawaited(_analyticsSub?.cancel());
    _checkpoints.dispose();
    _analytics.dispose();
    _guard?.dispose();
    unawaited(_controller.dispose());
    super.dispose();
  }

  String _fmt(Duration d) =>
      '${d.inSeconds}.${(d.inMilliseconds % 1000) ~/ 100}s';

  @override
  Widget build(BuildContext context) {
    final range = _controller.playbackRange;
    final sbAt15 = _storyboard.thumbnailAt(const Duration(seconds: 15));
    return Scaffold(
      appBar: AppBar(title: const Text('Player features')),
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
              'position: ${_fmt(_position)}',
              key: const ValueKey('features_position'),
            ),
            subtitle: Text(
              'checkpoint: ${_lastCheckpoint == null ? '-' : _fmt(_lastCheckpoint!)}',
              key: const ValueKey('features_checkpoint'),
            ),
          ),
          ListTile(
            title: Text(
              range == null
                  ? 'range: none'
                  : 'range: ${_fmt(range.start)}-${_fmt(range.end)} '
                        '(loop: ${range.loop})',
              key: const ValueKey('features_range'),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                key: const ValueKey('features_ab_set'),
                onPressed: () async {
                  await _controller.setPlaybackRange(
                    start: const Duration(seconds: 5),
                    end: const Duration(seconds: 10),
                  );
                  setState(() {});
                },
                child: const Text('A-B loop 5-10s'),
              ),
              ElevatedButton(
                key: const ValueKey('features_ab_clear'),
                onPressed: () {
                  _controller.clearPlaybackRange();
                  setState(() {});
                },
                child: const Text('Clear range'),
              ),
              ElevatedButton(
                key: const ValueKey('features_restart_at_20'),
                onPressed: () => _controller.load(
                  url: 'https://media.w3.org/2010/05/sintel/trailer.mp4',
                  startAt: const Duration(seconds: 20),
                  force: true,
                ),
                child: const Text('Reload startAt 20s'),
              ),
            ],
          ),
          SwitchListTile(
            key: const ValueKey('features_bg_guard_toggle'),
            title: const Text('Pause in background (guard)'),
            value: _pauseInBackground,
            onChanged: (value) {
              setState(() => _pauseInBackground = value);
              if (value) {
                _guard ??= BackgroundPlaybackGuard(_controller);
                _guard!.pauseInBackground = true;
              } else {
                _guard?.pauseInBackground = false;
              }
            },
          ),
          ListTile(
            title: Text(
              'storyboard: ${_storyboard.entries.length} entries, '
              '15s -> ${sbAt15?.url.split('/').last} ${sbAt15?.region}',
              key: const ValueKey('features_storyboard'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Analytics events:'),
          ),
          for (var i = 0; i < _analyticsLog.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Text(
                _analyticsLog[i],
                key: ValueKey('features_analytics_$i'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

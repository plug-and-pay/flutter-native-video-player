import 'package:flutter/material.dart';

import 'airplay_subtitle_screen.dart';
import 'audio_track_screen.dart';
import 'cast_screen.dart';
import 'download_screen.dart';
import 'extractor_screen.dart';
import 'lifecycle_stress_screen.dart';
import 'nav_loop_screen.dart';
import 'pip_screen.dart';
import 'player_features_screen.dart';
import 'playlist_screen.dart';
import 'scroll_feed_screen.dart';
import 'sidecar_subtitle_screen.dart';
import 'stress_feed_screen.dart';

/// Hub for the performance/stress harness screens. Every entry is keyed so
/// the harness can be driven via the Marionette MCP.
class PerfMenuScreen extends StatelessWidget {
  const PerfMenuScreen({super.key});

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Performance harness')),
      body: ListView(
        children: [
          ListTile(
            key: const ValueKey('perf_feed_n2'),
            title: const Text('Stress feed — 2 players'),
            onTap: () => _push(context, const StressFeedScreen(playerCount: 2)),
          ),
          ListTile(
            key: const ValueKey('perf_feed_n4'),
            title: const Text('Stress feed — 4 players'),
            onTap: () => _push(context, const StressFeedScreen(playerCount: 4)),
          ),
          ListTile(
            key: const ValueKey('perf_feed_n6'),
            title: const Text('Stress feed — 6 players'),
            onTap: () => _push(context, const StressFeedScreen(playerCount: 6)),
          ),
          ListTile(
            key: const ValueKey('perf_scroll_feed'),
            title: const Text('Scroll feed — 30 players'),
            onTap: () => _push(context, const ScrollFeedScreen()),
          ),
          ListTile(
            key: const ValueKey('perf_nav_loop'),
            title: const Text('Nav loop — shared controller ID'),
            onTap: () => _push(context, const NavLoopScreen()),
          ),
          ListTile(
            key: const ValueKey('perf_lifecycle_stress'),
            title: const Text('Lifecycle stress — MPE repro'),
            onTap: () => _push(context, const LifecycleStressScreen()),
          ),
          ListTile(
            key: const ValueKey('perf_pip'),
            title: const Text('PiP harness'),
            onTap: () => _push(context, const PipScreen()),
          ),
          ListTile(
            key: const ValueKey('feature_sidecar_subs'),
            title: const Text('Sidecar subtitles (VTT/SRT)'),
            onTap: () => _push(context, const SidecarSubtitleScreen()),
          ),
          ListTile(
            key: const ValueKey('feature_audio_tracks'),
            title: const Text('Audio track selection'),
            onTap: () => _push(context, const AudioTrackScreen()),
          ),
          ListTile(
            key: const ValueKey('feature_player_features'),
            title: const Text('Player features (startAt, A-B, analytics)'),
            onTap: () => _push(context, const PlayerFeaturesScreen()),
          ),
          ListTile(
            key: const ValueKey('feature_playlist'),
            title: const Text('Playlist auto-advance'),
            onTap: () => _push(context, const PlaylistScreen()),
          ),
          ListTile(
            key: const ValueKey('feature_extractor'),
            title: const Text('Vimeo extractor (no WebView)'),
            onTap: () => _push(context, const ExtractorScreen()),
          ),
          ListTile(
            key: const ValueKey('feature_downloads'),
            title: const Text('Downloads (offline playback)'),
            onTap: () => _push(context, const DownloadScreen()),
          ),
          ListTile(
            key: const ValueKey('feature_cast'),
            title: const Text('Chromecast (discover + control)'),
            onTap: () => _push(context, const CastScreen()),
          ),
          ListTile(
            key: const ValueKey('feature_airplay_subs'),
            title: const Text('AirPlay + subtitles (VTT)'),
            onTap: () => _push(context, const AirPlaySubtitleScreen()),
          ),
        ],
      ),
    );
  }
}

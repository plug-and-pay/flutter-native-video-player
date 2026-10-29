// better_native_video_player — the showcase.
//
// One file, every feature, four tabs:
//
//   Watch  · HLS with quality, captions, audio tracks, speed, A-B loop,
//            Picture-in-Picture, AirPlay, Chromecast, a poster with an
//            animated preview, scrub previews, fullscreen that flies out of
//            the page (swipe down to close) and live playback analytics.
//   Live   · live HLS with a DVR scrubber and a jump-to-live button.
//   Feed   · a scrolling feed of players with posters, duration badges and
//            offline downloads, tuned by NativeVideoPlayerConfig.
//   Binge  · a playlist with auto-advance and remembered resume positions.
//
// Videos: Blender Foundation open movies (CC BY), served by Mux, W3C and
// Unified Streaming test CDNs. Run it with `flutter run` from `example/`.

import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:better_native_video_player/cast.dart' as cast;
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  // Tuning for the whole app, set once before the first controller exists.
  NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
    maxConcurrentPlayingPlayers: 2, // a feed never decodes more than two
    qualityForViewportSize: true, // small tiles stream small renditions
    lightweightInlineViews: true, // bare video surfaces under custom controls
    prioritizeActivePlayback:
        true, // Android: the playing tile gets the network
    androidEnableDiskCache: true, // Android: replays come from disk
    androidTextureMode: true, // Android: fullscreen flies out of the tile
    bufferingTimeout: Duration(seconds: 20), // endless spinner -> error state
  );
  runApp(const ShowcaseApp());
}

// ─── Catalog ─────────────────────────────────────────────────────────────

class Film {
  const Film({
    required this.title,
    required this.credit,
    required this.url,
    this.poster,
    this.length,
    this.isLive = false,
  });

  final String title;
  final String credit;
  final String url;
  final String? poster;
  final Duration? length;
  final bool isLive;

  bool get isHls => url.contains('.m3u8');
}

abstract final class Films {
  static const bigBuckBunny = Film(
    title: 'Big Buck Bunny',
    credit: 'Blender Foundation · 2008',
    url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    poster:
        'https://peach.blender.org/wp-content/uploads/title_anouncement.jpg',
    length: Duration(minutes: 10, seconds: 34),
  );
  static const sintel = Film(
    title: 'Sintel',
    credit: 'Blender Foundation · trailer',
    url: 'https://media.w3.org/2010/05/sintel/trailer.mp4',
    poster:
        'https://durian.blender.org/wp-content/uploads/2010/06/05.8b_comp_000272.jpg',
    length: Duration(seconds: 52),
  );
  static const tearsOfSteel = Film(
    title: 'Tears of Steel',
    credit: 'Blender Foundation · 2012',
    url:
        'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8',
    poster:
        'https://mango.blender.org/wp-content/uploads/2013/05/01_thom_celia_bridge.jpg',
    length: Duration(minutes: 12, seconds: 14),
  );
  static const bunnyTrailer = Film(
    title: 'Big Buck Bunny',
    credit: 'Blender Foundation · trailer',
    url: 'https://media.w3.org/2010/05/bunny/trailer.mp4',
    poster:
        'https://peach.blender.org/wp-content/uploads/title_anouncement.jpg',
    length: Duration(seconds: 33),
  );
  static const liveSignal = Film(
    title: 'Test signal',
    credit: 'Unified Streaming · live clock',
    url: 'https://demo.unified-streaming.com/k8s/live/stable/live.isml/.m3u8',
    isLive: true,
  );
  static const liveBlender = Film(
    title: 'Blender 24/7',
    credit: 'iReplay.tv · open movies, live',
    url: 'https://ireplay.tv/test/blender.m3u8',
    isLive: true,
  );
}

/// Scrub previews for Big Buck Bunny: one sprite sheet, a frame every 10 s.
/// From Bunny Stream it is one line:
/// `StoryboardThumbnails.bunny(videoBaseUrl: 'https://vz-….b-cdn.net/<id>', duration: length)`.
final _bunnyStoryboard = StoryboardThumbnails.fromUniformGrid(
  spriteUrls: const ['assets/showcase/storyboard.jpg'],
  frameInterval: const Duration(seconds: 10),
  columns: 10,
  frameWidth: 160,
  frameHeight: 90,
  framesPerSprite: 60,
);

/// Chapters for Big Buck Bunny, written the way a video description lists
/// them. `NativeVideoPlayerChapters.parseVtt` reads a WebVTT chapters track.
final _bunnyChapters = NativeVideoPlayerChapters.parseText('''
0:00 Morning in the meadow
1:12 A butterfly visits
2:05 Three troublemakers
3:35 The last straw
5:20 Building the traps
7:10 Payback
9:15 Credits
''');

/// Big Buck Bunny has no dialogue, so these are sound captions: sidecar
/// WebVTT, rendered and styled by Flutter. Pass `.url(...)` or `.file(...)`
/// for captions that live elsewhere.
const _bunnyCaptions = [
  NativeVideoPlayerSidecarSubtitle.content(
    '''WEBVTT

00:00:03.000 --> 00:00:09.000
♪ soft woodwinds ♪

00:01:00.000 --> 00:01:06.000
[Bunny yawns and stretches]

00:01:20.000 --> 00:01:26.000
[a butterfly flutters by]

00:02:10.000 --> 00:02:16.000
[three rodents snicker]

00:05:30.000 --> 00:05:36.000
[a bowstring creaks]

00:07:20.000 --> 00:07:26.000
[a flying squirrel whooshes past]
''',
    language: 'en',
    label: 'English',
  ),
  NativeVideoPlayerSidecarSubtitle.content(
    '''WEBVTT

00:00:03.000 --> 00:00:09.000
♪ zachte houtblazers ♪

00:01:00.000 --> 00:01:06.000
[Bunny gaapt en rekt zich uit]

00:01:20.000 --> 00:01:26.000
[een vlinder fladdert voorbij]

00:02:10.000 --> 00:02:16.000
[drie knaagdieren grinniken]

00:05:30.000 --> 00:05:36.000
[een boogpees kraakt]

00:07:20.000 --> 00:07:26.000
[een vliegende eekhoorn zoeft voorbij]
''',
    language: 'nl',
    label: 'Nederlands',
  ),
];

// ─── App ─────────────────────────────────────────────────────────────────

abstract final class Palette {
  static const background = Color(0xFF09090F);
  static const surface = Color(0xFF14141D);
  static const raised = Color(0xFF1D1D29);
  static const line = Color(0x1AFFFFFF);
  static const muted = Color(0xFF9C9CB3);
  static const violet = Color(0xFF8B5CF6);
  static const pink = Color(0xFFEC4899);
  static const live = Color(0xFFFF3B47);
  static const brand = LinearGradient(colors: [violet, pink]);
}

class ShowcaseApp extends StatelessWidget {
  const ShowcaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Palette.violet,
        brightness: Brightness.dark,
        surface: Palette.surface,
      ),
    );
    return MaterialApp(
      title: 'Native Video Player',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: Palette.background,
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Palette.surface,
          indicatorColor: Color(0x338B5CF6),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Palette.surface,
          showDragHandle: true,
        ),
        sliderTheme: const SliderThemeData(
          trackHeight: 3,
          activeTrackColor: Palette.violet,
          inactiveTrackColor: Color(0x33FFFFFF),
          secondaryActiveTrackColor: Color(0x66FFFFFF),
          thumbColor: Colors.white,
          overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        ),
      ),
      home: const ShowcaseHome(),
    );
  }
}

class ShowcaseHome extends StatefulWidget {
  const ShowcaseHome({super.key});

  @override
  State<ShowcaseHome> createState() => _ShowcaseHomeState();
}

class _ShowcaseHomeState extends State<ShowcaseHome> {
  int _tab = 0;

  /// The Watch tab's player lives here, not in the tab, so it outlives the
  /// tab: a Picture-in-Picture window keeps playing while you browse, and
  /// "back to app" in the window brings you back to it.
  final hero = NativeVideoPlayerController(
    id: 1,
    mediaInfo: const NativeVideoPlayerMediaInfo(
      title: 'Big Buck Bunny',
      subtitle: 'Blender Foundation',
      artworkUrl:
          'https://peach.blender.org/wp-content/uploads/title_anouncement.jpg',
    ),
    fullscreenFlightBorderRadius: BorderRadius.circular(20),
    // Fullscreen follows the phone: portrait stays portrait (swipe down to
    // close), turn it sideways for landscape.
    lockToLandscape: false,
  );
  late final analytics = PlaybackAnalytics(hero);
  late final backgroundGuard = BackgroundPlaybackGuard(
    hero,
    pauseInBackground: false,
  );

  @override
  void initState() {
    super.initState();
    hero.onPictureInPictureRestore = () => setState(() => _tab = 0);
  }

  @override
  void dispose() {
    analytics.dispose();
    backgroundGuard.dispose();
    hero.dispose();
    super.dispose();
  }

  void _selectTab(int tab) {
    // Leaving the Watch tab pauses the hero, unless it plays in a window.
    if (_tab == 0 && tab != 0 && !hero.isPipEnabled) hero.pause();
    setState(() => _tab = tab);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: switch (_tab) {
          0 => WatchTab(
            controller: hero,
            analytics: analytics,
            guard: backgroundGuard,
          ),
          1 => const LiveTab(),
          2 => const FeedTab(),
          _ => const BingeTab(),
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _selectTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline_rounded),
            selectedIcon: Icon(Icons.play_circle_rounded),
            label: 'Watch',
          ),
          NavigationDestination(
            icon: Icon(Icons.sensors_rounded),
            label: 'Live',
          ),
          NavigationDestination(
            icon: Icon(Icons.view_agenda_outlined),
            selectedIcon: Icon(Icons.view_agenda_rounded),
            label: 'Feed',
          ),
          NavigationDestination(
            icon: Icon(Icons.queue_play_next_rounded),
            label: 'Binge',
          ),
        ],
      ),
    );
  }
}

// ─── Watch ───────────────────────────────────────────────────────────────

class WatchTab extends StatefulWidget {
  const WatchTab({
    super.key,
    required this.controller,
    required this.analytics,
    required this.guard,
  });

  final NativeVideoPlayerController controller;
  final PlaybackAnalytics analytics;
  final BackgroundPlaybackGuard guard;

  @override
  State<WatchTab> createState() => _WatchTabState();
}

class _WatchTabState extends State<WatchTab> {
  NativeVideoPlayerController get c => widget.controller;
  cast.CastSession? _castSession;
  double _captionScale = 1.0;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    await c.initialize();
    // load() is a no-op when the video is already loaded (coming back from
    // another tab), so the player picks up where it was.
    await c.load(
      url: Films.bigBuckBunny.url,
      sidecarSubtitles: _bunnyCaptions,
      chapters: _bunnyChapters,
      headers: const {'User-Agent': 'better_native_video_player showcase'},
    );
    // App-wide AirPlay route detection, once a player exists (iOS only;
    // a no-op elsewhere).
    await AirPlayStateManager.instance.init();
  }

  @override
  void dispose() {
    unawaited(_castSession?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const _Header(
          eyebrow: 'better_native_video_player',
          title: 'Native video,\nFlutter controls.',
        ),
        const SizedBox(height: 16),
        _VideoFrame(
          child: NativeVideoPlayer(
            controller: c,
            poster: NativeVideoPlayerPoster(
              image: NetworkImage(Films.bigBuckBunny.poster!),
              alignment: const Alignment(-0.6, 0), // keep the bunny in frame
              animation: const AssetImage('assets/showcase/preview.webp'),
              animationDelay: const Duration(seconds: 2),
              duration: Films.bigBuckBunny.length,
              badgeAlignment: Alignment.bottomLeft,
            ),
            // Sidecar captions are drawn by Flutter: style them freely.
            subtitleStyle: NativeVideoPlayerSubtitleStyle(
              fontSize: 16 * _captionScale,
              fontWeight: FontWeight.w600,
              backgroundColor: Color(0x99000000),
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 48),
            ),
            overlayBuilder: (context, controller) => CinemaControls(
              controller: controller,
              title: Films.bigBuckBunny.title,
              storyboard: _bunnyStoryboard,
            ),
          ),
        ),
        if (_castSession != null)
          _CastBanner(
            session: _castSession!,
            onStop: () async {
              await _castSession?.close();
              setState(() => _castSession = null);
            },
          ),
        const SizedBox(height: 18),
        Text(
          Films.bigBuckBunny.title,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        const Text(
          'Blender Foundation · HLS · 5 renditions · captions EN / NL',
          style: TextStyle(color: Palette.muted),
        ),
        const SizedBox(height: 20),
        _FeatureDeck(controller: c, onCast: () => _openCastSheet(context)),
        const SizedBox(height: 20),
        _StatsPanel(controller: c, analytics: widget.analytics),
        const SizedBox(height: 20),
        _Panel(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Loop'),
                subtitle: const Text('Seamless native looping'),
                value: _looping,
                onChanged: (on) {
                  setState(() => _looping = on);
                  c.setLooping(on);
                },
              ),
              SwitchListTile(
                title: const Text('Pause in background'),
                subtitle: const Text('BackgroundPlaybackGuard · PiP exempt'),
                value: widget.guard.pauseInBackground,
                onChanged: (on) =>
                    setState(() => widget.guard.pauseInBackground = on),
              ),
              ListTile(
                title: const Text('Caption size'),
                subtitle: Slider(
                  value: _captionScale,
                  min: 0.75,
                  max: 2,
                  onChanged: (scale) {
                    // Sidecar captions scale with subtitleStyle above,
                    // embedded HLS captions through the native renderer.
                    setState(() => _captionScale = scale);
                    c.setNativeSubtitleTextScale(scale);
                  },
                ),
                trailing: Text('${(_captionScale * 100).round()}%'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  bool _looping = false;

  Future<void> _openCastSheet(BuildContext context) async {
    final session = await showModalBottomSheet<cast.CastSession>(
      context: context,
      builder: (_) => const _CastPicker(),
    );
    if (session == null) return;
    await session.loadMedia(
      contentUrl: Films.bigBuckBunny.url,
      contentType: 'application/x-mpegURL',
      title: Films.bigBuckBunny.title,
      subtitle: Films.bigBuckBunny.credit,
      imageUrl: Films.bigBuckBunny.poster,
      startAt: c.currentPosition,
    );
    await c.pause();
    setState(() => _castSession = session);
  }
}

/// Speed, quality, captions, audio, A-B loop, PiP, AirPlay and Cast.
class _FeatureDeck extends StatelessWidget {
  const _FeatureDeck({required this.controller, required this.onCast});

  final NativeVideoPlayerController controller;
  final VoidCallback onCast;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    return PlayerBuilder(
      controller: c,
      builder: (context, c) {
        final range = c.playbackRange;
        final tiles = <_DeckTile>[
          _DeckTile(
            icon: Icons.high_quality_rounded,
            label: 'Quality',
            value: _qualityLabel(c),
            onTap: () => _pickQuality(context),
          ),
          _DeckTile(
            icon: Icons.closed_caption_rounded,
            label: 'Captions',
            value: 'EN · NL',
            onTap: () => _pickCaptions(context),
          ),
          _DeckTile(
            icon: Icons.graphic_eq_rounded,
            label: 'Audio',
            value: 'Tracks',
            onTap: () => _pickAudio(context),
          ),
          _DeckTile(
            icon: Icons.speed_rounded,
            label: 'Speed',
            value: '${_trim(c.speed)}×',
            onTap: () => _pickSpeed(context),
          ),
          _DeckTile(
            icon: Icons.repeat_one_rounded,
            label: 'A-B loop',
            value: range == null
                ? 'Off'
                : '${_fmt(range.start)}–${_fmt(range.end)}',
            active: range != null,
            onTap: () {
              if (range != null) {
                c.clearPlaybackRange();
              } else {
                final start = c.currentPosition;
                c.setPlaybackRange(
                  start: start,
                  end: start + const Duration(seconds: 8),
                );
              }
            },
          ),
          _DeckTile(
            icon: Icons.picture_in_picture_alt_rounded,
            label: 'Picture in picture',
            value: c.isPipEnabled ? 'On' : 'Float',
            active: c.isPipEnabled,
            onTap: () => c.togglePictureInPicture(),
          ),
          if (ios)
            _DeckTile(
              icon: Icons.airplay_rounded,
              label: 'AirPlay',
              value: c.airPlayDeviceName ?? 'Devices',
              active: c.isAirplayConnected,
              onTap: () => c.showAirPlayPicker(),
            ),
          _DeckTile(
            icon: Icons.cast_rounded,
            label: 'Cast',
            value: 'Scan',
            onTap: onCast,
          ),
        ];
        return GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.82,
          children: tiles,
        );
      },
    );
  }

  String _qualityLabel(NativeVideoPlayerController c) {
    final levels = c.qualities.where((q) => !q.isAuto).length;
    return levels == 0 ? 'Auto' : '$levels levels';
  }

  Future<void> _pickQuality(BuildContext context) async {
    final quality = await _pick<NativeVideoPlayerQuality>(
      context,
      title: 'Quality',
      options: {
        for (final q in controller.qualities)
          q: q.isAuto ? 'Auto' : (q.height != null ? '${q.height}p' : q.label),
      },
    );
    if (quality != null) await controller.setQuality(quality);
  }

  Future<void> _pickCaptions(BuildContext context) async {
    final tracks = await controller.getAvailableSubtitleTracks();
    if (!context.mounted) return;
    final track = await _pick<NativeVideoPlayerSubtitleTrack>(
      context,
      title: 'Captions',
      options: {
        NativeVideoPlayerSubtitleTrack.off(): 'Off',
        for (final t in tracks)
          t: t.source == SubtitleTrackSource.sidecar
              ? '${t.displayName}  ·  sidecar VTT'
              : t.displayName,
      },
      selected: (t) => t.isSelected,
    );
    if (track != null) await controller.setSubtitleTrack(track);
  }

  Future<void> _pickAudio(BuildContext context) async {
    final tracks = await controller.getAvailableAudioTracks();
    if (!context.mounted) return;
    final track = await _pick<NativeVideoPlayerAudioTrack>(
      context,
      title: 'Audio',
      empty: 'This stream has a single audio track.',
      options: {for (final t in tracks) t: t.displayName},
      selected: (t) => t.isSelected,
    );
    if (track != null) await controller.setAudioTrack(track);
  }

  Future<void> _pickSpeed(BuildContext context) async {
    final speed = await _pick<double>(
      context,
      title: 'Speed',
      options: {
        for (final s in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
          s: '${_trim(s)}×',
      },
      selected: (s) => s == controller.speed,
    );
    if (speed != null) await controller.setSpeed(speed);
  }
}

/// Stalls and watched time from [PlaybackAnalytics], next to the player's
/// own buffer and state.
class _StatsPanel extends StatelessWidget {
  const _StatsPanel({required this.controller, required this.analytics});

  final NativeVideoPlayerController controller;
  final PlaybackAnalytics analytics;

  @override
  Widget build(BuildContext context) {
    return PlayerBuilder(
      controller: controller,
      builder: (context, c) {
        final ahead = c.bufferedPosition - c.currentPosition;
        return _Panel(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'PLAYBACK ANALYTICS',
                style: TextStyle(
                  color: Palette.muted,
                  fontSize: 11,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _Stat(
                    label: 'Buffer ahead',
                    value: ahead.isNegative ? '0 s' : '${ahead.inSeconds} s',
                  ),
                  _Stat(label: 'Stalls', value: '${analytics.stallCount}'),
                  _Stat(
                    label: 'Watched',
                    value: _fmt(analytics.watchedDuration),
                  ),
                  _Stat(label: 'State', value: c.activityState.name),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Live ────────────────────────────────────────────────────────────────

class LiveTab extends StatefulWidget {
  const LiveTab({super.key});

  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<LiveTab> {
  final _controller = NativeVideoPlayerController(
    id: 2,
    autoPlay: true,
    mediaInfo: const NativeVideoPlayerMediaInfo(title: 'Live'),
    fullscreenFlightBorderRadius: BorderRadius.circular(20),
  );
  Film _channel = Films.liveSignal;

  @override
  void initState() {
    super.initState();
    unawaited(_tune(_channel));
  }

  Future<void> _tune(Film channel) async {
    setState(() => _channel = channel);
    await _controller.initialize();
    // Live TV keeps its controls up: the LIVE pill is always one tap away.
    _controller.lockOverlay();
    await _controller.load(url: channel.url, force: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const _Header(eyebrow: 'Live HLS', title: 'On air.'),
        const SizedBox(height: 16),
        _VideoFrame(
          child: NativeVideoPlayer(
            controller: _controller,
            poster: const NativeVideoPlayerPoster(
              isLive: true,
              backgroundColor: Palette.raised,
              badgeAlignment: Alignment.topLeft,
            ),
            overlayBuilder: (context, controller) =>
                CinemaControls(controller: controller, title: _channel.title),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            for (final channel in const [Films.liveSignal, Films.liveBlender])
              ChoiceChip(
                label: Text(channel.title),
                selected: channel == _channel,
                onSelected: (_) => _tune(channel),
              ),
          ],
        ),
        const SizedBox(height: 16),
        PlayerBuilder(
          controller: _controller,
          builder: (context, c) => _Panel(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _Stat(label: 'Channel', value: _channel.title),
                _Stat(label: 'DVR window', value: _fmt(c.duration)),
                _Stat(
                  label: 'Behind live',
                  value: c.isLive ? '${c.liveEdgeOffset.inSeconds} s' : '—',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Scrub back into the DVR window, then tap LIVE to catch up. '
          'isLive, liveEdgeOffset and seekToLiveEdge() do the work.',
          style: TextStyle(color: Palette.muted, height: 1.4),
        ),
      ],
    );
  }
}

// ─── Feed ────────────────────────────────────────────────────────────────

class FeedTab extends StatefulWidget {
  const FeedTab({super.key});

  @override
  State<FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<FeedTab> {
  static const _films = [Films.tearsOfSteel, Films.sintel, Films.bunnyTrailer];
  VideoDownloadController? _downloads;

  @override
  void initState() {
    super.initState();
    // Warm the cache for the whole feed (Android; a no-op on iOS).
    for (final film in _films) {
      unawaited(NativeVideoPlayerCache.precache(film.url));
    }
    unawaited(_openDownloads());
  }

  Future<void> _openDownloads() async {
    final dir = await getApplicationDocumentsDirectory();
    if (!mounted) return;
    setState(() {
      _downloads = VideoDownloadController(
        directoryPath: '${dir.path}/showcase_downloads',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const _Header(eyebrow: 'Feed', title: 'Scroll, tap, fly.'),
        for (final (i, film) in _films.indexed)
          _FeedCard(film: film, id: 10 + i, downloads: _downloads),
      ],
    );
  }
}

class _FeedCard extends StatefulWidget {
  const _FeedCard({
    required this.film,
    required this.id,
    required this.downloads,
  });

  final Film film;
  final int id;
  final VideoDownloadController? downloads;

  @override
  State<_FeedCard> createState() => _FeedCardState();
}

class _FeedCardState extends State<_FeedCard> {
  late final _controller = NativeVideoPlayerController(
    id: widget.id,
    // Feed tiles never take over the screen on their own.
    canStartPictureInPictureAutomatically: false,
    mediaInfo: NativeVideoPlayerMediaInfo(
      title: widget.film.title,
      subtitle: widget.film.credit,
      artworkUrl: widget.film.poster,
    ),
    fullscreenFlightBorderRadius: BorderRadius.circular(20),
  );
  double? _progress;
  bool _offline = false;
  StreamSubscription<VideoDownloadProgress>? _download;

  String get _downloadId => 'feed-${widget.id}';

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    await _controller.initialize();
    final local = await widget.downloads?.localPathFor(_downloadId);
    _offline = local != null;
    await _controller.load(
      url: local != null ? 'file://$local' : widget.film.url,
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    unawaited(_download?.cancel());
    _controller.dispose();
    super.dispose();
  }

  void _toggleDownload() {
    final downloads = widget.downloads;
    if (downloads == null) return;
    if (_offline) {
      unawaited(downloads.remove(_downloadId));
      setState(() => _offline = false);
      return;
    }
    if (_progress != null) {
      unawaited(downloads.cancel(_downloadId));
      return;
    }
    setState(() => _progress = 0);
    _download = downloads
        .download(id: _downloadId, url: widget.film.url)
        .listen(
          (p) => setState(() {
            _progress = p.status == VideoDownloadStatus.downloading
                ? (p.fraction ?? 0)
                : null;
            _offline = p.status == VideoDownloadStatus.completed;
          }),
          onDone: _playOfflineCopy,
        );
  }

  /// Swaps the stream for the downloaded file, unless the video is playing.
  Future<void> _playOfflineCopy() async {
    final path = await widget.downloads?.localPathFor(_downloadId);
    if (path == null || _controller.activityState.isPlaying) return;
    await _controller.load(url: 'file://$path', force: true);
  }

  @override
  Widget build(BuildContext context) {
    final film = widget.film;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _VideoFrame(
            child: NativeVideoPlayer(
              controller: _controller,
              poster: NativeVideoPlayerPoster(
                image: NetworkImage(film.poster!),
                duration: film.length,
              ),
              overlayBuilder: (context, controller) => CinemaControls(
                controller: controller,
                title: film.title,
                compact: true,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      film.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [film.credit, if (_offline) 'offline'].join(' · '),
                      style: const TextStyle(color: Palette.muted),
                    ),
                  ],
                ),
              ),
              // HLS needs an asset download task; plain files download here.
              if (!film.isHls && widget.downloads != null)
                _DownloadButton(
                  progress: _progress,
                  done: _offline,
                  onTap: _toggleDownload,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Binge ───────────────────────────────────────────────────────────────

class BingeTab extends StatefulWidget {
  const BingeTab({super.key});

  @override
  State<BingeTab> createState() => _BingeTabState();
}

class _BingeTabState extends State<BingeTab> {
  static const _films = [Films.bunnyTrailer, Films.sintel, Films.tearsOfSteel];

  /// Where each video was left. Persist it (shared_preferences, your API)
  /// to resume across launches.
  static final Map<int, Duration> _resumeAt = {};

  final _controller = NativeVideoPlayerController(
    id: 3,
    autoPlay: true,
    fullscreenFlightBorderRadius: BorderRadius.circular(20),
  );
  late final NativeVideoPlayerPlaylist _playlist;
  late final PositionCheckpoints _checkpoints;

  @override
  void initState() {
    super.initState();
    _playlist = NativeVideoPlayerPlaylist(
      _controller,
      items: [
        for (final (i, film) in _films.indexed)
          NativeVideoPlayerPlaylistItem(url: film.url, startAt: _resumeAt[i]),
      ],
    );
    _checkpoints = PositionCheckpoints(
      _controller,
      onCheckpoint: (position) {
        if (_playlist.currentIndex < 0) return;
        _resumeAt[_playlist.currentIndex] = position;
        // The last checkpoint lands while the tab is disposed.
        if (!_disposing) setState(() {});
      },
    );
    unawaited(_start());
  }

  Future<void> _start() async {
    await _controller.initialize();
    await _playlist.start();
  }

  bool _disposing = false;

  @override
  void dispose() {
    _disposing = true;
    _checkpoints.dispose();
    _playlist.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const _Header(eyebrow: 'Playlist', title: 'Up next.'),
        const SizedBox(height: 16),
        _VideoFrame(
          child: NativeVideoPlayer(
            controller: _controller,
            overlayBuilder: (context, controller) => CinemaControls(
              controller: controller,
              // -1 until the playlist starts.
              title: _films[_playlist.currentIndex.clamp(0, 2)].title,
            ),
          ),
        ),
        const SizedBox(height: 16),
        StreamBuilder<int>(
          stream: _playlist.currentIndexStream,
          initialData: _playlist.currentIndex,
          builder: (context, snapshot) => _Panel(
            child: Column(
              children: [
                for (final (i, film) in _films.indexed)
                  ListTile(
                    onTap: () => _playlist.playItemAt(i),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        film.poster!,
                        width: 72,
                        height: 40,
                        fit: BoxFit.cover,
                      ),
                    ),
                    title: Text(
                      film.title,
                      style: TextStyle(
                        fontWeight: i == snapshot.data
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      _resumeAt[i] == null
                          ? '${film.credit} · ${_fmt(film.length!)}'
                          : 'Resume at ${_fmt(_resumeAt[i]!)}',
                      style: const TextStyle(color: Palette.muted),
                    ),
                    trailing: i == snapshot.data
                        ? const Icon(
                            Icons.equalizer_rounded,
                            color: Palette.pink,
                          )
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Player chrome ───────────────────────────────────────────────────────

/// Custom controls drawn over the native video. The player shows them on
/// tap, hides them after three seconds and takes them into fullscreen.
class CinemaControls extends StatelessWidget {
  const CinemaControls({
    super.key,
    required this.controller,
    required this.title,
    this.storyboard,
    this.compact = false,
  });

  final NativeVideoPlayerController controller;
  final String title;
  final StoryboardThumbnails? storyboard;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return PlayerBuilder(
      controller: controller,
      builder: (context, c) {
        final state = c.activityState;
        final busy =
            state.isBuffering || state.isLoading || state.isInitializing;
        final ios = defaultTargetPlatform == TargetPlatform.iOS;
        // Until the first play the poster (and its badge) owns the frame:
        // just the title and a play button.
        final started =
            c.isLive || state.isPlaying || c.currentPosition > Duration.zero;
        return Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x99000000),
                      Color(0x00000000),
                      Color(0x00000000),
                      Color(0xD9000000),
                    ],
                    stops: [0, 0.32, 0.55, 1],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              // Fullscreen covers the whole screen: keep the controls clear
              // of the notch and the home indicator. Inline the player sits
              // inside the page and needs no insets.
              child: SafeArea(
                top: c.isFullScreen,
                bottom: c.isFullScreen,
                left: c.isFullScreen,
                right: c.isFullScreen,
                child: Stack(
                  children: [
                    Positioned(
                      top: 6,
                      left: 14,
                      right: 6,
                      child: Row(
                        children: [
                          if (c.isLive) ...[
                            const _LiveDot(),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (!compact) ...[
                            _RoundIcon(
                              icon: Icons.picture_in_picture_alt_rounded,
                              onTap: c.enterPictureInPicture,
                            ),
                            if (ios)
                              _RoundIcon(
                                icon: Icons.airplay_rounded,
                                onTap: c.showAirPlayPicker,
                              ),
                          ],
                        ],
                      ),
                    ),
                    Center(
                      child: state.hasError
                          ? _RetryChip(
                              onTap: () => c.load(url: c.url!, force: true),
                            )
                          : busy
                          ? const SizedBox.square(
                              dimension: 44,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: Colors.white,
                              ),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!compact && !c.isLive)
                                  _RoundIcon(
                                    icon: Icons.replay_10_rounded,
                                    size: 30,
                                    onTap: () => c.seekTo(
                                      c.currentPosition -
                                          const Duration(seconds: 10),
                                    ),
                                  ),
                                const SizedBox(width: 18),
                                _PlayPause(
                                  playing: state.isPlaying,
                                  onTap: () =>
                                      state.isPlaying ? c.pause() : c.play(),
                                ),
                                const SizedBox(width: 18),
                                if (!compact && !c.isLive)
                                  _RoundIcon(
                                    icon: Icons.forward_10_rounded,
                                    size: 30,
                                    onTap: () => c.seekTo(
                                      c.currentPosition +
                                          const Duration(seconds: 10),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                    if (started)
                      Positioned(
                        left: 10,
                        right: 4,
                        bottom: 2,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Above the row, so the bar and the buttons
                            // share one center line.
                            if (!compact) _ChapterChip(controller: c),
                            Row(
                              children: [
                                Expanded(
                                  child: Scrubber(
                                    controller: c,
                                    storyboard: storyboard,
                                  ),
                                ),
                                if (compact)
                                  _RoundIcon(
                                    icon: c.volume == 0
                                        ? Icons.volume_off_rounded
                                        : Icons.volume_up_rounded,
                                    onTap: () =>
                                        c.setVolume(c.volume == 0 ? 1 : 0),
                                  ),
                                _RoundIcon(
                                  icon: c.isFullScreen
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                  onTap: c.toggleFullScreen,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Seek bar with the buffered range, chapters, scrub-preview thumbnails
/// and, for live streams, a DVR window with a jump-to-live button. The bar
/// itself is the package's [NativeVideoPlayerProgressBar].
class Scrubber extends StatefulWidget {
  const Scrubber({super.key, required this.controller, this.storyboard});

  final NativeVideoPlayerController controller;
  final StoryboardThumbnails? storyboard;

  @override
  State<Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<Scrubber> {
  /// Where the drag points, for the time label.
  Duration? _drag;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    // While dragging, show where the drag lands rather than where it plays.
    final position = _drag ?? c.currentPosition;
    final behind = c.duration - position;
    final atLiveEdge = c.isLive && behind.inSeconds < 10;
    const labelStyle = TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    return Row(
      children: [
        if (!c.isLive) Text(_fmt(position), style: labelStyle),
        const SizedBox(width: 10),
        Expanded(
          child: NativeVideoPlayerProgressBar(
            controller: c,
            storyboard: widget.storyboard,
            style: NativeVideoPlayerProgressBarStyle(
              playedColor: c.isLive ? Palette.live : Palette.violet,
            ),
            onScrubUpdate: (p) => setState(() => _drag = p),
            onScrubEnd: (_) => setState(() => _drag = null),
          ),
        ),
        const SizedBox(width: 10),
        if (c.isLive)
          _LivePill(
            atEdge: atLiveEdge,
            behind: behind.isNegative ? Duration.zero : behind,
            onTap: c.seekToLiveEdge,
          )
        else
          Text(_fmt(c.duration), style: labelStyle),
      ],
    );
  }
}

/// The chapter that is playing, tap to skip to the next one (YouTube puts
/// this next to the time).
class _ChapterChip extends StatelessWidget {
  const _ChapterChip({required this.controller});

  final NativeVideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<NativeVideoPlayerChapter?>(
      stream: controller.currentChapterStream,
      initialData: controller.currentChapter,
      builder: (context, snapshot) {
        final chapter = snapshot.data;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: chapter == null
              ? const SizedBox.shrink()
              : GestureDetector(
                  key: ValueKey(chapter.start),
                  onTap: controller.seekToNextChapter,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          chapter.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

/// Rebuilds whenever the player reports anything, position ticks included.
class PlayerBuilder extends StatefulWidget {
  const PlayerBuilder({
    super.key,
    required this.controller,
    required this.builder,
  });

  final NativeVideoPlayerController controller;
  final Widget Function(BuildContext, NativeVideoPlayerController) builder;

  @override
  State<PlayerBuilder> createState() => _PlayerBuilderState();
}

class _PlayerBuilderState extends State<PlayerBuilder> {
  @override
  void initState() {
    super.initState();
    _listen(widget.controller);
  }

  @override
  void didUpdateWidget(PlayerBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _unlisten(oldWidget.controller);
      _listen(widget.controller);
    }
  }

  @override
  void dispose() {
    _unlisten(widget.controller);
    super.dispose();
  }

  void _listen(NativeVideoPlayerController c) => c
    ..addActivityListener(_onActivity)
    ..addControlListener(_onControl);

  void _unlisten(NativeVideoPlayerController c) => c
    ..removeActivityListener(_onActivity)
    ..removeControlListener(_onControl);

  void _onActivity(PlayerActivityEvent _) => _refresh();
  void _onControl(PlayerControlEvent _) => _refresh();
  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, widget.controller);
}

// ─── Chromecast ──────────────────────────────────────────────────────────

/// Finds Cast devices on the network and connects to the one you tap.
class _CastPicker extends StatefulWidget {
  const _CastPicker();

  @override
  State<_CastPicker> createState() => _CastPickerState();
}

class _CastPickerState extends State<_CastPicker> {
  List<cast.CastDevice>? _devices;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan() async {
    setState(() {
      _devices = null;
      _error = null;
    });
    try {
      final devices = await cast.CastDeviceDiscovery.discover();
      if (mounted) setState(() => _devices = devices);
    } on cast.CastDiscoveryException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetTitle('Cast to a device'),
            if (_error != null)
              ListTile(
                title: Text(_error!),
                leading: const Icon(Icons.wifi_off),
              )
            else if (devices == null)
              const ListTile(
                leading: SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: Text('Looking for Chromecasts…'),
              )
            else if (devices.isEmpty)
              ListTile(
                leading: const Icon(Icons.cast_rounded),
                title: const Text('No Cast devices on this network'),
                trailing: TextButton(
                  onPressed: _scan,
                  child: const Text('Scan again'),
                ),
              )
            else
              for (final device in devices)
                ListTile(
                  leading: const Icon(Icons.tv_rounded),
                  title: Text(device.displayName),
                  subtitle: Text(device.model ?? device.host),
                  onTap: () async {
                    final session = await cast.CastSession.connect(device);
                    if (context.mounted) Navigator.pop(context, session);
                  },
                ),
          ],
        ),
      ),
    );
  }
}

/// Remote control for the TV, mirrored from the receiver's own status.
class _CastBanner extends StatelessWidget {
  const _CastBanner({required this.session, required this.onStop});

  final cast.CastSession session;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<cast.CastSessionStatus>(
      stream: session.statusStream,
      builder: (context, snapshot) {
        final status = snapshot.data;
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _Panel(
            child: ListTile(
              leading: const Icon(
                Icons.cast_connected_rounded,
                color: Palette.pink,
              ),
              title: Text('Casting to ${session.device.displayName}'),
              subtitle: Text(
                status == null
                    ? 'Connecting…'
                    : '${_fmt(status.position)} · ${status.playerState.toLowerCase()}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      status?.isPlaying ?? false
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                    onPressed: () => (status?.isPlaying ?? false)
                        ? session.pause()
                        : session.play(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.stop_rounded),
                    onPressed: onStop,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── Small pieces ────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.eyebrow, required this.title});

  final String eyebrow;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShaderMask(
          shaderCallback: Palette.brand.createShader,
          child: Text(
            eyebrow.toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              letterSpacing: 1.6,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: const TextStyle(
            fontSize: 30,
            height: 1.1,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
          ),
        ),
      ],
    );
  }
}

/// A 16:9 player slot with rounded corners and a soft glow.
class _VideoFrame extends StatelessWidget {
  const _VideoFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x408B5CF6),
            blurRadius: 40,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: AspectRatio(aspectRatio: 16 / 9, child: child),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = EdgeInsets.zero});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    // A Material, so list tiles inside can paint their ink on it.
    return Material(
      color: Palette.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Palette.line),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _DeckTile extends StatelessWidget {
  const _DeckTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            gradient: active ? Palette.brand : null,
            color: active ? null : Palette.raised,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Palette.line),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 22, color: Colors.white),
                const Spacer(),
                Text(
                  label,
                  maxLines: 2,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: active ? Colors.white70 : Palette.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: Palette.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _PlayPause extends StatelessWidget {
  const _PlayPause({required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: Palette.brand,
          boxShadow: [BoxShadow(color: Color(0x668B5CF6), blurRadius: 24)],
        ),
        child: Icon(
          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: Colors.white,
          size: 36,
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap, this.size = 22});

  final IconData icon;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: size, color: Colors.white),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Palette.live,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'LIVE',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _LivePill extends StatelessWidget {
  const _LivePill({
    required this.atEdge,
    required this.behind,
    required this.onTap,
  });

  final bool atEdge;
  final Duration behind;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: atEdge ? null : onTap,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white,
        visualDensity: VisualDensity.compact,
      ),
      icon: Icon(
        Icons.circle,
        size: 9,
        color: atEdge ? Palette.live : Colors.white54,
      ),
      label: Text(atEdge ? 'LIVE' : '-${_fmt(behind)}'),
    );
  }
}

class _RetryChip extends StatelessWidget {
  const _RetryChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: const Icon(Icons.refresh_rounded, size: 18),
      label: const Text("Couldn't play this video · Retry"),
      onPressed: onTap,
    );
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({
    required this.progress,
    required this.done,
    required this.onTap,
  });

  final double? progress;
  final bool done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      onPressed: onTap,
      tooltip: done ? 'Remove download' : 'Download',
      icon: progress != null
          ? SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(
                value: progress == 0 ? null : progress,
                strokeWidth: 2.5,
              ),
            )
          : Icon(
              done ? Icons.download_done_rounded : Icons.download_rounded,
              color: done ? Palette.pink : null,
            ),
    );
  }
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// A bottom sheet listing [options]; returns the one picked.
Future<T?> _pick<T>(
  BuildContext context, {
  required String title,
  required Map<T, String> options,
  bool Function(T option)? selected,
  String empty = 'Nothing to choose from yet.',
}) {
  return showModalBottomSheet<T>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetTitle(title),
            if (options.isEmpty)
              ListTile(
                title: Text(
                  empty,
                  style: const TextStyle(color: Palette.muted),
                ),
              )
            else
              for (final MapEntry(key: option, value: label) in options.entries)
                ListTile(
                  title: Text(label),
                  trailing: (selected?.call(option) ?? false)
                      ? const Icon(Icons.check_rounded, color: Palette.pink)
                      : null,
                  onTap: () => Navigator.pop(context, option),
                ),
          ],
        ),
      ),
    ),
  );
}

/// "4:05", "1:02:03".
String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// 1.0 -> "1", 1.25 -> "1.25".
String _trim(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

import 'package:flutter/foundation.dart';

/// Global, opt-in tuning knobs for the plugin.
///
/// All defaults preserve the plugin's existing behavior; set
/// [NativeVideoPlayerConfig.global] (typically once, at app startup, before
/// creating controllers) to opt in:
///
/// ```dart
/// NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
///   maxConcurrentPlayingPlayers: 2,
///   androidBufferConfig: NativeVideoPlayerAndroidBufferConfig.feed(),
///   iosBufferConfig: NativeVideoPlayerIosBufferConfig.feed(),
/// );
/// ```
@immutable
class NativeVideoPlayerConfig {
  const NativeVideoPlayerConfig({
    this.maxConcurrentPlayingPlayers,
    this.timeUpdateInterval = const Duration(milliseconds: 500),
    this.androidBufferConfig,
    this.iosBufferConfig,
    this.qualityForViewportSize = false,
    this.prioritizeActivePlayback = false,
    this.lightweightInlineViews = false,
    this.androidEnableDiskCache = false,
    this.androidDiskCacheMaxBytes = 100 * 1024 * 1024,
    this.androidPrecacheBytes = 2 * 1024 * 1024,
  }) : assert(
         maxConcurrentPlayingPlayers == null || maxConcurrentPlayingPlayers > 0,
         'maxConcurrentPlayingPlayers must be > 0 (or null for unlimited)',
       );

  /// The active configuration. Replace it to change behavior; changes to the
  /// playing cap take effect on the next playback-state transition, while
  /// buffer/interval settings apply to players created afterwards.
  static NativeVideoPlayerConfig global = const NativeVideoPlayerConfig();

  /// Maximum number of players allowed to PLAY simultaneously (null =
  /// unlimited, the default).
  ///
  /// When a player starts playing and the cap is exceeded, the
  /// least-recently-played player is paused (never disposed or released).
  /// Players that are in Picture-in-Picture or connected to AirPlay are
  /// never auto-paused; if only exempt players remain, the cap is allowed to
  /// be exceeded (soft cap). Useful for feeds: devices support only a
  /// handful of simultaneous hardware decode sessions before quality and
  /// frame rates degrade.
  final int? maxConcurrentPlayingPlayers;

  /// Interval between `timeUpdated` events while playing (default 500ms,
  /// matching previous behavior). Applies to players created after the
  /// config is set. Larger intervals reduce per-player channel traffic and
  /// main-thread wakeups in multi-player feeds.
  final Duration timeUpdateInterval;

  /// Optional ExoPlayer buffer tuning (Android). Applies to native players
  /// created after the config is set; null keeps ExoPlayer's defaults.
  final NativeVideoPlayerAndroidBufferConfig? androidBufferConfig;

  /// Optional AVPlayer buffer tuning (iOS). Applies on the next `load()`;
  /// null keeps AVPlayer's automatic behavior.
  final NativeVideoPlayerIosBufferConfig? iosBufferConfig;

  /// Caps adaptive (HLS) quality selection to each player's on-screen size
  /// (default: false = current behavior).
  ///
  /// By default ABR selects quality for a full-screen viewport, so a feed of
  /// small tiles can decode several 1080p streams at once. With this enabled,
  /// each platform view reports its physical pixel size and the player limits
  /// variant selection accordingly (`TrackSelectionParameters.setViewportSize`
  /// on Android, `AVPlayerItem.preferredMaximumResolution` on iOS).
  ///
  /// The cap is lifted automatically in native fullscreen and while AirPlay
  /// external playback is active (iOS), and a Dart-fullscreen view reports its
  /// own larger size. Manual quality selection via `setQuality` loads a
  /// specific variant URL and is never constrained by this. Has no effect on
  /// single-variant sources (plain MP4).
  final bool qualityForViewportSize;

  /// Lets actively playing players win network/IO contention over paused
  /// ones (Android only; default: false = current behavior).
  ///
  /// All players created while this is enabled share one Media3
  /// `PriorityTaskManager`: playing players load at `C.PRIORITY_PLAYBACK`,
  /// paused/idle players are demoted to `C.PRIORITY_PLAYBACK_PRELOAD`, so a
  /// feed's background players stop competing with the videos the user is
  /// actually watching. Visual quality is unaffected; paused players simply
  /// buffer later. Applies to players created after the config is set.
  final bool prioritizeActivePlayback;

  /// Hosts a bare video surface instead of the full native player UI for
  /// views created with native controls hidden (default: false = current
  /// behavior).
  ///
  /// Every inline tile normally carries a complete `AVPlayerViewController`
  /// (iOS) or Media3 `PlayerView` (Android) — controls UI, gesture
  /// recognizers, internal observation — even when the app always draws its
  /// own controls via `overlayBuilder`. With this enabled, views whose
  /// native controls are hidden (`showNativeControls: false` or a custom
  /// overlay) host a plain `AVPlayerLayer` / `SurfaceView` instead, which is
  /// noticeably cheaper to create, lay out, and tear down in scroll feeds.
  ///
  /// Everything else keeps working: PiP (iOS inline PiP runs on the layer
  /// via `AVPictureInPictureController`; Android PiP is activity-level),
  /// Now Playing / media session, native fullscreen (which always creates
  /// its own full controller on demand), subtitles, and the native sidecar
  /// caption rendering used during PiP/fullscreen. Applies to platform views
  /// created after the config is set.
  ///
  /// Limitation: `setShowNativeControls(true)` at runtime is ignored for a
  /// view created lightweight — recreate the player view with
  /// `showNativeControls: true` instead. On iOS, PiP started from a
  /// lightweight view ends if that platform view is disposed while PiP is
  /// active (keep the tile mounted, or use `releaseResources()` semantics).
  final bool lightweightInlineViews;

  /// Caches remote media on disk so revisited feed items skip the network
  /// (Android only; default: false = current behavior).
  ///
  /// Uses a single Media3 `SimpleCache` with LRU eviction shared by all
  /// players. Cache reads/writes happen transparently during playback, and
  /// [NativeVideoPlayerCache.precache] can warm the cache for upcoming feed
  /// items before any player exists. DRM-protected streams and local
  /// sources always bypass the cache.
  ///
  /// The cache is created at first use and lives for the process; size
  /// changes after that (see [androidDiskCacheMaxBytes]) apply on the next
  /// app start. iOS is unsupported: AVPlayer has no practical inline HLS
  /// cache (`AVAssetDownloadTask` is an offline-download API) — `precache`
  /// is a no-op there.
  final bool androidEnableDiskCache;

  /// Maximum disk cache size in bytes (default 100 MB). Applies when the
  /// cache is first created in the process; LRU eviction keeps the cache
  /// under this bound.
  final int androidDiskCacheMaxBytes;

  /// Default byte budget for [NativeVideoPlayerCache.precache] (default
  /// 2 MB): progressive sources cache their first bytes, HLS warms the
  /// playlists plus leading segments up to this budget.
  final int androidPrecacheBytes;
}

/// ExoPlayer `DefaultLoadControl` parameters (Android only).
///
/// Defaults match Media3 1.5.0's `DefaultLoadControl` values, so constructing
/// this without arguments changes nothing.
@immutable
class NativeVideoPlayerAndroidBufferConfig {
  const NativeVideoPlayerAndroidBufferConfig({
    this.minBufferMs = 50000,
    this.maxBufferMs = 50000,
    this.bufferForPlaybackMs = 2500,
    this.bufferForPlaybackAfterRebufferMs = 5000,
  });

  /// Preset for feeds with multiple simultaneous players: smaller buffers so
  /// N players don't each try to hold up to 50s of media (memory + sustained
  /// network per player), and a lower start threshold for snappier startup.
  const NativeVideoPlayerAndroidBufferConfig.feed()
    : this(
        minBufferMs: 15000,
        maxBufferMs: 30000,
        bufferForPlaybackMs: 1500,
        bufferForPlaybackAfterRebufferMs: 3000,
      );

  /// Minimum buffered media the player tries to maintain, in milliseconds.
  final int minBufferMs;

  /// Maximum buffered media, in milliseconds.
  final int maxBufferMs;

  /// Buffer required before starting playback, in milliseconds.
  final int bufferForPlaybackMs;

  /// Buffer required to resume after a rebuffer, in milliseconds.
  final int bufferForPlaybackAfterRebufferMs;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'minBufferMs': minBufferMs,
    'maxBufferMs': maxBufferMs,
    'bufferForPlaybackMs': bufferForPlaybackMs,
    'bufferForPlaybackAfterRebufferMs': bufferForPlaybackAfterRebufferMs,
  };
}

/// AVPlayer buffering parameters (iOS only).
@immutable
class NativeVideoPlayerIosBufferConfig {
  const NativeVideoPlayerIosBufferConfig({
    this.preferredForwardBufferDuration,
    this.automaticallyWaitsToMinimizeStalling = true,
  });

  /// Preset for feeds with multiple simultaneous players: bounds each
  /// player's forward buffer to ~15s to reduce N-player network contention.
  const NativeVideoPlayerIosBufferConfig.feed()
    : this(preferredForwardBufferDuration: 15);

  /// Preferred forward buffer in seconds; null (default) keeps AVPlayer's
  /// automatic buffer management.
  final double? preferredForwardBufferDuration;

  /// AVPlayer's `automaticallyWaitsToMinimizeStalling`. Leave true (default)
  /// unless you know you need immediate starts at the cost of stalls.
  final bool automaticallyWaitsToMinimizeStalling;

  Map<String, dynamic> toMap() => <String, dynamic>{
    if (preferredForwardBufferDuration != null)
      'preferredForwardBufferDuration': preferredForwardBufferDuration,
    'automaticallyWaitsToMinimizeStalling':
        automaticallyWaitsToMinimizeStalling,
  };
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/native_video_player_config.dart';

/// One video a [NativeVideoPlayerPreloader] may preload.
@immutable
class NativeVideoPlayerPreloadItem {
  const NativeVideoPlayerPreloadItem({
    required this.url,
    this.headers,
    this.isDrm = false,
  });

  /// The URL that will later be passed to `controller.load(url: ...)`.
  final String url;

  /// HTTP headers for the preload requests. Use the same headers as the
  /// later `load()`; on iOS the preloaded asset is only used when they match.
  final Map<String, String>? headers;

  /// DRM sources are never preloaded (their licence flow runs on load).
  final bool isDrm;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'url': url,
    'headers': ?headers,
  };

  @override
  bool operator ==(Object other) =>
      other is NativeVideoPlayerPreloadItem &&
      other.url == url &&
      other.isDrm == isDrm &&
      mapEquals(other.headers, headers);

  @override
  int get hashCode => Object.hash(
    url,
    isDrm,
    headers == null
        ? null
        : Object.hashAllUnordered(
            headers!.entries.map(
              (MapEntry<String, String> e) => '${e.key}=${e.value}',
            ),
          ),
  );
}

/// Preloads the videos around the current one in a vertical (reels-style)
/// feed, so swiping to the next video starts faster.
///
/// Call [setWindow] whenever the current page changes. The preloader keeps
/// the [ahead] items after and the [behind] items before the current one
/// preloaded, and releases everything that left the window:
///
/// ```dart
/// final preloader = NativeVideoPlayerPreloader();
///
/// PageView.builder(
///   onPageChanged: (int index) => preloader.setWindow(items, index),
///   ...
/// );
///
/// // When the feed goes away:
/// preloader.dispose();
/// ```
///
/// A controller that loads a preloaded URL picks the preloaded data up
/// automatically; nothing else changes in how controllers are used.
///
/// - **iOS:** each window item's asset is loaded in the background (for
///   HLS the master and media playlists, for files the header). `load()`
///   with the same URL and headers starts from that asset, which skips those
///   round trips. Segments are not buffered ahead on iOS: a player item
///   can't move between players, and a hidden player per neighbour would
///   cost decoders and memory.
/// - **Android:** the first segments are written to the disk cache, which
///   `load()` then reads. This needs
///   [NativeVideoPlayerConfig.androidEnableDiskCache]; without it the
///   preloader does nothing on Android.
///
/// The current item itself is not preloaded (its controller is loading it),
/// and neither are DRM sources. The window is capped at 3 items. The native
/// side keeps one window, so use one preloader per feed and [dispose] it when
/// the feed closes.
class NativeVideoPlayerPreloader {
  NativeVideoPlayerPreloader({this.ahead = 2, this.behind = 1})
    : assert(ahead >= 0 && behind >= 0),
      assert(
        ahead + behind <= maxWindow,
        'At most $maxWindow items are preloaded',
      );

  /// The most items kept preloaded at once.
  static const int maxWindow = 3;

  /// Items after the current one to preload.
  final int ahead;

  /// Items before the current one to preload.
  final int behind;

  static const MethodChannel _channel = MethodChannel('native_video_player');

  List<NativeVideoPlayerPreloadItem> _window =
      const <NativeVideoPlayerPreloadItem>[];
  bool _disposed = false;
  Future<void> _pending = Future<void>.value();

  /// The items currently kept preloaded (for tests and diagnostics).
  List<NativeVideoPlayerPreloadItem> get window =>
      List<NativeVideoPlayerPreloadItem>.unmodifiable(_window);

  /// Which items to preload for [currentIndex]: the next [ahead] first (most
  /// likely to be watched next), then the previous [behind]. DRM items and
  /// the current item are skipped; duplicates of the current URL too.
  @visibleForTesting
  List<NativeVideoPlayerPreloadItem> windowFor(
    List<NativeVideoPlayerPreloadItem> items,
    int currentIndex,
  ) {
    if (items.isEmpty) return const <NativeVideoPlayerPreloadItem>[];
    final int current = currentIndex.clamp(0, items.length - 1);
    final String currentUrl = items[current].url;
    final List<NativeVideoPlayerPreloadItem> result =
        <NativeVideoPlayerPreloadItem>[];
    void add(int index) {
      if (index < 0 || index >= items.length) return;
      final NativeVideoPlayerPreloadItem item = items[index];
      if (item.isDrm || item.url == currentUrl || result.contains(item)) return;
      result.add(item);
    }

    for (int i = 1; i <= ahead; i++) {
      add(current + i);
    }
    for (int i = 1; i <= behind; i++) {
      add(current - i);
    }
    return result;
  }

  /// Moves the window to [currentIndex] in [items].
  ///
  /// Calls are serialized; it is fine to call this on every page change,
  /// even while a previous update is still in flight. Never throws: a
  /// failing platform call only means nothing is preloaded.
  Future<void> setWindow(
    List<NativeVideoPlayerPreloadItem> items,
    int currentIndex,
  ) {
    if (_disposed) return Future<void>.value();
    final List<NativeVideoPlayerPreloadItem> next = windowFor(
      items,
      currentIndex,
    );
    if (listEquals(next, _window)) return _pending;
    _window = next;
    return _send(next);
  }

  /// Releases everything this preloader holds.
  Future<void> clear() {
    if (_window.isEmpty) return _pending;
    _window = const <NativeVideoPlayerPreloadItem>[];
    return _send(const <NativeVideoPlayerPreloadItem>[]);
  }

  /// Releases everything and ignores later calls.
  Future<void> dispose() {
    if (_disposed) return _pending;
    final Future<void> cleared = clear();
    _disposed = true;
    return cleared;
  }

  Future<void> _send(List<NativeVideoPlayerPreloadItem> items) {
    if (kIsWeb) return Future<void>.value();
    // Chain on the previous update so the native side sees them in order.
    return _pending = _pending.then((_) async {
      try {
        final NativeVideoPlayerConfig config = NativeVideoPlayerConfig.global;
        await _channel
            .invokeMethod<Object?>('setPreloadWindow', <String, dynamic>{
              'items': items
                  .map((NativeVideoPlayerPreloadItem i) => i.toMap())
                  .toList(),
              'androidDiskCache': config.androidEnableDiskCache,
              'precacheBytes': config.androidPrecacheBytes,
              'cacheMaxBytes': config.androidDiskCacheMaxBytes,
            });
      } catch (e) {
        debugPrint('NativeVideoPlayerPreloader: setPreloadWindow failed: $e');
      }
    });
  }
}

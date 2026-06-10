import 'dart:async';

import 'package:flutter/foundation.dart';

import '../controllers/native_video_player_controller.dart';
import '../enums/native_video_player_event.dart';
import '../models/native_video_player_sidecar_subtitle.dart';

/// One entry in a [NativeVideoPlayerPlaylist].
@immutable
class NativeVideoPlayerPlaylistItem {
  const NativeVideoPlayerPlaylistItem({
    required this.url,
    this.headers,
    this.drmConfig,
    this.sidecarSubtitles,
    this.startAt,
  });

  /// Video URL (same formats as `NativeVideoPlayerController.load`).
  final String url;

  /// Optional HTTP headers for this item's video request.
  final Map<String, String>? headers;

  /// Optional DRM configuration for this item.
  final Map<String, dynamic>? drmConfig;

  /// Optional sidecar subtitles loaded together with this item.
  final List<NativeVideoPlayerSidecarSubtitle>? sidecarSubtitles;

  /// Optional resume position applied natively before the first frame.
  final Duration? startAt;
}

/// Sequential playback of multiple sources on ONE controller, with
/// auto-advance when an item completes.
///
/// A queue helper, not a player: it drives the existing controller (same
/// shared-player lifecycle, views, PiP), so it composes with everything
/// else. Note auto-advance relies on the `completed` event — a controller
/// with `setLooping(true)` never completes, so disable looping while a
/// playlist is attached.
///
/// ```dart
/// final playlist = NativeVideoPlayerPlaylist(controller, items: [...]);
/// await playlist.start();
/// playlist.currentIndexStream.listen((i) => print('now playing $i'));
/// ```
class NativeVideoPlayerPlaylist {
  NativeVideoPlayerPlaylist(
    this.controller, {
    required List<NativeVideoPlayerPlaylistItem> items,
    this.autoAdvance = true,
    this.loop = false,
  }) : items = List.unmodifiable(items) {
    controller.addActivityListener(_onActivity);
  }

  final NativeVideoPlayerController controller;

  /// The queue, in playback order (immutable snapshot).
  final List<NativeVideoPlayerPlaylistItem> items;

  /// Load and play the next item when the current one completes.
  final bool autoAdvance;

  /// Wrap from the last item back to the first.
  final bool loop;

  final StreamController<int> _indexController =
      StreamController<int>.broadcast();
  int _currentIndex = -1;
  bool _advancing = false;

  /// Index of the item playing now; -1 before [start].
  int get currentIndex => _currentIndex;

  /// Emits whenever a new item starts loading.
  Stream<int> get currentIndexStream => _indexController.stream;

  bool get hasNext =>
      loop ? items.isNotEmpty : _currentIndex < items.length - 1;

  bool get hasPrevious => loop ? items.isNotEmpty : _currentIndex > 0;

  /// Starts the playlist from [index].
  Future<void> start({int index = 0}) => playItemAt(index);

  /// Loads and plays [items]`[index]`.
  Future<void> playItemAt(int index) async {
    RangeError.checkValidIndex(index, items, 'index');
    final item = items[index];
    _currentIndex = index;
    if (!_indexController.isClosed) {
      _indexController.add(index);
    }
    await controller.load(
      url: item.url,
      headers: item.headers,
      drmConfig: item.drmConfig,
      sidecarSubtitles: item.sidecarSubtitles,
      startAt: item.startAt,
      force: true,
    );
    await controller.play();
  }

  /// Advances to the next item (wrapping when [loop] is set); no-op at the
  /// end of a non-looping queue.
  Future<void> next() async {
    if (!hasNext) {
      return;
    }
    await playItemAt((_currentIndex + 1) % items.length);
  }

  /// Goes back to the previous item (wrapping when [loop] is set).
  Future<void> previous() async {
    if (!hasPrevious) {
      return;
    }
    await playItemAt((_currentIndex - 1 + items.length) % items.length);
  }

  void _onActivity(PlayerActivityEvent event) {
    if (!autoAdvance ||
        _advancing ||
        event.state != PlayerActivityState.completed ||
        !hasNext) {
      return;
    }
    // Guard against duplicate completed events while the next load runs.
    _advancing = true;
    unawaited(next().whenComplete(() => _advancing = false));
  }

  /// Detaches from the controller. Does not stop current playback.
  void dispose() {
    controller.removeActivityListener(_onActivity);
    unawaited(_indexController.close());
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/native_video_player_config.dart';

/// What the coordinator needs to know about a player to enforce the playing
/// cap. Implemented by the controller; abstract so the cap logic is testable
/// without platform channels.
abstract class PlayableHandle {
  /// Controller ID, for stable identity in logs/tests.
  int get id;

  /// Players in Picture-in-Picture are never auto-paused.
  bool get isPipActive;

  /// Players connected to AirPlay are never auto-paused.
  bool get isAirPlayConnected;

  /// Pauses playback because the playing cap was exceeded.
  Future<void> pauseForCap();
}

/// Enforces [NativeVideoPlayerConfig.maxConcurrentPlayingPlayers].
///
/// Tracks playback-state TRANSITIONS (not `play()` calls), so playback
/// started natively (native controls, remote commands, autoplay) is counted
/// too. When the cap is exceeded, the least-recently-played non-exempt
/// player is paused — never disposed or released, so resuming it is
/// instant. Controllers that share an id (one native player) count once.
/// With the default config (no cap) this class does nothing.
class PlaybackCoordinator {
  PlaybackCoordinator._();

  /// Test constructor: an isolated instance with its own state.
  @visibleForTesting
  PlaybackCoordinator.forTesting();

  static final PlaybackCoordinator instance = PlaybackCoordinator._();

  /// Currently playing handles in least-recently-played-first order.
  final List<PlayableHandle> _playing = <PlayableHandle>[];

  /// Number of handles currently considered playing (visible for tests and
  /// debugging).
  int get playingCount => _playing.length;

  /// Reports that [handle] entered the playing state (or re-reported playing,
  /// which refreshes its most-recently-played position).
  void onPlaying(PlayableHandle handle) {
    _playing.remove(handle);
    _playing.add(handle);
    _enforceCap();
  }

  /// Reports that [handle] left the playing state (paused, completed,
  /// stopped, errored) for any reason — including a pause this coordinator
  /// issued itself.
  void onStoppedPlaying(PlayableHandle handle) {
    _playing.remove(handle);
  }

  /// Removes [handle] entirely (controller disposed).
  void unregister(PlayableHandle handle) {
    _playing.remove(handle);
  }

  void _enforceCap() {
    final int? cap = NativeVideoPlayerConfig.global.maxConcurrentPlayingPlayers;
    if (cap == null) {
      return;
    }

    // Controllers that share an id drive one native player (e.g. a feed tile
    // and the detail page showing the same video): they count as one player
    // and never pause each other. Distinct ids, least recently played first.
    final ids = <int>[];
    for (final handle in _playing) {
      ids
        ..remove(handle.id)
        ..add(handle.id);
    }

    var overBy = ids.length - cap;
    if (overBy <= 0) {
      return;
    }

    // Pause least-recently-played first; PiP/AirPlay players are exempt.
    // If only exempt players remain over the cap, exceed it (soft cap).
    for (final id in ids) {
      if (overBy <= 0) {
        break;
      }
      final group = _playing.where((h) => h.id == id).toList(growable: false);
      if (group.any((h) => h.isPipActive || h.isAirPlayConnected)) {
        continue;
      }
      // Remove BEFORE pausing: the resulting pause events trigger
      // onStoppedPlaying, which must be a no-op for these handles. One pause
      // stops the shared player for the whole group.
      _playing.removeWhere((h) => h.id == id);
      overBy--;
      unawaited(group.last.pauseForCap());
    }
  }
}

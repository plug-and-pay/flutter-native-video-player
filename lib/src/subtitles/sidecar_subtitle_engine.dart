import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/native_video_player_sidecar_subtitle.dart';
import 'subtitle_cue.dart';
import 'subtitle_loader.dart';
import 'subtitle_parser.dart';

/// Loads, parses and time-syncs sidecar subtitle sources for one controller.
///
/// Cue timing: the engine anchors on the last position it was fed (the
/// controller forwards `timeUpdated`/seek/speed/pause signals) and, while
/// playing, interpolates between updates with a local ticker so cue edges
/// land smoothly without extra platform-channel traffic.
class SidecarSubtitleEngine {
  SidecarSubtitleEngine();

  /// Interpolation tick while playing. Cue granularity, not event traffic.
  static const Duration _tickInterval = Duration(milliseconds: 250);

  final List<NativeVideoPlayerSidecarSubtitle> _sources = [];
  final Map<int, List<SubtitleCue>> _cuesBySource = {};

  /// Active cue lines at the current playback position (empty = no cue).
  /// The subtitle overlay widget listens to this.
  final ValueNotifier<List<String>> activeCueLines = ValueNotifier(const []);

  int? _selectedSource;
  Timer? _ticker;
  Duration _anchorPosition = Duration.zero;
  late final Stopwatch _sinceAnchor = Stopwatch();
  double _speed = 1.0;
  bool _playing = false;
  bool _disposed = false;

  List<NativeVideoPlayerSidecarSubtitle> get sources =>
      List.unmodifiable(_sources);

  /// Index of the selected sidecar source, or null when off.
  int? get selectedSource => _selectedSource;

  /// Replaces the sidecar sources. Parsing happens lazily on selection;
  /// selection resets to off.
  void setSources(List<NativeVideoPlayerSidecarSubtitle> sources) {
    _sources
      ..clear()
      ..addAll(sources);
    _cuesBySource.clear();
    deselect();
  }

  /// Loads (if needed) and activates the sidecar source at [index].
  /// Throws RangeError for invalid indices; load/parse failures propagate so
  /// callers can surface them (a failed subtitle must not break playback —
  /// the controller catches and reports).
  Future<void> select(int index) async {
    RangeError.checkValidIndex(index, _sources, 'index');
    if (!_cuesBySource.containsKey(index)) {
      final source = _sources[index];
      final String content;
      if (source.content != null) {
        content = source.content!;
      } else if (source.url != null) {
        content = await SubtitleLoader.loadUrl(source.url!);
      } else {
        content = await SubtitleLoader.loadFile(source.filePath!);
      }
      final format =
          source.format ??
          SubtitleParser.detectFormat(
            name: source.url ?? source.filePath,
            content: content,
          );
      _cuesBySource[index] = SubtitleParser.parse(content, format: format);
    }
    if (_disposed) return;
    _selectedSource = index;
    _emitForPosition(_currentPosition());
    _updateTicker();
  }

  /// Turns sidecar subtitles off (keeps parsed cues cached).
  void deselect() {
    _selectedSource = null;
    _stopTicker();
    if (!_disposed && activeCueLines.value.isNotEmpty) {
      activeCueLines.value = const [];
    }
  }

  // --- Position signals from the controller ---

  void onPosition(Duration position) {
    _anchorPosition = position;
    _sinceAnchor
      ..reset()
      ..start();
    _emitForPosition(position);
  }

  void onPlayingChanged(bool playing) {
    // Re-anchor so interpolation doesn't run across the pause.
    _anchorPosition = _currentPosition();
    _sinceAnchor
      ..reset()
      ..start();
    _playing = playing;
    _updateTicker();
  }

  void onSpeedChanged(double speed) {
    _anchorPosition = _currentPosition();
    _sinceAnchor
      ..reset()
      ..start();
    _speed = speed;
  }

  // --- Internals ---

  Duration _currentPosition() {
    if (!_playing || !_sinceAnchor.isRunning) return _anchorPosition;
    return _anchorPosition + _sinceAnchor.elapsed * _speed;
  }

  void _updateTicker() {
    if (_playing && _selectedSource != null) {
      _ticker ??= Timer.periodic(
        _tickInterval,
        (_) => _emitForPosition(_currentPosition()),
      );
    } else {
      _stopTicker();
    }
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _emitForPosition(Duration position) {
    final selected = _selectedSource;
    if (_disposed || selected == null) return;
    final cues = _cuesBySource[selected] ?? const <SubtitleCue>[];
    final active = _activeCueAt(cues, position);
    final lines = active?.lines ?? const <String>[];
    if (!listEquals(lines, activeCueLines.value)) {
      activeCueLines.value = lines;
    }
  }

  /// Binary search for the last cue starting at/before [position], then
  /// checks it is still active (cues are sorted and rarely overlap).
  SubtitleCue? _activeCueAt(List<SubtitleCue> cues, Duration position) {
    var low = 0;
    var high = cues.length - 1;
    SubtitleCue? candidate;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (cues[mid].start <= position) {
        candidate = cues[mid];
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (candidate != null && candidate.isActiveAt(position)) return candidate;
    return null;
  }

  void dispose() {
    _disposed = true;
    _stopTicker();
    activeCueLines.dispose();
  }
}

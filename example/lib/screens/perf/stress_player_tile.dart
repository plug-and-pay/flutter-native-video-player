import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

import '../../models/video_item.dart';
import '../../services/perf_metrics.dart';

/// Minimal player tile for the stress screens.
///
/// Supports two rebuild strategies so package-level optimizations can be
/// measured separately from consumer-side rebuild cost:
/// - naive: `setState` on every activity/control event (mirrors the pattern in
///   the original example card and the typical consumer mistake)
/// - optimized: the player subtree never rebuilds; labels rebuild via
///   [StreamBuilder] scoped to the text widgets only.
class StressPlayerTile extends StatefulWidget {
  const StressPlayerTile({
    required this.video,
    required this.index,
    this.autoPlay = true,
    this.naiveRebuilds = false,
    this.onControllerCreated,
    super.key,
  });

  final VideoItem video;
  final int index;
  final bool autoPlay;
  final bool naiveRebuilds;
  final void Function(NativeVideoPlayerController controller)?
  onControllerCreated;

  @override
  State<StressPlayerTile> createState() => _StressPlayerTileState();
}

class _StressPlayerTileState extends State<StressPlayerTile> {
  NativeVideoPlayerController? _controller;
  PlayerActivityState _state = PlayerActivityState.idle;
  Duration _position = Duration.zero;
  bool _sawFirstFrame = false;

  @override
  void initState() {
    super.initState();
    unawaited(_setup());
  }

  Future<void> _setup() async {
    final controller = NativeVideoPlayerController(
      id: widget.video.id,
      autoPlay: widget.autoPlay,
      lockToLandscape: false,
      showNativeControls: false,
      // Stress tiles don't exercise automatic PiP (the PiP harness does);
      // disabling it lets iosTextureMode apply to these tiles.
      canStartPictureInPictureAutomatically: false,
      mediaInfo: NativeVideoPlayerMediaInfo(
        title: widget.video.title,
        subtitle: widget.video.description,
        artworkUrl: widget.video.artworkUrl,
      ),
    );
    _controller = controller;
    controller.addActivityListener(_onActivity);
    controller.addControlListener(_onControl);
    widget.onControllerCreated?.call(controller);
    if (mounted) setState(() {});

    try {
      await controller.initialize();
      PerfMetrics.instance.markLoadStart(widget.video.id);
      await controller.load(url: widget.video.url);
    } catch (e) {
      debugPrint('StressPlayerTile ${widget.video.id} load error: $e');
    }
  }

  void _onActivity(PlayerActivityEvent event) {
    if (!mounted) return;
    if (event.state == PlayerActivityState.playing && !_sawFirstFrame) {
      _sawFirstFrame = true;
      PerfMetrics.instance.markFirstFrame(widget.video.id);
    }
    if (widget.naiveRebuilds) {
      setState(() => _state = event.state);
    } else if (_state != event.state) {
      // Status text rebuilds through the stream below; keep the local copy
      // only for the playing indicator without rebuilding the whole tile.
      _state = event.state;
    }
  }

  void _onControl(PlayerControlEvent event) {
    if (!mounted) return;
    if (event.state == PlayerControlState.timeUpdated) {
      if (!_sawFirstFrame) {
        _sawFirstFrame = true;
        PerfMetrics.instance.markFirstFrame(widget.video.id);
      }
      if (widget.naiveRebuilds) {
        final position = event.data?['position'] as int?;
        setState(() {
          if (position != null) {
            _position = Duration(milliseconds: position);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      controller.removeActivityListener(_onActivity);
      controller.removeControlListener(_onControl);
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  String _format(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: Colors.black,
              child: controller != null
                  ? NativeVideoPlayer(controller: controller)
                  : const SizedBox.shrink(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                _buildStatusLabel(controller),
                const SizedBox(width: 8),
                _buildPositionLabel(controller),
                const Spacer(),
                Flexible(
                  child: Text(
                    widget.video.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusLabel(NativeVideoPlayerController? controller) {
    final key = ValueKey('stress_feed_status_${widget.index}');
    if (widget.naiveRebuilds || controller == null) {
      return Text(key: key, _state.name, style: const TextStyle(fontSize: 12));
    }
    return StreamBuilder<PlayerActivityState>(
      stream: controller.playerStateStream,
      initialData: controller.activityState,
      builder: (context, snapshot) => Text(
        key: key,
        (snapshot.data ?? PlayerActivityState.idle).name,
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _buildPositionLabel(NativeVideoPlayerController? controller) {
    if (widget.naiveRebuilds || controller == null) {
      return Text(_format(_position), style: const TextStyle(fontSize: 12));
    }
    return StreamBuilder<Duration>(
      stream: controller.positionStream,
      initialData: controller.currentPosition,
      builder: (context, snapshot) => Text(
        _format(snapshot.data ?? Duration.zero),
        style: const TextStyle(fontSize: 12),
      ),
    );
  }
}

import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

/// A seek bar that shows a storyboard thumbnail preview while dragging —
/// the YouTube-style scrub preview. Feed it any [StoryboardThumbnails]
/// (parsed VTT storyboard or a sprite grid, e.g. from the Vimeo extractor)
/// and it crops the right tile out of the sprite sheet for the drag
/// position; release seeks the player.
class StoryboardScrubBar extends StatefulWidget {
  const StoryboardScrubBar({
    super.key,
    required this.controller,
    this.storyboard,
    this.previewWidth = 160,
  });

  final NativeVideoPlayerController controller;
  final StoryboardThumbnails? storyboard;
  final double previewWidth;

  @override
  State<StoryboardScrubBar> createState() => _StoryboardScrubBarState();
}

class _StoryboardScrubBarState extends State<StoryboardScrubBar> {
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _dragSeconds;

  @override
  void initState() {
    super.initState();
    _position = widget.controller.currentPosition;
    _duration = widget.controller.duration;
    _positionSub = widget.controller.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _durationSub = widget.controller.durationStream.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
  }

  @override
  void dispose() {
    unawaited(_positionSub?.cancel());
    unawaited(_durationSub?.cancel());
    super.dispose();
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// Crops [thumb]'s region out of its sprite sheet, scaled to
  /// [widget.previewWidth].
  Widget _spriteThumb(StoryboardThumbnail thumb) {
    final region = thumb.region;
    if (region == null) {
      // Whole-image entry (storyboards with one image per cue).
      return Image.network(
        thumb.url,
        width: widget.previewWidth,
        fit: BoxFit.contain,
      );
    }
    final scale = widget.previewWidth / region.width;
    return SizedBox(
      width: widget.previewWidth,
      height: region.height * scale,
      child: FittedBox(
        fit: BoxFit.fill,
        child: SizedBox(
          width: region.width,
          height: region.height,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: -region.left,
                top: -region.top,
                child: Image.network(thumb.url),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final durationSeconds = _duration.inSeconds.toDouble();
    final hasDuration = durationSeconds > 0;
    final value = (_dragSeconds ?? _position.inSeconds.toDouble()).clamp(
      0.0,
      hasDuration ? durationSeconds : double.infinity,
    );
    final dragging = _dragSeconds != null;
    final thumb = dragging
        ? widget.storyboard?.thumbnailAt(Duration(seconds: value.round()))
        : null;
    final fraction = hasDuration ? (value / durationSeconds) : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: thumb != null ? null : 0,
          child: thumb == null
              ? null
              : Align(
                  // Track the drag position horizontally (-1..1).
                  alignment: Alignment(fraction * 2 - 1, 0),
                  child: Column(
                    key: const ValueKey('storyboard_preview'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: const [
                            BoxShadow(color: Colors.black54, blurRadius: 6),
                          ],
                        ),
                        child: _spriteThumb(thumb),
                      ),
                      Text(
                        _fmt(Duration(seconds: value.round())),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        Row(
          children: [
            Text(_fmt(Duration(seconds: value.round()))),
            Expanded(
              child: Slider(
                key: const ValueKey('storyboard_scrub_slider'),
                value: hasDuration ? value : 0,
                max: hasDuration ? durationSeconds : 1,
                onChanged: hasDuration
                    ? (v) => setState(() => _dragSeconds = v)
                    : null,
                onChangeEnd: (v) {
                  setState(() => _dragSeconds = null);
                  // Releasing AT the end completes the video immediately
                  // (position snaps to 0 on loop/idle) — stop 1s short.
                  final target = v.clamp(0.0, durationSeconds - 1);
                  unawaited(
                    widget.controller.seekTo(Duration(seconds: target.round())),
                  );
                },
              ),
            ),
            Text(hasDuration ? _fmt(_duration) : '--:--'),
          ],
        ),
      ],
    );
  }
}

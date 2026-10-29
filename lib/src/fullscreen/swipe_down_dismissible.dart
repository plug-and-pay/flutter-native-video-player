import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Swipe-down-to-dismiss for fullscreen pages, Instagram style: once a
/// downward drag starts, the content follows the finger (sideways too),
/// shrinking and rounding its corners as it goes down while the background
/// fades. Letting go past a threshold, or flicking down, dismisses the page;
/// otherwise the content springs back into place.
///
/// The drag still starts as a vertical drag, so horizontal gestures inside
/// (a seek bar) keep working.
class SwipeDownDismissible extends StatefulWidget {
  const SwipeDownDismissible({
    required this.child,
    required this.onDismissed,
    this.backgroundColor = Colors.black,
    this.onDismissing,
    this.onDragStart,
    this.onDragCancel,
    this.dragProgress,
    this.roundContent = true,
    this.contentCornerRadius,
    super.key,
  });

  /// The page content.
  final Widget child;

  /// Called when the user drags down past the dismiss threshold (or flicks
  /// down) and lets go.
  final VoidCallback onDismissed;

  /// Background color behind the content; fades out as the drag progresses.
  final Color backgroundColor;

  /// Called right before [onDismissed] with where the content is on screen
  /// then (dragged and scaled), the background's opacity and the content's
  /// corner radius, so a closing transition can start from there.
  final void Function(
    Rect contentRect,
    double backgroundOpacity,
    double cornerRadius,
  )?
  onDismissing;

  /// Called when a dismiss drag starts (to prepare a closing transition).
  final VoidCallback? onDragStart;

  /// Called when a drag ends without dismissing.
  final VoidCallback? onDragCancel;

  /// Receives the drag's progress (0 at rest, 1 at the dismiss distance and
  /// beyond), e.g. to fade controls out while dragging.
  final ValueNotifier<double>? dragProgress;

  /// Whether the content's corners round as it is dragged down. Off when
  /// the page rounds something inside it instead (a video smaller than the
  /// page), using [contentCornerRadius].
  final bool roundContent;

  /// Receives the corner radius the drag gives the content (growing with
  /// how far it is dragged down), before the content's scale.
  final ValueNotifier<double>? contentCornerRadius;

  @override
  State<SwipeDownDismissible> createState() => _SwipeDownDismissibleState();
}

class _SwipeDownDismissibleState extends State<SwipeDownDismissible>
    with SingleTickerProviderStateMixin {
  /// Dismisses when let go past this fraction of the page height...
  static const double _dismissThreshold = 0.15;

  /// ...or when flicked down this fast (logical px/s), once it moved at
  /// least [_flingMinDistance] of the height.
  static const double _flingVelocity = 900;
  static const double _flingMinDistance = 0.08;

  /// Scale at (and past) half the page height.
  static const double _minScale = 0.55;
  static const double _maxRadius = 28;

  /// Sideways movement follows the finger in full once the content moved
  /// this far down (so a mostly vertical start stays put sideways).
  static const double _sidewaysRamp = 80;

  /// Where the content is, relative to its resting place.
  Offset _offset = Offset.zero;

  /// The finger position the offset is measured from while dragging.
  Offset? _origin;
  bool _dragging = false;

  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..addListener(_handleSettleTick);
  Offset _settleFrom = Offset.zero;

  final GlobalKey _contentKey = GlobalKey();

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  /// The page height, from the last layout.
  double _height = 1;

  /// 0 at rest, 1 at the dismiss distance and beyond.
  double get _progress =>
      (_offset.dy / (_height * _dismissThreshold)).clamp(0.0, 1.0);

  /// How far down the content is, as a fraction of the page height.
  double get _downFraction => (_offset.dy / _height).clamp(0.0, 1.0);

  void _setOffset(Offset offset) {
    setState(() => _offset = offset);
    widget.dragProgress?.value = _progress;
    widget.contentCornerRadius?.value = _cornerRadius;
  }

  void _handleSettleTick() {
    _setOffset(
      Offset.lerp(
        _settleFrom,
        Offset.zero,
        Curves.easeOutCubic.transform(_settle.value),
      )!,
    );
  }

  void _handleDragStart(DragStartDetails details) {
    // Grabbing the content while it springs back continues from there.
    _settle.stop();
    _origin = details.globalPosition - _offset;
    _dragging = true;
    widget.onDragStart?.call();
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final Offset? origin = _origin;
    if (!_dragging || origin == null) return;
    final Offset raw = event.position - origin;
    // Down only; sideways follows once the content is on its way down.
    final double dy = max(0, raw.dy);
    final double sideways = (dy / _sidewaysRamp).clamp(0.0, 1.0);
    _setOffset(Offset(raw.dx * sideways, dy));
  }

  void _handleDragEnd(DragEndDetails details) =>
      _release(details.velocity.pixelsPerSecond.dy);

  /// Let go (or the system cancelled the touch, which counts as a release
  /// without speed): dismisses or springs back, never stays put.
  void _release(double velocity) {
    if (!_dragging) return;
    _dragging = false;
    _origin = null;
    final bool flung =
        velocity > _flingVelocity && _downFraction > _flingMinDistance;
    if (_downFraction > _dismissThreshold || flung) {
      _reportDismissing();
      widget.onDismissed();
      return;
    }
    widget.onDragCancel?.call();
    if (_offset == Offset.zero) return;
    _settleFrom = _offset;
    _settle.forward(from: 0);
  }

  void _reportDismissing() {
    final onDismissing = widget.onDismissing;
    final box = _contentKey.currentContext?.findRenderObject();
    if (onDismissing == null || box is! RenderBox || !box.hasSize) return;
    onDismissing(
      MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      ),
      _backgroundOpacity,
      _cornerRadius * _scale,
    );
  }

  /// Fades out over the first part of the way down, so the page underneath
  /// shows while dragging.
  double get _backgroundOpacity => (1 - _downFraction * 3).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.hasBoundedHeight && constraints.maxHeight > 0) {
          _height = constraints.maxHeight;
        }
        return _buildContent();
      },
    );
  }

  /// The content's scale: shrinking over the first half of the height.
  double get _scale => lerpDouble(
    1,
    _minScale,
    Curves.easeOut.transform((_downFraction * 2).clamp(0.0, 1.0)),
  )!;

  /// The content's corner radius before scaling.
  double get _cornerRadius =>
      lerpDouble(0, _maxRadius, (_downFraction * 4).clamp(0, 1))!;

  Widget _buildContent() {
    final Color background = widget.backgroundColor == Colors.transparent
        ? Colors.transparent
        : widget.backgroundColor.withValues(
            alpha: widget.backgroundColor.a * _backgroundOpacity,
          );

    return Listener(
      onPointerMove: _handlePointerMove,
      child: GestureDetector(
        onVerticalDragStart: _handleDragStart,
        onVerticalDragEnd: _handleDragEnd,
        onVerticalDragCancel: () => _release(0),
        // Required for the recognizer to compete; positions come from the
        // Listener so sideways movement counts too.
        onVerticalDragUpdate: (_) {},
        dragStartBehavior: DragStartBehavior.start,
        behavior: HitTestBehavior.opaque,
        child: ColoredBox(
          color: background,
          child: Transform.translate(
            offset: _offset,
            child: Transform.scale(
              scale: _scale,
              child: ClipRRect(
                key: _contentKey,
                borderRadius: BorderRadius.circular(
                  widget.roundContent ? _cornerRadius : 0,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

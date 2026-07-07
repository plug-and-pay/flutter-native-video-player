import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// A minimal swipe-down-to-dismiss wrapper for fullscreen pages.
///
/// Replaces the `dismissible_page` package dependency with the single
/// behavior this plugin actually used: drag the page down, the content
/// follows the finger while scaling down slightly and rounding its corners,
/// the background fades out, and releasing past a threshold dismisses the
/// page. Releasing before the threshold animates the content back into
/// place.
class SwipeDownDismissible extends StatefulWidget {
  const SwipeDownDismissible({
    required this.child,
    required this.onDismissed,
    this.backgroundColor = Colors.black,
    super.key,
  });

  /// The page content.
  final Widget child;

  /// Called when the user drags down past the dismiss threshold and lets go.
  final VoidCallback onDismissed;

  /// Background color behind the content; fades out as the drag progresses.
  final Color backgroundColor;

  @override
  State<SwipeDownDismissible> createState() => _SwipeDownDismissibleState();
}

class _SwipeDownDismissibleState extends State<SwipeDownDismissible>
    with SingleTickerProviderStateMixin {
  // Tuned to match the defaults of dismissible_page 1.0.2, which this
  // widget replaced, so the swipe feel stays identical.
  static const double _dismissThreshold = 0.15;
  static const double _dragSensitivity = 0.7;
  static const double _maxTranslation = 0.4;
  static const double _minScale = 0.85;
  static const double _minRadius = 7;
  static const double _maxRadius = 30;
  static const Duration _reverseDuration = Duration(milliseconds: 200);

  /// Tracks the drag as a fraction of the page height (0.0 - 1.0).
  late final AnimationController _dragController;
  double _dragExtent = 0;

  @override
  void initState() {
    super.initState();
    _dragController = AnimationController(
      vsync: this,
      duration: Duration.zero,
    );
  }

  @override
  void dispose() {
    _dragController.dispose();
    super.dispose();
  }

  void _handleDragStart(DragStartDetails details) {
    if (_dragController.isAnimating) {
      _dragExtent = _dragController.value * context.size!.height;
      _dragController.stop();
    } else {
      _dragExtent = 0;
      _dragController.value = 0;
    }
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (_dragController.isAnimating) return;
    final delta = details.primaryDelta ?? 0;

    // Down-only: never let the content travel above its resting position.
    if (_dragExtent + delta > 0) {
      _dragExtent += delta;
    } else {
      _dragExtent = 0;
    }

    _dragController.value = _dragExtent / context.size!.height;
  }

  void _handleDragEnd(DragEndDetails details) {
    if (_dragController.isAnimating || _dragController.isDismissed) return;
    if (_dragController.value > _dismissThreshold) {
      widget.onDismissed();
    } else {
      _dragController.animateBack(
        0,
        duration: _reverseDuration,
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragStart: _handleDragStart,
      onVerticalDragUpdate: _handleDragUpdate,
      onVerticalDragEnd: _handleDragEnd,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _dragController,
        builder: (BuildContext context, Widget? child) {
          final dragValue = _dragController.value * _dragSensitivity;

          return ColoredBox(
            color: widget.backgroundColor == Colors.transparent
                ? Colors.transparent
                : widget.backgroundColor
                      .withValues(alpha: (1 - dragValue).clamp(0.0, 1.0)),
            child: FractionalTranslation(
              translation: Offset(0, min(dragValue, _maxTranslation)),
              child: Transform.scale(
                scale: lerpDouble(1, _minScale, dragValue),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    lerpDouble(_minRadius, _maxRadius, dragValue)!,
                  ),
                  child: child,
                ),
              ),
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

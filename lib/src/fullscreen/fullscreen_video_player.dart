import 'package:material_ui/material_ui.dart';

import '../controllers/native_video_player_controller.dart';
import '../legacy_material_support.dart';
import '../models/native_video_player_subtitle_style.dart';
import '../native_video_player_widget.dart';
import 'fullscreen_hero_transition.dart';
import 'swipe_down_dismissible.dart';

/// A fullscreen video player widget that displays the video in fullscreen mode
///
/// This widget is designed to be shown in a fullscreen dialog or route.
/// It includes the video player and optional overlay controls.
class FullscreenVideoPlayer extends StatefulWidget {
  const FullscreenVideoPlayer({
    required this.controller,
    this.overlayBuilder,
    this.subtitleStyle = const NativeVideoPlayerSubtitleStyle(),
    this.backgroundColor = Colors.black,
    this.heroFlight,
    super.key,
  });

  /// The video player controller
  final NativeVideoPlayerController controller;

  /// Optional overlay widget builder for custom controls
  final Widget Function(
    BuildContext context,
    NativeVideoPlayerController controller,
  )?
  overlayBuilder;

  /// Style and position for sidecar subtitles, forwarded to the inner
  /// [NativeVideoPlayer] so fullscreen captions match the inline player.
  final NativeVideoPlayerSubtitleStyle subtitleStyle;

  /// Background color for the fullscreen container
  final Color backgroundColor;

  /// The flight the route opened with, if any; closing refreshes its frame
  /// so the way back starts from the frame on screen.
  final FullscreenHeroFlight? heroFlight;

  @override
  State<FullscreenVideoPlayer> createState() => _FullscreenVideoPlayerState();
}

class _FullscreenVideoPlayerState extends State<FullscreenVideoPlayer> {
  @override
  void initState() {
    super.initState();

    // Register the close callback with the controller
    // This allows the controller to close the fullscreen dialog
    widget.controller.setDartFullscreenCloseCallback(_closeFullscreen);
    widget.controller.setFullscreenVideoCornerRadius(_cornerRadius);
  }

  @override
  void dispose() {
    // Clear the callback when widget is disposed
    widget.controller.setDartFullscreenCloseCallback(null);
    widget.controller.clearFullscreenVideoCornerRadius(_cornerRadius);
    _dragProgress.dispose();
    _cornerRadius.dispose();
    super.dispose();
  }

  bool _closing = false;

  /// The way back, readied as soon as a dismiss drag starts so letting go
  /// flies off without waiting for the frame.
  Future<void>? _preparedReturn;

  /// The swipe's progress, fading the controls out while dragging.
  final ValueNotifier<double> _dragProgress = ValueNotifier<double>(0);

  /// The video's corner radius while dragging, growing with how far it is
  /// pulled down (the fullscreen player clips the video with it).
  final ValueNotifier<double> _cornerRadius = ValueNotifier<double>(0);

  void _handleDragStart() {
    _preparedReturn ??= widget.heroFlight?.prepareReturn(context);
  }

  void _handleDragCancel() {
    // Drag let go short of dismissing: drop the live texture again (nothing
    // copies frames while fullscreen stays open).
    _preparedReturn = null;
    widget.heroFlight?.releaseLiveTexture();
  }

  Future<void> _closeFullscreen() async {
    if (_closing || !mounted) return;
    _closing = true;
    await (_preparedReturn ?? widget.heroFlight?.prepareReturn(context));
    if (!mounted) return;
    // Pop on the next frame to avoid timing issues
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  void _recordDismissal(
    Rect contentRect,
    double backgroundOpacity,
    double cornerRadius,
  ) {
    widget.heroFlight
      ?..dismissedFromRect = contentRect
      ..dismissedBackdropOpacity = backgroundOpacity
      // The video's own corners at that point (see _cornerRadius).
      ..dismissedCornerRadius = cornerRadius;
  }

  @override
  Widget build(BuildContext context) {
    final overlayBuilder = widget.overlayBuilder;
    final bool swipeable = overlayBuilder != null;
    final content = Scaffold(
      // With swipe-to-dismiss the background is the dismissible's, which
      // fades while dragging; only the video and its controls move.
      backgroundColor: swipeable ? Colors.transparent : widget.backgroundColor,
      body: Center(
        child: LegacyMaterialAncestor(
          child: NativeVideoPlayer(
            controller: widget.controller,
            overlayBuilder: swipeable
                ? (
                    BuildContext context,
                    NativeVideoPlayerController controller,
                  ) => ValueListenableBuilder<double>(
                    valueListenable: _dragProgress,
                    // Controls get out of the way as soon as a drag starts.
                    // Nothing loaded: the overlay is all there is to see (an
                    // app's thumbnail often lives in it), so it moves along.
                    builder: (context, progress, child) => IgnorePointer(
                      ignoring: progress > 0,
                      child: Opacity(
                        opacity: controller.hasVideoFrame
                            ? (1 - progress * 4).clamp(0.0, 1.0)
                            : 1,
                        child: child,
                      ),
                    ),
                    child: overlayBuilder(context, controller),
                  )
                : null,
            subtitleStyle: widget.subtitleStyle,
            isFullscreenContext: true,
          ),
        ),
      ),
    );
    if (swipeable) {
      return SwipeDownDismissible(
        onDismissed: _closeFullscreen,
        onDismissing: _recordDismissal,
        onDragStart: _handleDragStart,
        onDragCancel: _handleDragCancel,
        dragProgress: _dragProgress,
        roundContent: false,
        contentCornerRadius: _cornerRadius,
        backgroundColor: widget.backgroundColor,
        child: content,
      );
    }
    return content;
  }
}

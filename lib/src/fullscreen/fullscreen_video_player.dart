import 'package:dismissible_page/dismissible_page.dart';
import 'package:flutter/material.dart';

import '../controllers/native_video_player_controller.dart';
import '../native_video_player_widget.dart';

/// A fullscreen video player widget that displays the video in fullscreen mode
///
/// This widget is designed to be shown in a fullscreen dialog or route.
/// It includes the video player and optional overlay controls.
class FullscreenVideoPlayer extends StatefulWidget {
  const FullscreenVideoPlayer({
    required this.controller,
    this.overlayBuilder,
    this.backgroundColor = Colors.black,
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

  /// Background color for the fullscreen container
  final Color backgroundColor;

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
  }

  @override
  void dispose() {
    // Clear the callback when widget is disposed
    widget.controller.setDartFullscreenCloseCallback(null);
    super.dispose();
  }

  void _closeFullscreen() {
    if (mounted && context.mounted) {
      // Pop on the next frame to avoid timing issues
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && context.mounted) {
          Navigator.of(context).pop();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = Scaffold(
      backgroundColor: widget.backgroundColor,
      body: Center(
        child: NativeVideoPlayer(
          controller: widget.controller,
          overlayBuilder: widget.overlayBuilder,
          isFullscreenContext: true,
        ),
      ),
    );
    if (widget.overlayBuilder != null) {
      return DismissiblePage(
        onDismissed: _closeFullscreen,
        direction: DismissiblePageDismissDirection.down,
        backgroundColor: widget.backgroundColor,
        isFullScreen: true,
        child: content,
      );
    }
    return content;
  }
}

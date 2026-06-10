import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'config/native_video_player_config.dart';
import 'controllers/native_video_player_controller.dart';
import 'enums/native_video_player_event.dart';
import 'models/native_video_player_subtitle_style.dart';
import 'subtitles/subtitle_overlay.dart';

/// A native video player widget that wraps platform-specific video players
/// (AVPlayerViewController on iOS, ExoPlayer on Android).
///
/// Android handles fullscreen natively using a Dialog, so only ONE platform view is used.
/// iOS uses native AVPlayerViewController presentation for fullscreen.
///
/// **Android PiP Support:**
/// PiP works automatically on Android using the floating package.
/// The video aspect ratio is automatically calculated from quality information.
/// Custom overlays are automatically hidden when entering PiP mode.
///
/// Note: Android PiP captures the entire activity window. For best results,
/// ensure your video player is the primary content on screen when entering PiP.
class NativeVideoPlayer extends StatefulWidget {
  const NativeVideoPlayer({
    required this.controller,
    this.overlayBuilder,
    this.overlayFadeDuration = const Duration(milliseconds: 300),
    this.isFullscreenContext = false,
    this.subtitleStyle = const NativeVideoPlayerSubtitleStyle(),
    super.key,
  });

  final NativeVideoPlayerController controller;

  /// Style and position for sidecar (external VTT/SRT) subtitles rendered by
  /// the plugin's Flutter subtitle layer. Rebuild with a new style to change
  /// it at runtime. Embedded native tracks use system caption settings.
  final NativeVideoPlayerSubtitleStyle subtitleStyle;

  /// Optional overlay widget builder that renders on top of the video player.
  /// The builder receives the BuildContext and controller to build custom controls.
  /// The overlay is displayed in both normal and fullscreen modes with fade animations.
  final Widget Function(
    BuildContext context,
    NativeVideoPlayerController controller,
  )?
  overlayBuilder;

  /// Duration for overlay fade in/out animations.
  /// Defaults to 300ms.
  final Duration overlayFadeDuration;

  /// When true, this instance is the fullscreen host (Dart fullscreen dialog).
  /// Passed to the platform view as [isDartFullscreen] so iOS can use a dedicated
  /// AVPlayerViewController and avoid moving the shared view away from the inline slot.
  final bool isFullscreenContext;

  @override
  State<NativeVideoPlayer> createState() => _NativeVideoPlayerState();
}

class _NativeVideoPlayerState extends State<NativeVideoPlayer>
    with SingleTickerProviderStateMixin {
  int? _platformViewId;
  late AnimationController _overlayAnimationController;
  late Animation<double> _overlayOpacity;
  bool _overlayVisible = true;
  Timer? _hideTimer;
  StreamSubscription<bool>? _overlayLockSubscription;

  @override
  void initState() {
    super.initState();
    // Pass the overlay builder to the controller
    widget.controller.setOverlayBuilder(widget.overlayBuilder);

    // Set up animation controller for overlay fade
    _overlayAnimationController = AnimationController(
      duration: widget.overlayFadeDuration,
      vsync: this,
    );

    _overlayOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _overlayAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    // Start with overlay visible if we have one
    if (widget.overlayBuilder != null) {
      _overlayAnimationController.value = 1.0;
      _startHideTimer();
    }

    // Listen to controller events to restart hide timer on user interaction
    widget.controller.addControlListener(_handleControlEvent);

    // Listen to overlay lock state changes
    _overlayLockSubscription = widget.controller.isOverlayLockedStream.listen((
      isLocked,
    ) {
      if (isLocked) {
        // When locked, show overlay and cancel hide timer
        _hideTimer?.cancel();
        if (!_overlayVisible) {
          setState(() {
            _overlayVisible = true;
            _overlayAnimationController.forward();
          });
        }
      } else {
        // When unlocked, start the hide timer
        if (_overlayVisible) {
          _startHideTimer();
        }
      }
    });
  }

  void _handleControlEvent(PlayerControlEvent event) {
    // Hide custom overlay when entering PiP (Android only)
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (event.state == PlayerControlState.pipStarted && _overlayVisible) {
        setState(() {
          _overlayVisible = false;
          _overlayAnimationController.reverse();
          _hideTimer?.cancel();
        });
        return;
      }

      // Show custom overlay when exiting PiP (Android only)
      if (event.state == PlayerControlState.pipStopped && !_overlayVisible) {
        setState(() {
          _overlayVisible = true;
          _overlayAnimationController.forward();
          _startHideTimer();
        });
        return;
      }
    }

    // Show overlay when exiting fullscreen
    if (event.state == PlayerControlState.fullscreenExited &&
        !_overlayVisible) {
      setState(() {
        _overlayVisible = true;
        _overlayAnimationController.forward();
        _startHideTimer();
      });
    }

    // Restart hide timer on any control interaction (except time updates)
    if (_overlayVisible && event.state != PlayerControlState.timeUpdated) {
      _startHideTimer();
    }
  }

  void _startHideTimer() {
    // Don't start hide timer if overlay is locked
    if (widget.controller.isOverlayLocked) {
      return;
    }

    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      // Don't hide if overlay is locked
      if (mounted && _overlayVisible && !widget.controller.isOverlayLocked) {
        setState(() {
          _overlayVisible = false;
          _overlayAnimationController.reverse();
        });
      }
    });
  }

  void _toggleOverlay() {
    // Don't allow toggle if overlay is locked
    if (widget.controller.isOverlayLocked) {
      return;
    }

    setState(() {
      _overlayVisible = !_overlayVisible;
      if (_overlayVisible) {
        _overlayAnimationController.forward();
        _startHideTimer();
      } else {
        _hideTimer?.cancel();
        _overlayAnimationController.reverse();
      }
    });
  }

  @override
  void dispose() {
    // Notify the controller that this platform view is being disposed
    if (_platformViewId != null) {
      widget.controller.onPlatformViewDisposed(_platformViewId!);
    }

    widget.controller.removeControlListener(_handleControlEvent);
    _overlayLockSubscription?.cancel();
    _hideTimer?.cancel();
    _overlayAnimationController.dispose();
    super.dispose();
  }

  /// Called when the platform view is created
  Future<void> _onPlatformViewCreated(int id) async {
    _platformViewId = id;
    await widget.controller.onPlatformViewCreated(id, context);
    // The first layout usually happens before the platform view exists, so
    // report the viewport size now that there is a native receiver.
    _maybeReportViewportSize();
  }

  /// Last layout constraints seen by the LayoutBuilder around the platform
  /// view, in logical pixels.
  BoxConstraints? _lastConstraints;
  double _devicePixelRatio = 1.0;

  /// Last viewport size sent to the native side, in physical pixels.
  Size? _reportedViewportSize;

  /// Reports the platform view's physical pixel size to the native side so
  /// adaptive quality selection can be capped to what the view can display
  /// (see [NativeVideoPlayerConfig.qualityForViewportSize]). No-op unless the
  /// config flag is enabled, the platform view exists, and the size changed.
  void _maybeReportViewportSize() {
    if (!NativeVideoPlayerConfig.global.qualityForViewportSize) {
      return;
    }
    final int? viewId = _platformViewId;
    final BoxConstraints? constraints = _lastConstraints;
    if (viewId == null || constraints == null) {
      return;
    }
    if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
      return;
    }
    final size = Size(
      (constraints.maxWidth * _devicePixelRatio).roundToDouble(),
      (constraints.maxHeight * _devicePixelRatio).roundToDouble(),
    );
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    if (_reportedViewportSize == size) {
      return;
    }
    _reportedViewportSize = size;
    unawaited(_sendViewportSize(viewId, size));
  }

  Future<void> _sendViewportSize(int viewId, Size physicalSize) async {
    try {
      await const MethodChannel(
        'native_video_player',
      ).invokeMethod<void>('setViewportSize', <String, dynamic>{
        'viewId': viewId,
        'width': physicalSize.width.round(),
        'height': physicalSize.height.round(),
      });
      debugPrint(
        'NativeVideoPlayer: viewport '
        '${physicalSize.width.round()}x${physicalSize.height.round()} '
        'reported for view $viewId (quality cap)',
      );
    } catch (e) {
      debugPrint('Failed to report viewport size: $e');
    }
  }

  Map<String, dynamic> _getCreationParams() {
    final Map<String, dynamic> params = Map<String, dynamic>.from(
      widget.controller.creationParams,
    );
    if (widget.isFullscreenContext) {
      params['isDartFullscreen'] = true;
    }
    return params;
  }

  /// The platform view is built once and cached: rebuilding this State (e.g.
  /// overlay visibility setState) must never re-run UiKitView /
  /// PlatformViewLink construction.
  Widget? _cachedPlatformView;

  Widget _platformView() => _cachedPlatformView ??= _buildPlatformView();

  Widget _buildPlatformView() {
    const String viewType = 'native_video_player';
    final Map<String, dynamic> creationParams = _getCreationParams();

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: viewType,
        onPlatformViewCreated: _onPlatformViewCreated,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
          Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
        },
      );
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      // Use PlatformViewLink with AndroidViewSurface to enable Hybrid Composition
      // This fixes video scaling/cropping issues that occur with Virtual Display mode
      return PlatformViewLink(
        viewType: viewType,
        surfaceFactory: (context, controller) {
          return AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
              Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
            },
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          );
        },
        onCreatePlatformView: (params) {
          final AndroidViewController controller =
              PlatformViewsService.initSurfaceAndroidView(
                id: params.id,
                viewType: viewType,
                layoutDirection: TextDirection.ltr,
                creationParams: creationParams,
                creationParamsCodec: const StandardMessageCodec(),
                onFocus: () {
                  params.onFocusChanged(true);
                },
              );
          controller.addOnPlatformViewCreatedListener(
            params.onPlatformViewCreated,
          );
          controller.addOnPlatformViewCreatedListener(_onPlatformViewCreated);
          return controller..create();
        },
      );
    }

    return const Text(
      'Only iOS and Android are supported',
      textAlign: TextAlign.center,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Track the view's on-screen size for viewport-based quality capping
    // (rotation/resize re-runs this builder; the report deduplicates).
    final platformView = LayoutBuilder(
      builder: (context, constraints) {
        _lastConstraints = constraints;
        _devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
        _maybeReportViewportSize();
        return _platformView();
      },
    );

    // Sidecar subtitle layer: renders the active external-VTT/SRT cue lines
    // above the video and below the controls. Suppressed during PiP (the
    // Flutter UI is not part of the iOS PiP window; on Android the native
    // sideloaded track takes over so captions stay visible there).
    final subtitleLayer = StreamBuilder<bool>(
      stream: widget.controller.isPipEnabledStream,
      initialData: widget.controller.isPipEnabled,
      builder: (context, pipSnapshot) {
        if (pipSnapshot.data ?? false) return const SizedBox.shrink();
        return SubtitleOverlay(
          cueLines: widget.controller.activeSidecarCueLines,
          style: widget.subtitleStyle,
        );
      },
    );

    Widget content;

    // Without a custom controls overlay, the stack is just the platform view
    // plus the subtitle layer
    if (widget.overlayBuilder == null) {
      content = Stack(children: [platformView, subtitleLayer]);
    } else {
      // Wrap platform view with animated overlay in a Stack
      content = Stack(
        children: [
          // Platform view
          platformView,
          // Subtitles render below the controls overlay
          subtitleLayer,
          // Transparent tap layer when overlay is hidden
          if (!_overlayVisible)
            Positioned.fill(
              child: GestureDetector(
                onTap: _toggleOverlay,
                behavior: HitTestBehavior.opaque,
                child: Container(color: Colors.transparent),
              ),
            ),
          // Animated overlay with tap-to-hide, isolated in its own repaint
          // boundary so fade animations only repaint the overlay layer (a
          // boundary around the platform view itself would be useless — it
          // composites outside Flutter's raster cache)
          RepaintBoundary(
            child: FadeTransition(
              opacity: _overlayOpacity,
              child: GestureDetector(
                onTap: _overlayVisible ? _toggleOverlay : null,
                behavior: HitTestBehavior.deferToChild,
                child: IgnorePointer(
                  ignoring: !_overlayVisible,
                  child: widget.overlayBuilder!(context, widget.controller),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return content;
  }
}

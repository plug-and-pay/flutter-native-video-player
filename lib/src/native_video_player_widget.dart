import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'config/native_video_player_config.dart';
import 'controllers/native_video_player_controller.dart';
import 'enums/native_video_player_event.dart';
import 'fullscreen/fullscreen_hero_transition.dart';
import 'models/native_video_player_poster.dart';
import 'models/native_video_player_subtitle_style.dart';
import 'models/native_video_player_video_size.dart';
import 'platform/video_player_method_channel.dart';
import 'platform/view_visibility.dart';
import 'poster/poster_layer.dart';
import 'subtitles/subtitle_overlay.dart';

/// A native video player widget that wraps platform-specific video players
/// (AVPlayerViewController on iOS, ExoPlayer on Android).
///
/// Android handles fullscreen natively using a Dialog, so only ONE platform view is used.
/// iOS uses native AVPlayerViewController presentation for fullscreen.
///
/// **Android PiP Support:**
/// PiP works automatically on Android from Dart fullscreen; the plugin drives
/// the activity's picture-in-picture itself.
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
    this.poster,
    this.borderRadius = 0,
    super.key,
  });

  final NativeVideoPlayerController controller;

  /// Corner radius of the inline player, in logical pixels. Use this instead
  /// of wrapping the player in a `ClipRRect`.
  ///
  /// On iOS the native view rounds its own corners and only the Flutter
  /// layers (poster, subtitles, overlay) are clipped. A rounded Flutter clip
  /// around an iOS platform view breaks compositing on Flutter 3.47: content
  /// drawn over an earlier platform view (a drawer, a dialog) can end up
  /// behind it. The fullscreen player has square corners.
  final double borderRadius;

  /// Style and position for sidecar (external VTT/SRT) subtitles rendered by
  /// the plugin's Flutter subtitle layer. Rebuild with a new style to change
  /// it at runtime. Embedded native tracks use system caption settings.
  final NativeVideoPlayerSubtitleStyle subtitleStyle;

  /// A custom thumbnail over the video until it plays, with an optional
  /// preview animation after a delay. See [NativeVideoPlayerPoster].
  final NativeVideoPlayerPoster? poster;

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
  /// The Flutter layers over the video (poster, controls overlay), which
  /// fly into fullscreen in place of the video while it has no frame yet.
  final GlobalKey _posterBoundaryKey = GlobalKey();
  final GlobalKey _overlayBoundaryKey = GlobalKey();

  /// What this player shows in Flutter now (poster under overlay, on black),
  /// as PNG. Null when neither layer is painted.
  Future<Uint8List?> _snapshotLayers() async {
    if (!mounted) return null;
    final double pixelRatio = MediaQuery.devicePixelRatioOf(context);
    // Both layers are taken from the frame on screen now, before awaiting
    // either: a rebuild in between (the overlay restyling for fullscreen)
    // must not reach the snapshot.
    final List<Future<ui.Image>> captures = <Future<ui.Image>>[];
    for (final GlobalKey key in <GlobalKey>[
      _posterBoundaryKey,
      _overlayBoundaryKey,
    ]) {
      final RenderObject? boundary = key.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary || !boundary.hasSize) continue;
      try {
        captures.add(boundary.toImage(pixelRatio: pixelRatio));
      } catch (_) {
        // Not painted yet (e.g. a hidden overlay): leave that layer out.
      }
    }
    final List<ui.Image> layers = <ui.Image>[];
    for (final Future<ui.Image> capture in captures) {
      try {
        layers.add(await capture);
      } catch (_) {
        // Not painted yet: leave that layer out.
      }
    }
    if (layers.isEmpty) return null;
    final int width = layers.first.width;
    final int height = layers.first.height;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder)
      ..drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = const Color(0xFF000000),
      );
    for (final ui.Image layer in layers) {
      canvas.drawImage(layer, Offset.zero, Paint());
      layer.dispose();
    }
    final ui.Image image = await recorder.endRecording().toImage(width, height);
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    return bytes?.buffer.asUint8List();
  }

  int? _platformViewId;
  late AnimationController _overlayAnimationController;
  late Animation<double> _overlayOpacity;
  bool _overlayVisible = true;
  Timer? _hideTimer;
  StreamSubscription<bool>? _overlayLockSubscription;

  @override
  void initState() {
    super.initState();
    // Pass the overlay builder to the controller (inline views only: the
    // Dart fullscreen host builds its own from the controller's, and storing
    // it would make the next fullscreen reuse this one's, which is gone).
    if (!widget.isFullscreenContext) {
      widget.controller.setOverlayBuilder(widget.overlayBuilder);
    }
    // Cache the subtitle style on the controller so the Dart fullscreen host
    // (which builds its own NativeVideoPlayer) renders captions identically.
    widget.controller.setSubtitleStyle(widget.subtitleStyle);

    // Texture rendering mode: decided per view at creation, after the
    // overlay determined the effective showNativeControls. Views with
    // native controls and Dart-fullscreen hosts keep using platform views.
    // On iOS, controllers with automatic PiP additionally keep platform
    // views (auto PiP needs an on-screen AVPlayerLayer at background time);
    // manual PiP on a texture tile live-swaps to a platform view instead.
    final controlsHidden =
        widget.controller.creationParams['showNativeControls'] == false;
    final iosAutoPip =
        widget.controller.allowsPictureInPicture &&
        widget.controller.canStartPictureInPictureAutomatically;
    // Android's Dart fullscreen host is a texture too when tiles are: then
    // the fullscreen flight and swipe-down move plain Flutter content.
    _useTextureBackend =
        !kIsWeb &&
        (!widget.isFullscreenContext ||
            defaultTargetPlatform == TargetPlatform.android) &&
        controlsHidden &&
        ((defaultTargetPlatform == TargetPlatform.android &&
                NativeVideoPlayerConfig.global.androidTextureMode) ||
            (defaultTargetPlatform == TargetPlatform.iOS &&
                NativeVideoPlayerConfig.global.iosTextureMode &&
                !iosAutoPip));
    if (_useTextureBackend) {
      _swapRequestSubscription = widget.controller.surfaceSwapRequests.listen(
        _handleSurfaceSwapRequest,
      );
      unawaited(_createTextureBackend());
    }

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
    widget.controller.addActivityListener(_handleActivityEvent);
    widget.controller.fullscreenFlightPhase.addListener(_handleFlightPhase);

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Another page route over this one drives this route's
    // secondaryAnimation: from its first frame until it is popped again.
    // Nested navigators (a tab shell) put this route inside another route,
    // and a page pushed on an outer navigator only drives the outer route's,
    // so every enclosing route counts.
    // A route's own animation runs while it is pushed or popped.
    final List<Animation<double>> coverAnimations = <Animation<double>>[];
    final List<Animation<double>> ownAnimations = <Animation<double>>[];
    ModalRoute<dynamic>? route = ModalRoute.of(context);
    while (route != null) {
      final Animation<double>? secondary = route.secondaryAnimation;
      if (secondary != null) coverAnimations.add(secondary);
      final Animation<double>? own = route.animation;
      if (own != null) ownAnimations.add(own);
      final BuildContext? navigatorContext = route.navigator?.context;
      route = navigatorContext == null || !navigatorContext.mounted
          ? null
          : ModalRoute.of(navigatorContext);
    }
    if (!listEquals(coverAnimations, _coverAnimations)) {
      for (final Animation<double> animation in _coverAnimations) {
        animation.removeStatusListener(_handleCoverStatus);
      }
      _coverAnimations = coverAnimations;
      for (final Animation<double> animation in coverAnimations) {
        animation.addStatusListener(_handleCoverStatus);
      }
      _covered = _anyRouteCovered;
    }
    if (!listEquals(ownAnimations, _ownAnimations)) {
      for (final Animation<double> animation in _ownAnimations) {
        animation.removeStatusListener(_handleOwnRouteStatus);
      }
      _ownAnimations = ownAnimations;
      for (final Animation<double> animation in ownAnimations) {
        animation.addStatusListener(_handleOwnRouteStatus);
      }
      _routeInMotion = _anyOwnRouteInMotion;
    }
  }

  /// Android hybrid composition draws a platform view at full opacity and
  /// size whatever its route's transition does, so a page's video popped in
  /// before its page had faded in, and stayed until its page was gone. While
  /// this view's page is pushed or popped there is no native view then, just
  /// black that moves with the page: it is created once the push is done,
  /// and released as soon as a pop starts (the page below gets the shared
  /// player back sooner, too). Hiding a live view instead leaves a stale
  /// image of its page in the compositor, so the view is released, not
  /// hidden.
  bool get _defersOnAndroid =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      !_useTextureBackend;

  List<Animation<double>> _ownAnimations = <Animation<double>>[];
  bool _routeInMotion = false;

  bool get _anyOwnRouteInMotion => _ownAnimations.any(
    (Animation<double> animation) =>
        animation.status == AnimationStatus.forward ||
        animation.status == AnimationStatus.reverse,
  );

  void _handleOwnRouteStatus(AnimationStatus status) {
    if (!_defersOnAndroid) return;
    final bool moving = _anyOwnRouteInMotion;
    if (moving == _routeInMotion || !mounted) return;
    if (moving) _releasePlatformView();
    setState(() => _routeInMotion = moving);
  }

  /// Drops the native view (it is rebuilt by [_platformView] when needed).
  void _releasePlatformView() {
    final int? viewId = _platformViewId;
    if (viewId != null) {
      widget.controller.onPlatformViewDisposed(viewId);
      _platformViewId = null;
    }
    _cachedPlatformView = null;
    _reportedViewportSize = null;
  }

  @override
  void didUpdateWidget(NativeVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the controller's cached style in sync (e.g. theme change) so the
    // fullscreen host picks up the latest one.
    if (widget.subtitleStyle != oldWidget.subtitleStyle) {
      widget.controller.setSubtitleStyle(widget.subtitleStyle);
    }
    // The native view got its corners with the creation params; the Flutter
    // layers follow on rebuild, the native view only when told.
    final int? viewId = _platformViewId;
    if (_roundsNatively &&
        viewId != null &&
        widget.borderRadius != oldWidget.borderRadius) {
      unawaited(_sendCornerRadius(viewId));
    }
  }

  Future<void> _sendCornerRadius(int viewId) async {
    try {
      await const MethodChannel('native_video_player').invokeMethod<void>(
        'setCornerRadius',
        <String, dynamic>{'viewId': viewId, 'cornerRadius': _cornerRadius},
      );
    } catch (e) {
      debugPrint('Failed to set the corner radius: $e');
    }
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
    // Playback-driven events are not interaction: they must not keep the
    // overlay up.
    if (_overlayVisible &&
        event.state != PlayerControlState.timeUpdated &&
        event.state != PlayerControlState.chapterChanged &&
        event.state != PlayerControlState.chaptersChanged) {
      _startHideTimer();
    }
  }

  /// iOS platform views are native views the engine layers around Flutter
  /// content, and while another route slides over this one the video can end
  /// up drawn on top of that route. So while this route is covered (another
  /// page route animating over it or sitting on top), the platform view is
  /// left out of the scene and the player's poster frame is painted in its
  /// place. Texture tiles are plain Flutter content and need none of this.
  /// Android's hybrid composition layers its views correctly, and leaving a
  /// view out of the scene there leaves a stale image of its page behind,
  /// which shows whenever a video surface is briefly empty.
  bool get _hidesWhenCovered =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      !_useTextureBackend;

  List<Animation<double>> _coverAnimations = <Animation<double>>[];
  bool _covered = false;

  bool get _anyRouteCovered => _coverAnimations.any(
    (Animation<double> animation) => !animation.isDismissed,
  );

  void _handleCoverStatus(AnimationStatus status) {
    if (!_hidesWhenCovered) return;
    // A route starts sliding over this one, or off it again: the frame
    // showing now (the video kept playing while it was covered).
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      unawaited(_capturePosterFrame());
    }
    final covered = _anyRouteCovered;
    if (covered != _covered && mounted) {
      setState(() => _covered = covered);
    }
  }

  void _handleFlightPhase() {
    if (!widget.isFullscreenContext && mounted) setState(() {});
  }

  /// The video is out in a fullscreen flight: the inline slot stays empty
  /// (texture tiles always; platform views see [_coverablePlatformView]).
  bool get _videoOut =>
      !widget.isFullscreenContext &&
      widget.controller.fullscreenFlightPhase.value ==
          FullscreenFlightPhase.out;

  void _handleActivityEvent(PlayerActivityEvent event) {
    if (!_hidesWhenCovered) return;
    // Keeps a poster ready for a paused video, so a route pushed over it
    // shows the exact frame from its first transition frame on.
    final bool stopped =
        event.state == PlayerActivityState.paused ||
        event.state == PlayerActivityState.completed;
    // The first capture of a video attaches the native frame output and
    // waits for a frame (up to a second); doing it once playback starts makes
    // the capture when a route covers the player immediate, and leaves a
    // frame to show until that one lands instead of black.
    final bool firstPlay =
        event.state == PlayerActivityState.playing &&
        widget.controller.posterFrame == null;
    if (stopped || firstPlay) {
      unawaited(_capturePosterFrame());
    }
  }

  Future<void> _capturePosterFrame() async {
    final int? viewId = _platformViewId;
    if (viewId == null) return;
    final double? width = _lastConstraints?.maxWidth;
    final Uint8List? frame = await widget.controller.capturePosterFrame(
      viewId,
      maxWidth: width != null && width.isFinite
          ? (width * _devicePixelRatio).round()
          : null,
    );
    if (frame == null || !mounted) return;
    // Decoded before it is shown, so swapping it in never flashes black.
    await precacheImage(MemoryImage(frame), context);
    if (mounted) setState(() {});
  }

  /// The platform view, or the poster frame while a transition would draw
  /// it wrong (see [_hidesWhenCovered]). The platform view stays mounted
  /// (hidden) so the native view survives.
  Widget _coverablePlatformView() {
    if (_defersOnAndroid && _routeInMotion) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    if (!_hidesWhenCovered) return _platformView();
    final FullscreenFlightPhase flight = widget.isFullscreenContext
        ? FullscreenFlightPhase.none
        : widget.controller.fullscreenFlightPhase.value;
    final bool hidden = _covered || flight != FullscreenFlightPhase.none;
    final Uint8List? poster = widget.controller.posterFrame;
    // While the video is out in a fullscreen flight, its inline slot stays
    // empty (a swipe-down shows the page with a gap for it), until the way
    // back starts: the poster is under the landing video then, so the live
    // view's first frame never shows a gap.
    final bool slotEmpty = flight == FullscreenFlightPhase.out;
    return Stack(
      fit: StackFit.expand,
      children: [
        Visibility(
          visible: !hidden,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: _platformView(),
        ),
        if (slotEmpty)
          const SizedBox.expand()
        else if (hidden)
          _roundedFlutterContent(
            ColoredBox(
              color: const Color(0xFF000000),
              child: poster == null
                  ? null
                  : Image.memory(
                      poster,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
            ),
          ),
      ],
    );
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
      ViewVisibility.unregister(_platformViewId!, context);
      widget.controller.onPlatformViewDisposed(_platformViewId!);
    }
    // A swap that never completed still owns the old texture view.
    if (_swapOldTextureViewId != null) {
      widget.controller.onPlatformViewDisposed(_swapOldTextureViewId!);
      _swapOldTextureViewId = null;
    }

    widget.controller.removeControlListener(_handleControlEvent);
    widget.controller.removeActivityListener(_handleActivityEvent);
    widget.controller.fullscreenFlightPhase.removeListener(_handleFlightPhase);
    for (final Animation<double> animation in _coverAnimations) {
      animation.removeStatusListener(_handleCoverStatus);
    }
    for (final Animation<double> animation in _ownAnimations) {
      animation.removeStatusListener(_handleOwnRouteStatus);
    }
    _overlayLockSubscription?.cancel();
    _swapRequestSubscription?.cancel();
    _pendingSwapCompleter?.complete(false);
    _pendingSwapCompleter = null;
    _hideTimer?.cancel();
    _overlayAnimationController.dispose();
    super.dispose();
  }

  /// Called when the platform view is created
  Future<void> _onPlatformViewCreated(int id) async {
    _platformViewId = id;
    ViewVisibility.register(id, context, controllerId: widget.controller.id);
    if (widget.isFullscreenContext) {
      widget.controller.registerFullscreenView(id);
    }
    await widget.controller.onPlatformViewCreated(id, context);
    widget.controller.registerViewSnapshot(id, _snapshotLayers);
    // The first layout usually happens before the platform view exists, so
    // report the viewport size now that there is a native receiver.
    _maybeReportViewportSize();
    // If this platform view replaces a texture tile (iOS manual-PiP swap),
    // finish the handoff now that the new surface is live.
    _completeSurfaceSwapIfPending();
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
    if (_forceLightPlatformView) {
      // PiP swap target: a lightweight AVPlayerLayer view, the path PiP is
      // verified on (a custom AVPictureInPictureController on a layer owned
      // by AVPlayerViewController can silently fail to start).
      params['lightweightInlineViews'] = true;
    }
    if (_roundsNatively) {
      params['cornerRadius'] = _cornerRadius;
    }
    return params;
  }

  /// The inline player's corner radius; the fullscreen player is square.
  double get _cornerRadius =>
      widget.isFullscreenContext ? 0 : widget.borderRadius;

  /// Whether the native view rounds its own corners (see
  /// [NativeVideoPlayer.borderRadius]).
  bool get _roundsNatively => defaultTargetPlatform == TargetPlatform.iOS;

  /// Clips Flutter-drawn content to the player's corners.
  Widget _roundedFlutterContent(Widget child) {
    if (_cornerRadius <= 0) return child;
    return ClipRRect(
      borderRadius: BorderRadius.circular(_cornerRadius),
      child: child,
    );
  }

  /// Forces the platform view built after a PiP surface swap onto the
  /// lightweight AVPlayerLayer path.
  bool _forceLightPlatformView = false;

  /// The platform view is built once and cached: rebuilding this State (e.g.
  /// overlay visibility setState) must never re-run UiKitView /
  /// PlatformViewLink construction.
  Widget? _cachedPlatformView;

  Widget _platformView() => _cachedPlatformView ??= _buildPlatformView();

  /// Texture rendering mode (androidTextureMode/iosTextureMode): decided in
  /// initState; flips off permanently when a PiP swap converts this tile to
  /// a platform view.
  bool _useTextureBackend = false;

  /// Engine texture id once the native backend exists.
  int? _textureId;

  /// In-flight PiP surface swap (iOS): the texture view being replaced and
  /// the completer to resolve once the platform view took over.
  StreamSubscription<Completer<bool>>? _swapRequestSubscription;
  Completer<bool>? _pendingSwapCompleter;
  int? _swapOldTextureViewId;

  /// Converts this texture tile to a platform view (iOS manual-PiP path).
  /// The platform view attaches the same shared player — most recently
  /// attached layer displays, so the handoff is visually seamless; the old
  /// texture half is disposed once the platform view reports created.
  void _handleSurfaceSwapRequest(Completer<bool> completer) {
    if (!mounted || !_useTextureBackend) {
      completer.complete(!_useTextureBackend && mounted);
      return;
    }
    if (_pendingSwapCompleter != null) {
      completer.complete(false);
      return;
    }
    _pendingSwapCompleter = completer;
    _swapOldTextureViewId = _platformViewId;
    _forceLightPlatformView = true;
    setState(() {
      _useTextureBackend = false;
      _textureId = null;
      // build() now constructs the platform view; _onPlatformViewCreated
      // completes the swap.
    });
  }

  void _completeSurfaceSwapIfPending() {
    final completer = _pendingSwapCompleter;
    if (completer == null) return;
    _pendingSwapCompleter = null;

    final oldViewId = _swapOldTextureViewId;
    _swapOldTextureViewId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Dispose the texture half only after the platform view rendered a
      // frame (no black-frame gap).
      if (oldViewId != null) {
        widget.controller.onPlatformViewDisposed(oldViewId);
      }
      if (!completer.isCompleted) {
        completer.complete(true);
      }
    });
  }

  /// One-time hot-restart hygiene per isolate: native texture backends
  /// survive a hot restart while the Dart side forgets them.
  static bool _textureBackendsResetDone = false;

  Future<void> _createTextureBackend() async {
    if (!_textureBackendsResetDone) {
      _textureBackendsResetDone = true;
      await VideoPlayerMethodChannel.disposeAllTextureViews();
    }

    // Allocate the synthetic viewId from the same registry as real platform
    // views, so it can never collide with one. Everything downstream
    // (channels, routing, viewDisposed) treats it like a platform view id.
    final int viewId = platformViewsRegistry.getNextPlatformViewId();
    final params = _getCreationParams()..['viewId'] = viewId;

    try {
      final textureId = await VideoPlayerMethodChannel.createTextureView(
        params,
      );
      if (!mounted) {
        // Disposed while creating: release the native backend directly (the
        // normal dispose flow never learned this view existed).
        unawaited(VideoPlayerMethodChannel.notifyViewDisposed(viewId));
        return;
      }
      setState(() {
        _platformViewId = viewId;
        _textureId = textureId;
      });
      widget.controller.registerTextureView(viewId);
      widget.controller.registerTextureId(viewId, textureId);
      if (widget.isFullscreenContext) {
        widget.controller.registerFullscreenView(viewId);
      }
      await widget.controller.onPlatformViewCreated(viewId, context);
      widget.controller.registerViewSnapshot(viewId, _snapshotLayers);
      _maybeReportViewportSize();
    } catch (e) {
      debugPrint('NativeVideoPlayer: texture backend creation failed: $e');
    }
  }

  /// Letterboxes the engine texture to the video's aspect ratio inside
  /// whatever box the app gives the player — mirroring the platform views'
  /// RESIZE_MODE_FIT/resizeAspect behavior. Black until the size is known.
  Widget _textureWidget() {
    if (_videoOut) return const SizedBox.expand();
    final textureId = _textureId;
    if (textureId == null) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    return StreamBuilder<NativeVideoPlayerVideoSize>(
      stream: widget.controller.videoSizeStream,
      initialData: widget.controller.videoSize,
      builder: (context, snapshot) {
        final videoSize = snapshot.data;
        Widget texture = Texture(textureId: textureId);
        if (videoSize == null ||
            videoSize.width <= 0 ||
            videoSize.height <= 0) {
          return ColoredBox(color: const Color(0xFF000000), child: texture);
        }
        if (videoSize.rotationCorrection % 360 != 0) {
          texture = RotatedBox(
            quarterTurns: videoSize.rotationCorrection ~/ 90,
            child: texture,
          );
        }
        return ColoredBox(
          color: const Color(0xFF000000),
          child: Center(
            child: AspectRatio(
              aspectRatio: videoSize.aspectRatio,
              child: texture,
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlatformView() {
    const String viewType = 'native_video_player';
    final Map<String, dynamic> creationParams = _getCreationParams();
    // The fullscreen host with custom controls has no native controls to
    // touch, and claiming every touch on the video would beat the
    // swipe-down-to-close drag; inline views keep claiming them.
    final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers =
        widget.isFullscreenContext && widget.overlayBuilder != null
        ? const <Factory<OneSequenceGestureRecognizer>>{}
        : const <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
          };

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: viewType,
        onPlatformViewCreated: _onPlatformViewCreated,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: gestureRecognizers,
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
            gestureRecognizers: gestureRecognizers,
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

  /// The video clipped with the fullscreen swipe's corner radius (always the
  /// same widgets, so the native view is never rebuilt).
  Widget _rounded(Widget surface) {
    final ValueListenable<double> radius =
        widget.controller.fullscreenVideoCornerRadius ??
        const AlwaysStoppedAnimation<double>(0);
    return ValueListenableBuilder<double>(
      valueListenable: radius,
      child: surface,
      builder: (BuildContext context, double value, Widget? child) =>
          ClipRRect(borderRadius: BorderRadius.circular(value), child: child),
    );
  }

  /// The fullscreen host's video surface sized to the video's aspect-fit
  /// rect instead of the whole screen, so a swipe-down moves just the video
  /// (not a screen-sized black box around it). Always the same widgets,
  /// starting from the box's own aspect until the size is known, so the
  /// native view is never rebuilt.
  Widget _fittedToVideo(Widget surface) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double boxAspect =
            constraints.hasBoundedWidth &&
                constraints.hasBoundedHeight &&
                constraints.maxHeight > 0
            ? constraints.maxWidth / constraints.maxHeight
            : 16 / 9;
        return StreamBuilder<NativeVideoPlayerVideoSize>(
          stream: widget.controller.videoSizeStream,
          initialData: widget.controller.videoSize,
          builder: (context, snapshot) {
            final NativeVideoPlayerVideoSize? size = snapshot.data;
            final double aspect =
                size != null && size.width > 0 && size.height > 0
                ? size.aspectRatio
                : boxAspect;
            return Center(
              child: AspectRatio(aspectRatio: aspect, child: _rounded(surface)),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Track the view's on-screen size for viewport-based quality capping
    // (rotation/resize re-runs this builder; the report deduplicates).
    final Widget videoSurface = LayoutBuilder(
      builder: (context, constraints) {
        _lastConstraints = constraints;
        _devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
        _maybeReportViewportSize();
        // Texture backends render as plain Flutter content (rebuilding the
        // Texture widget is free, so no caching needed).
        if (_useTextureBackend) return _roundedFlutterContent(_textureWidget());
        if (_roundsNatively) return _coverablePlatformView();
        return _roundedFlutterContent(_coverablePlatformView());
      },
    );
    final Widget platformView = widget.isFullscreenContext
        ? _fittedToVideo(videoSurface)
        : videoSurface;

    // Captions grow when the player is fullscreen AND in landscape; inline and
    // fullscreen-portrait keep the base typography. Reading orientation here
    // registers a MediaQuery dependency, so the inline player and the
    // fullscreen route's inner player both rebuild and restyle on rotation.
    final isFullscreenLandscape =
        widget.isFullscreenContext &&
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final effectiveSubtitleStyle = isFullscreenLandscape
        ? widget.subtitleStyle.copyWith(
            fontSize:
                widget.subtitleStyle.fullscreenLandscapeFontSize ??
                widget.subtitleStyle.fontSize,
            fontWeight:
                widget.subtitleStyle.fullscreenLandscapeFontWeight ??
                widget.subtitleStyle.fontWeight,
            lineHeight:
                widget.subtitleStyle.fullscreenLandscapeLineHeight ??
                widget.subtitleStyle.lineHeight,
          )
        : widget.subtitleStyle;

    // Sidecar subtitle layer: renders the active external-VTT/SRT cue lines
    // above the video and below the controls. Suppressed during PiP (the
    // Flutter UI is not part of the iOS PiP window; on Android the native
    // sideloaded track takes over so captions stay visible there).
    // The video is out in a fullscreen flight: its captions and controls
    // leave the (empty) inline slot with it.
    final bool videoOut = _videoOut;
    Widget whileVideoIn(Widget layer) => Visibility(
      visible: !videoOut,
      maintainState: true,
      maintainAnimation: true,
      maintainSize: true,
      child: layer,
    );

    final subtitleLayer = StreamBuilder<bool>(
      stream: widget.controller.isPipEnabledStream,
      initialData: widget.controller.isPipEnabled,
      builder: (context, pipSnapshot) {
        if ((pipSnapshot.data ?? false) || videoOut) {
          return const SizedBox.shrink();
        }
        // Track the video's display size so the overlay can pin captions to
        // the video's content rect instead of the full (possibly
        // letterboxed) widget — e.g. portrait fullscreen with a 16:9 video.
        return StreamBuilder<NativeVideoPlayerVideoSize>(
          stream: widget.controller.videoSizeStream,
          initialData: widget.controller.videoSize,
          builder: (context, sizeSnapshot) {
            final videoSize = sizeSnapshot.data;
            final double? videoAspectRatio =
                videoSize != null && videoSize.width > 0 && videoSize.height > 0
                ? videoSize.aspectRatio
                : null;
            return SubtitleOverlay(
              cueLines: widget.controller.activeSidecarCueLines,
              style: effectiveSubtitleStyle,
              videoAspectRatio: videoAspectRatio,
            );
          },
        );
      },
    );

    Widget content;

    // Without a custom controls overlay, the stack is just the platform view
    // plus the subtitle layer
    // The poster covers the video (not the controls) until it plays
    final Widget? posterLayer = widget.poster == null
        ? null
        : Positioned.fill(
            child: RepaintBoundary(
              key: _posterBoundaryKey,
              child: whileVideoIn(
                PosterLayer(
                  poster: widget.poster!,
                  controller: widget.controller,
                  hasCustomControls: widget.overlayBuilder != null,
                ),
              ),
            ),
          );

    final List<Widget> flutterLayers;
    if (widget.overlayBuilder == null) {
      flutterLayers = [?posterLayer, subtitleLayer];
    } else {
      flutterLayers = [
        ?posterLayer,
        // Subtitles render below the controls overlay
        subtitleLayer,
        // Transparent tap layer when overlay is hidden
        if (!_overlayVisible && !videoOut)
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
        whileVideoIn(
          RepaintBoundary(
            key: _overlayBoundaryKey,
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
        ),
      ];
    }

    if (_cornerRadius <= 0) {
      content = Stack(children: [platformView, ...flutterLayers]);
    } else {
      // The video surface rounds itself; the Flutter layers on top get their
      // own clip, so no rounded clip wraps the platform view.
      content = Stack(
        children: [
          platformView,
          Positioned.fill(
            child: _roundedFlutterContent(Stack(children: flutterLayers)),
          ),
        ],
      );
    }

    return content;
  }
}

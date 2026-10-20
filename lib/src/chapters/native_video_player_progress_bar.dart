import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/native_video_player_controller.dart';
import '../enums/native_video_player_event.dart';
import '../models/native_video_player_chapter.dart';
import '../native_video_player_widget.dart';
import '../subtitles/storyboard_thumbnails.dart';
import 'native_video_player_chapters.dart';
import 'native_video_player_scrub_preview.dart';

/// How a [NativeVideoPlayerProgressBar] looks.
///
/// The defaults are YouTube's: a thin bar where only the chapter under the
/// finger grows. For a bar that thickens as a whole while you touch it and
/// a thumb that only shows then, set [expandedBarHeight], [thumbRadius] 0
/// and [expandedThumbRadius].
@immutable
class NativeVideoPlayerProgressBarStyle {
  const NativeVideoPlayerProgressBarStyle({
    this.height,
    this.barHeight = 3,
    this.expandedBarHeight,
    this.activeSegmentHeight = 6,
    this.chapterGap = 2,
    this.trackInset,
    this.roundedCaps = true,
    this.thumbRadius = 6,
    this.expandedThumbRadius = 8,
    this.playedColor,
    this.bufferedColor,
    this.backgroundColor,
    this.thumbColor,
    this.expandDuration = const Duration(milliseconds: 150),
    this.collapseDelay = Duration.zero,
    this.snapPulse = true,
  });

  /// Height of the bar's box, which is also its touch area; the bar is
  /// centered in it. Null fits the bar: the thickest it gets (the touched
  /// segment, the expanded bar or the grown thumb) plus 4 px above and
  /// below, 24 px with the defaults. Make sure it fits your overlay.
  final double? height;

  /// [height], or the fitted height when it is null.
  double get effectiveHeight =>
      height ??
      [
            barHeight,
            expandedBarHeight ?? 0,
            activeSegmentHeight,
            expandedThumbRadius * 2,
          ].reduce(math.max) +
          8;

  /// Thickness of the bar at rest.
  final double barHeight;

  /// Thickness of the whole bar while touched or hovered; null keeps it at
  /// [barHeight] (only the active segment grows).
  final double? expandedBarHeight;

  /// Thickness of the segment under the finger or mouse.
  final double activeSegmentHeight;

  /// Gap between chapter segments, in logical pixels.
  final double chapterGap;

  /// Room at both ends between the box and the track, so the thumb at the
  /// very start or end sits whole inside the touch area (a finger on it
  /// always starts a drag). A touch in that room counts as the start or
  /// end. Null is the grown thumb's radius.
  final double? trackInset;

  /// [trackInset], or the grown thumb's radius when it is null.
  double get effectiveTrackInset =>
      trackInset ?? math.max(thumbRadius, expandedThumbRadius);

  /// Whether segment ends are rounded.
  final bool roundedCaps;

  /// Thumb radius at rest (0 hides it) and while touched.
  final double thumbRadius;
  final double expandedThumbRadius;

  /// Colors; null takes them from the [SliderTheme] (active, secondary
  /// active and inactive track, thumb), then the color scheme.
  final Color? playedColor;
  final Color? bufferedColor;
  final Color? backgroundColor;
  final Color? thumbColor;

  /// How long growing and shrinking takes.
  final Duration expandDuration;

  /// How long the bar stays expanded after the finger lifts.
  final Duration collapseDelay;

  /// Whether the thumb pulses when the drag snaps to a chapter start.
  final bool snapPulse;

  NativeVideoPlayerProgressBarStyle copyWith({
    double? height,
    double? barHeight,
    double? expandedBarHeight,
    double? activeSegmentHeight,
    double? chapterGap,
    double? trackInset,
    bool? roundedCaps,
    double? thumbRadius,
    double? expandedThumbRadius,
    Color? playedColor,
    Color? bufferedColor,
    Color? backgroundColor,
    Color? thumbColor,
    Duration? expandDuration,
    Duration? collapseDelay,
    bool? snapPulse,
  }) => NativeVideoPlayerProgressBarStyle(
    height: height ?? this.height,
    barHeight: barHeight ?? this.barHeight,
    expandedBarHeight: expandedBarHeight ?? this.expandedBarHeight,
    activeSegmentHeight: activeSegmentHeight ?? this.activeSegmentHeight,
    chapterGap: chapterGap ?? this.chapterGap,
    trackInset: trackInset ?? this.trackInset,
    roundedCaps: roundedCaps ?? this.roundedCaps,
    thumbRadius: thumbRadius ?? this.thumbRadius,
    expandedThumbRadius: expandedThumbRadius ?? this.expandedThumbRadius,
    playedColor: playedColor ?? this.playedColor,
    bufferedColor: bufferedColor ?? this.bufferedColor,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    thumbColor: thumbColor ?? this.thumbColor,
    expandDuration: expandDuration ?? this.expandDuration,
    collapseDelay: collapseDelay ?? this.collapseDelay,
    snapPulse: snapPulse ?? this.snapPulse,
  );
}

/// A seek bar for custom controls, with chapters like YouTube's.
///
/// - The track splits into one segment per chapter, with a small gap at
///   each chapter start. The segment under the finger (or mouse) grows.
/// - While dragging, a preview bubble above the bar shows the storyboard
///   frame (when [storyboard] is given), the chapter title and the time.
/// - A drag that comes within [snapDistance] pixels of a chapter start
///   snaps to it, with a light haptic tick. Releasing seeks there.
///
/// Without chapters it is a plain seek bar with buffered range and scrub
/// preview. It reads position, duration, buffered range, live state and
/// chapters from [controller]; pass [position], [duration],
/// [bufferedPosition], [isLive] or [chapters] to override them (for
/// example while casting, or for an audio player without a controller),
/// and [onSeek] to seek some other way. Live streams show no chapters and
/// no preview.
///
/// ```dart
/// NativeVideoPlayerProgressBar(
///   controller: controller,
///   storyboard: storyboard, // optional scrub thumbnails
///   showPreview: controller.isFullScreen,
/// )
/// ```
class NativeVideoPlayerProgressBar extends StatefulWidget {
  const NativeVideoPlayerProgressBar({
    super.key,
    this.controller,
    this.position,
    this.duration,
    this.bufferedPosition,
    this.isLive,
    this.chapters,
    this.onSeek,
    this.storyboard,
    this.storyboardHeaders,
    this.storyboardImageProvider,
    this.storyboardPrecacheLimit = 4,
    this.snapToChapters = true,
    this.snapDistance = 8,
    this.hapticFeedback = true,
    this.showPreview = true,
    this.showBuffered = true,
    this.holdOverlayWhileScrubbing = true,
    this.style = const NativeVideoPlayerProgressBarStyle(),
    this.previewStyle = const NativeVideoPlayerScrubPreviewStyle(),
    this.previewBuilder,
    this.previewMaxHeight,
    this.onScrubStart,
    this.onScrubUpdate,
    this.onScrubEnd,
    this.onScrubChapterChanged,
    this.onSnap,
    this.onPreviewChanged,
    this.semanticsLabel,
  }) : assert(
         controller != null || duration != null,
         'Pass a controller, or at least a duration (and a position)',
       );

  /// Where the values come from and what seeks; optional when they are
  /// all passed in (see below) together with [onSeek].
  final NativeVideoPlayerController? controller;

  /// Overrides for the controller's values.
  final Duration? position;
  final Duration? duration;
  final Duration? bufferedPosition;
  final bool? isLive;

  /// Chapters to show instead of the controller's
  /// [NativeVideoPlayerController.chapters]. Sorted for you.
  final List<NativeVideoPlayerChapter>? chapters;

  /// Seeks on release (and tap) instead of `controller.seekTo`.
  final FutureOr<void> Function(Duration position)? onSeek;

  /// Scrub-preview frames shown in the bubble.
  final StoryboardThumbnails? storyboard;

  /// HTTP headers for storyboard images (e.g. a `Referer`).
  final Map<String, String>? storyboardHeaders;

  /// Builds the provider for storyboard images, e.g. to go through your
  /// own image cache; null uses
  /// [NativeVideoPlayerScrubPreview.defaultImageProvider].
  final StoryboardImageProviderBuilder? storyboardImageProvider;

  /// How many storyboard images around the playing position (and, while
  /// scrubbing, around the finger) are loaded ahead, so the frame is there
  /// when the bubble shows. Flutter's image cache bounds the memory; 0
  /// turns precaching off. Load failures are ignored.
  final int storyboardPrecacheLimit;

  /// Whether a drag near a chapter start snaps to it.
  final bool snapToChapters;

  /// How close, in logical pixels, a drag must come to a chapter start to
  /// snap to it.
  final double snapDistance;

  /// Whether snapping gives a light haptic tick
  /// ([HapticFeedback.selectionClick]).
  final bool hapticFeedback;

  /// Whether to show the preview bubble while scrubbing; turn it off for a
  /// small inline player, for example. Never shown for live.
  final bool showPreview;

  /// Whether to draw the buffered range (never for live).
  final bool showBuffered;

  /// Whether the player's overlay stays up while the viewer scrubs (see
  /// [NativeVideoPlayerController.holdOverlay]); its hide timer starts
  /// over after the release. Needs [controller].
  final bool holdOverlayWhileScrubbing;

  final NativeVideoPlayerProgressBarStyle style;
  final NativeVideoPlayerScrubPreviewStyle previewStyle;

  /// The tallest the preview may get above the bar. Null measures the room
  /// up to the top of the player (or the screen's safe area), so the bubble
  /// never sticks out of a small inline player. A bubble that does not fit
  /// is scaled down; with too little room it is left out.
  final double? previewMaxHeight;

  /// Builds the bubble instead of [NativeVideoPlayerScrubPreview]. It is
  /// centered over the finger and kept inside the bar's ends; the bar
  /// animates it in and out.
  final Widget Function(BuildContext, NativeVideoPlayerScrubDetails)?
  previewBuilder;

  /// Called when a drag (or tap) starts, with the position under the
  /// finger. Keep the controls visible from here to [onScrubEnd].
  final ValueChanged<Duration>? onScrubStart;

  /// Called as the drag moves, with the (snapped) position.
  final ValueChanged<Duration>? onScrubUpdate;

  /// Called on release, with the position the bar seeks to.
  final ValueChanged<Duration>? onScrubEnd;

  /// Called when the finger (or mouse) moves into another chapter, and
  /// with null when scrubbing ends, e.g. to show the chapter title
  /// somewhere else in the overlay while dragging.
  final ValueChanged<NativeVideoPlayerChapter?>? onScrubChapterChanged;

  /// Called each time the drag snaps to a chapter start.
  final ValueChanged<NativeVideoPlayerChapter>? onSnap;

  /// Called whenever what the preview shows changes (position, chapter,
  /// storyboard frame, snapped), and with null when it goes away. Fires
  /// with [showPreview] off too, so you can draw the preview elsewhere.
  final ValueChanged<NativeVideoPlayerScrubDetails?>? onPreviewChanged;

  /// Accessibility label; the value is the position.
  final String? semanticsLabel;

  @override
  State<NativeVideoPlayerProgressBar> createState() =>
      _NativeVideoPlayerProgressBarState();
}

class _NativeVideoPlayerProgressBarState
    extends State<NativeVideoPlayerProgressBar>
    with TickerProviderStateMixin {
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Bar (and thumb) expansion while touched or hovered.
  late final AnimationController _grow = AnimationController(
    vsync: this,
    duration: widget.style.expandDuration,
  );

  /// Hand-over between the previously and newly active segment.
  late final AnimationController _segmentSwitch = AnimationController(
    vsync: this,
    duration: widget.style.expandDuration,
    value: 1,
  );

  /// Thumb pulse on a snap.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// Preview bubble in/out.
  late final AnimationController _preview = AnimationController(
    vsync: this,
    duration: widget.previewStyle.animationDuration,
  );

  /// The position the drag points at (snapped), while dragging and until
  /// the release's seek lands.
  Duration? _scrub;
  bool _dragging = false;
  Timer? _settleTimer;
  Timer? _collapseTimer;

  /// The chapter start the drag is snapped to, for the haptic tick.
  Duration? _snappedTo;

  /// Releases the controller's overlay hold taken while scrubbing.
  VoidCallback? _releaseOverlay;

  void _holdOverlay() {
    if (!widget.holdOverlayWhileScrubbing) return;
    _releaseOverlay ??= _c?.holdOverlay();
  }

  void _releaseOverlayHold() {
    _releaseOverlay?.call();
    _releaseOverlay = null;
  }

  /// Mouse x while hovering (desktop/web).
  double? _hoverX;

  /// Room above the bar for the preview, measured when scrubbing starts.
  double _roomAbove = double.infinity;

  /// The distance from this bar's top up to the top of the player it sits
  /// in (or the safe area of the screen without one).
  double _measureRoomAbove() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) {
      return double.infinity;
    }
    final top = box.localToGlobal(Offset.zero).dy;
    RenderBox? player;
    context.visitAncestorElements((element) {
      if (element.widget is NativeVideoPlayer) {
        final render = element.findRenderObject();
        if (render is RenderBox && render.hasSize) player = render;
        return false;
      }
      return true;
    });
    final limit = player != null
        ? player!.localToGlobal(Offset.zero).dy
        : MediaQuery.maybePaddingOf(context)?.top ?? 0;
    return math.max(0, top - limit);
  }

  int _activeSegment = -1;
  int _previousSegment = -1;

  /// The last preview shown, kept while it animates out.
  NativeVideoPlayerScrubDetails? _lastPreview;

  /// What the scrub callbacks last reported, to call them on changes only.
  NativeVideoPlayerScrubDetails? _reportedDetails;
  int _reportedChapter = -1;

  /// Storyboard sheets kept loaded around the position, by URL: listening
  /// keeps each decoded and live in the image cache, so a busy app's other
  /// images can't push it out before the viewer scrubs. At most
  /// [NativeVideoPlayerProgressBar.storyboardPrecacheLimit] of them.
  final Map<String, (ImageStream, ImageStreamListener)> _warm = {};
  String? _precacheCenter;

  /// When a storyboard URL last failed to precache; retried after
  /// [_precacheRetryAfter].
  final Map<String, DateTime> _precacheFailedAt = {};
  static const _precacheRetryAfter = Duration(seconds: 10);

  NativeVideoPlayerController? get _c => widget.controller;

  Duration get _duration => widget.duration ?? _c?.duration ?? Duration.zero;
  Duration get _position =>
      widget.position ?? _c?.currentPosition ?? Duration.zero;
  Duration get _buffered =>
      widget.bufferedPosition ?? _c?.bufferedPosition ?? Duration.zero;
  bool get _isLive => widget.isLive ?? _c?.isLive ?? false;

  List<NativeVideoPlayerChapter> get _chapters {
    if (_isLive) return const [];
    final own = widget.chapters;
    return own == null
        ? (_c?.chapters ?? const [])
        : NativeVideoPlayerChapters.normalize(own);
  }

  @override
  void initState() {
    super.initState();
    _listen();
    // Drop the bubble once it has faded out.
    _preview.addStatusListener((status) {
      if (status == AnimationStatus.dismissed &&
          mounted &&
          _lastPreview != null) {
        setState(() => _lastPreview = null);
      }
    });
  }

  @override
  void didUpdateWidget(NativeVideoPlayerProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _releaseOverlayHold();
      _unlisten();
      _listen();
    } else if ((oldWidget.position == null) != (widget.position == null) ||
        (oldWidget.duration == null) != (widget.duration == null) ||
        (oldWidget.bufferedPosition == null) !=
            (widget.bufferedPosition == null) ||
        (oldWidget.chapters == null) != (widget.chapters == null) ||
        (oldWidget.isLive == null) != (widget.isLive == null)) {
      _unlisten();
      _listen();
    }
    _grow.duration = widget.style.expandDuration;
    _segmentSwitch.duration = widget.style.expandDuration;
    _preview.duration = widget.previewStyle.animationDuration;
    if (oldWidget.storyboard != widget.storyboard ||
        oldWidget.storyboardPrecacheLimit != widget.storyboardPrecacheLimit) {
      _releaseWarm();
      _precacheFailedAt.clear();
      _precacheCenter = null;
    }
  }

  /// Leaving the tree (removed, or moved under another parent) mid-drag:
  /// the gesture will never finish here, so drop the scrub and the preview
  /// without seeking, rather than bringing a stale bubble back.
  @override
  void deactivate() {
    _resetScrub();
    super.deactivate();
  }

  void _resetScrub() {
    _dragging = false;
    _scrub = null;
    _snappedTo = null;
    _hoverX = null;
    _settleTimer?.cancel();
    _releaseOverlayHold();
    // No bubble from here on; its animation is reset after this frame
    // (resetting it now would notify transitions mid-build).
    _lastPreview = null;
    _preview.stop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _lastPreview == null) _preview.value = 0;
    });
  }

  @override
  void dispose() {
    _releaseWarm();
    _releaseOverlayHold();
    _unlisten();
    _settleTimer?.cancel();
    _collapseTimer?.cancel();
    _grow.dispose();
    _segmentSwitch.dispose();
    _pulse.dispose();
    _preview.dispose();
    super.dispose();
  }

  void _listen() {
    final c = _c;
    if (c == null) return;
    void refresh(Object? _) {
      if (mounted) setState(() {});
    }

    // Values passed in come with the parent's rebuilds; listening to
    // their streams too would rebuild twice per tick.
    _subscriptions.addAll([
      if (widget.position == null) c.positionStream.listen(refresh),
      if (widget.duration == null) c.durationStream.listen(refresh),
      if (widget.bufferedPosition == null)
        c.bufferedPositionStream.listen(refresh),
      if (widget.chapters == null) c.chaptersStream.listen(refresh),
      if (widget.isLive == null) c.isLiveStream.listen(refresh),
    ]);
  }

  void _unlisten() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    _subscriptions.clear();
  }

  // ─── Gestures ───────────────────────────────────────────────────────

  /// The track's inset from the box's ends, bounded so a narrow bar keeps
  /// a track.
  double _insetFor(double width) =>
      math.min(widget.style.effectiveTrackInset, math.max(0, width / 4));

  /// Where [fraction] of the video lies on a box [width] wide.
  double _xOf(double fraction, double width) {
    final inset = _insetFor(width);
    return inset + fraction * (width - 2 * inset);
  }

  /// Converts a local x to a position, snapped to a nearby chapter start.
  (Duration, Duration?) _positionAt(double x, double width) {
    final duration = _duration;
    final inset = _insetFor(width);
    final track = width - 2 * inset;
    if (track <= 0 || duration <= Duration.zero) return (Duration.zero, null);
    final fraction = ((x - inset) / track).clamp(0.0, 1.0);
    final raw = duration * fraction;
    if (!widget.snapToChapters) return (raw, null);
    final target = NativeVideoPlayerChapters.snapTarget(
      _chapters,
      raw,
      threshold: duration * (widget.snapDistance / track),
    );
    return (target ?? raw, target);
  }

  void _expand() {
    _collapseTimer?.cancel();
    unawaited(_grow.forward());
  }

  void _collapse() {
    if (_dragging || _hoverX != null) return;
    _collapseTimer?.cancel();
    final delay = widget.style.collapseDelay;
    if (delay <= Duration.zero) {
      unawaited(_grow.reverse());
    } else {
      _collapseTimer = Timer(delay, () {
        if (mounted && !_dragging && _hoverX == null) {
          unawaited(_grow.reverse());
        }
      });
    }
  }

  void _start(double x, double width) {
    if (_duration <= Duration.zero) return;
    _roomAbove = _measureRoomAbove();
    final (position, snapped) = _positionAt(x, width);
    _settleTimer?.cancel();
    _snappedTo = snapped;
    setState(() {
      _dragging = true;
      _scrub = position;
      // A finger is down: whatever hover was reported is over.
      _hoverX = null;
    });
    _holdOverlay();
    _expand();
    widget.onScrubStart?.call(position);
  }

  void _update(double x, double width) {
    if (!_dragging) return;
    final (position, snapped) = _positionAt(x, width);
    if (snapped != null && snapped != _snappedTo) {
      if (widget.hapticFeedback) unawaited(HapticFeedback.selectionClick());
      if (widget.style.snapPulse) unawaited(_pulse.forward(from: 0));
      final chapter = NativeVideoPlayerChapters.chapterAt(_chapters, snapped);
      if (chapter != null) widget.onSnap?.call(chapter);
    }
    _snappedTo = snapped;
    if (position == _scrub) return;
    setState(() => _scrub = position);
    widget.onScrubUpdate?.call(position);
  }

  Future<void> _end() async {
    if (!_dragging) return;
    final target = _scrub!;
    setState(() => _dragging = false);
    _snappedTo = null;
    _releaseOverlayHold();
    _collapse();
    widget.onScrubEnd?.call(target);
    final seek = widget.onSeek ?? _c?.seekTo;
    // Keep the thumb at the target until the player reports a position near
    // it (see build), so it doesn't jump back while the seek (or the load
    // of a video that wasn't loaded yet) is still under way.
    _settleWaited = Duration.zero;
    _armSettleTimer();
    try {
      await seek?.call(target);
    } finally {
      // Count from when the seek (or load) returned.
      _settleWaited = Duration.zero;
    }
  }

  /// How long the thumb has waited at the seek target, counted in timer
  /// ticks (so it also runs on a test's fake clock).
  Duration _settleWaited = Duration.zero;
  static const _settleTick = Duration(milliseconds: 250);

  /// How long the thumb waits at a seek target for the player to get
  /// there: a moment once the player plays on, longer while it is still
  /// loading, initializing or buffering.
  static const _settleAfterSeek = Duration(seconds: 2);
  static const _settleWhileLoading = Duration(seconds: 10);

  void _armSettleTimer() {
    _settleTimer?.cancel();
    _settleTimer = Timer.periodic(_settleTick, (timer) {
      if (!mounted || _dragging || _scrub == null) {
        timer.cancel();
        return;
      }
      _settleWaited += _settleTick;
      final waited = _settleWaited;
      final activity = _c?.activityState;
      final busy =
          activity != null &&
          (activity.isLoading ||
              activity.isInitializing ||
              activity.isBuffering ||
              activity.isIdle);
      if (waited >= (busy ? _settleWhileLoading : _settleAfterSeek)) {
        timer.cancel();
        setState(() => _scrub = null);
      }
    });
  }

  void _cancel() {
    if (!_dragging) return;
    setState(() {
      _dragging = false;
      _scrub = null;
    });
    _snappedTo = null;
    _releaseOverlayHold();
    _collapse();
  }

  void _tap(double x, double width) {
    _start(x, width);
    unawaited(_end());
  }

  void _hover(double? x) {
    if (x != null && _hoverX == null) _roomAbove = _measureRoomAbove();
    setState(() => _hoverX = x);
    if (x != null) {
      _expand();
    } else {
      _collapse();
    }
  }

  // ─── Precaching ─────────────────────────────────────────────────────

  /// Keeps the sheets around [position] loaded (see [_warm]) and lets go
  /// of the ones that are no longer near it.
  void _precacheAround(Duration position) {
    final storyboard = widget.storyboard;
    final limit = widget.storyboardPrecacheLimit;
    if (storyboard == null || limit <= 0) return;
    final center = storyboard.thumbnailAt(position)?.url;
    if (center == null || center == _precacheCenter) return;
    _precacheCenter = center;
    final urls = storyboard.imageUrlsAround(position, limit: limit);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final url in _warm.keys.toList()) {
        if (!urls.contains(url)) _releaseSheet(url);
      }
      final build =
          widget.storyboardImageProvider ??
          NativeVideoPlayerScrubPreview.defaultImageProvider;
      final configuration = createLocalImageConfiguration(context);
      final now = DateTime.now();
      for (final url in urls) {
        if (_warm.containsKey(url)) continue;
        final failedAt = _precacheFailedAt[url];
        if (failedAt != null &&
            now.difference(failedAt) < _precacheRetryAfter) {
          continue;
        }
        final provider = build(url, widget.storyboardHeaders);
        final stream = provider.resolve(configuration);
        late final ImageStreamListener listener;
        listener = ImageStreamListener(
          // The stream keeps its own image while we listen.
          (info, synchronousCall) => info.dispose(),
          onError: (error, stackTrace) {
            // Not loaded: forget it and try again after a pause.
            _precacheFailedAt[url] = DateTime.now();
            PaintingBinding.instance.imageCache.evict(provider);
            _precacheCenter = null;
            scheduleMicrotask(() {
              if (identical(_warm[url]?.$2, listener)) _releaseSheet(url);
            });
          },
        );
        _warm[url] = (stream, listener);
        stream.addListener(listener);
      }
    });
  }

  void _releaseSheet(String url) {
    final entry = _warm.remove(url);
    entry?.$1.removeListener(entry.$2);
  }

  void _releaseWarm() {
    for (final url in _warm.keys.toList()) {
      _releaseSheet(url);
    }
  }

  /// Calls the preview/chapter callbacks after this frame when what they
  /// report changed.
  void _report(NativeVideoPlayerScrubDetails? details) {
    final changed =
        details?.position != _reportedDetails?.position ||
        details?.chapterIndex != _reportedDetails?.chapterIndex ||
        details?.thumbnail != _reportedDetails?.thumbnail ||
        details?.snapped != _reportedDetails?.snapped ||
        (details == null) != (_reportedDetails == null);
    if (!changed) return;
    _reportedDetails = details;
    final chapterIndex = details?.chapterIndex ?? -1;
    final chapterChanged = chapterIndex != _reportedChapter;
    _reportedChapter = chapterIndex;
    if (widget.onPreviewChanged == null &&
        (widget.onScrubChapterChanged == null || !chapterChanged)) {
      return;
    }
    // Callbacks usually call setState on a parent: not during this build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onPreviewChanged?.call(details);
      if (chapterChanged) widget.onScrubChapterChanged?.call(details?.chapter);
    });
  }

  // ─── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final sliderTheme = SliderTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    final played =
        style.playedColor ?? sliderTheme.activeTrackColor ?? scheme.primary;
    final buffered =
        style.bufferedColor ??
        sliderTheme.secondaryActiveTrackColor ??
        Colors.white.withValues(alpha: 0.5);
    final background =
        style.backgroundColor ??
        sliderTheme.inactiveTrackColor ??
        Colors.white.withValues(alpha: 0.24);
    final thumb = style.thumbColor ?? sliderTheme.thumbColor ?? played;

    // The seek landed: follow the player again.
    if (!_dragging &&
        _scrub != null &&
        (_position - _scrub!).abs() < const Duration(milliseconds: 1200)) {
      _scrub = null;
      _settleTimer?.cancel();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final duration = _duration;
        final chapters = _chapters;
        final segments = NativeVideoPlayerChapters.segments(chapters, duration);
        double fractionOf(Duration d) => duration <= Duration.zero
            ? 0
            : (d.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);

        final position = _scrub ?? _position;
        final hoverPosition = _hoverX == null
            ? null
            : _positionAt(_hoverX!, width).$1;
        final focus = _dragging ? _scrub : hoverPosition;

        // The segment that grows: under the finger, else under the mouse.
        if (focus != null) {
          final active = segments.lastIndexWhere((s) => s.start <= focus);
          if (active != _activeSegment) {
            _previousSegment = _activeSegment;
            _activeSegment = active;
            unawaited(_segmentSwitch.forward(from: 0));
          }
        }

        if (!_isLive) {
          _precacheAround(focus ?? _position);
        }

        // Preview bubble.
        NativeVideoPlayerScrubDetails? details;
        if (focus != null && !_isLive && duration > Duration.zero) {
          final index = NativeVideoPlayerChapters.indexAt(chapters, focus);
          details = NativeVideoPlayerScrubDetails(
            position: focus,
            duration: duration,
            chapter: index == -1 ? null : chapters[index],
            chapterIndex: index,
            thumbnail: widget.storyboard?.thumbnailAt(focus),
            snapped: _dragging && _snappedTo != null,
          );
        }
        _report(details);
        if (details != null &&
            (!widget.showPreview ||
                (widget.previewBuilder == null &&
                    !NativeVideoPlayerScrubPreview.hasContent(
                      details,
                      widget.previewStyle,
                    )))) {
          details = null;
        }

        if (details != null) {
          _lastPreview = details;
          if (!_preview.isForwardOrCompleted) unawaited(_preview.forward());
        } else if (_preview.value == 0) {
          // Nothing to fade out (reversing now would notify mid-build).
          _preview.stop();
          _lastPreview = null;
        } else if (_preview.status != AnimationStatus.reverse) {
          unawaited(_preview.reverse());
        }

        final bar = AnimatedBuilder(
          animation: Listenable.merge([_grow, _segmentSwitch, _pulse]),
          builder: (context, _) {
            final grow = Curves.easeOut.transform(_grow.value);
            final pulse = math.sin(_pulse.value * math.pi) * 0.3;
            return CustomPaint(
              size: Size(width, style.effectiveHeight),
              painter: _ChapterBarPainter(
                segments: segments,
                playedFraction: fractionOf(position),
                bufferedFraction: widget.showBuffered && !_isLive
                    ? fractionOf(_buffered)
                    : 0,
                activeSegment: _activeSegment,
                previousSegment: _previousSegment,
                switchProgress: Curves.easeOut.transform(_segmentSwitch.value),
                grow: grow,
                barHeight: style.barHeight,
                expandedBarHeight: style.expandedBarHeight ?? style.barHeight,
                activeSegmentHeight: style.activeSegmentHeight,
                gap: style.chapterGap,
                inset: _insetFor(width),
                roundedCaps: style.roundedCaps,
                thumbRadius:
                    lerpDouble(
                      style.thumbRadius,
                      style.expandedThumbRadius,
                      grow,
                    )! *
                    (1 + pulse),
                playedColor: played,
                bufferedColor: buffered,
                backgroundColor: background,
                thumbColor: thumb,
              ),
            );
          },
        );

        final format =
            widget.previewStyle.timeFormatter ??
            NativeVideoPlayerScrubPreview.formatDuration;
        const step = Duration(seconds: 10);
        Future<void> seekBy(Duration delta) async {
          final target = _position + delta;
          final clamped = target < Duration.zero
              ? Duration.zero
              : (target > duration ? duration : target);
          await (widget.onSeek ?? _c?.seekTo)?.call(clamped);
        }

        return Semantics(
          slider: true,
          label: widget.semanticsLabel,
          value: format(position),
          increasedValue: format(position + step),
          decreasedValue: format(
            position > step ? position - step : Duration.zero,
          ),
          onIncrease: () => unawaited(seekBy(step)),
          onDecrease: () => unawaited(seekBy(-step)),
          child: MouseRegion(
            // Only a real mouse hovers: some Android touch screens also
            // send a hover (kind unknown) at each touch-down and never
            // an exit, which left a preview pinned where a drag began.
            onHover: (e) {
              if (e.kind == PointerDeviceKind.mouse) {
                _hover(e.localPosition.dx);
              }
            },
            onExit: (_) => _hover(null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragDown: (d) => _start(d.localPosition.dx, width),
              // The move that wins the drag arrives as its start.
              onHorizontalDragStart: (d) => _update(d.localPosition.dx, width),
              onHorizontalDragUpdate: (d) => _update(d.localPosition.dx, width),
              onHorizontalDragEnd: (_) => _end(),
              onHorizontalDragCancel: _cancel,
              onTapUp: (d) => _tap(d.localPosition.dx, width),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  SizedBox(
                    width: width,
                    height: style.effectiveHeight,
                    child: bar,
                  ),
                  ..._previewLayer(context, width, fractionOf),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _previewLayer(
    BuildContext context,
    double width,
    double Function(Duration) fractionOf,
  ) {
    final details = _lastPreview;
    if (details == null) return const [];
    final style = widget.style;
    final previewStyle = widget.previewStyle;
    final x = _xOf(fractionOf(details.position), width);
    final animation = CurvedAnimation(
      parent: _preview,
      curve: previewStyle.animationCurve,
    );
    // Above the thickest the bar (or its thumb) gets.
    final tallest = [
      style.activeSegmentHeight,
      style.expandedBarHeight ?? 0,
      style.expandedThumbRadius * 2,
    ].reduce(math.max);
    final barTop = style.effectiveHeight / 2 + tallest / 2;
    final arrow = previewStyle.backgroundColor == null
        ? null
        : previewStyle.arrowSize;
    final bubbleBottom = barTop + previewStyle.gapToBar + (arrow?.height ?? 0);

    // The slot runs from above the arrow up to the top of the player (or
    // previewMaxHeight): the bubble is scaled down to fit it, and left out
    // when there is hardly any room.
    final room = math.min(
      widget.previewMaxHeight ?? double.infinity,
      _roomAbove + style.effectiveHeight - bubbleBottom,
    );
    if (room < _minPreviewRoom) return const [];
    final slotHeight = room.isFinite ? room : 600.0;

    final bubble =
        widget.previewBuilder?.call(context, details) ??
        NativeVideoPlayerScrubPreview(
          details: details,
          style: previewStyle,
          imageHeaders: widget.storyboardHeaders,
          imageProviderBuilder: widget.storyboardImageProvider,
        );

    Widget appear(Widget child, Alignment alignment) => IgnorePointer(
      child: FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.85, end: 1.0).animate(animation),
          alignment: alignment,
          child: child,
        ),
      ),
    );

    return [
      Positioned(
        left: 0,
        right: 0,
        bottom: bubbleBottom,
        // The bubble sits at the bottom of its slot, scaled down when it
        // is wider than the bar or taller than the slot.
        height: slotHeight,
        child: appear(
          CustomSingleChildLayout(
            delegate: _BubbleLayout(x),
            child: FittedBox(fit: BoxFit.scaleDown, child: bubble),
          ),
          Alignment((x / math.max(width, 1) * 2 - 1).clamp(-1.0, 1.0), 1),
        ),
      ),
      if (arrow != null)
        Positioned(
          left:
              x.clamp(
                arrow.width / 2,
                math.max(arrow.width / 2, width - arrow.width / 2),
              ) -
              arrow.width / 2,
          bottom: barTop + previewStyle.gapToBar,
          child: appear(
            CustomPaint(
              size: arrow,
              painter: _ArrowPainter(previewStyle.backgroundColor!),
            ),
            Alignment.bottomCenter,
          ),
        ),
    ];
  }
}

/// Less room than this above the bar and the preview is left out.
const double _minPreviewRoom = 28;

/// Centers the bubble on the finger, kept inside the bar's ends, at the
/// bottom of its slot.
class _BubbleLayout extends SingleChildLayoutDelegate {
  _BubbleLayout(this.x);

  final double x;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxLeft = size.width - childSize.width;
    final left = maxLeft <= 0
        ? maxLeft / 2
        : (x - childSize.width / 2).clamp(0.0, maxLeft);
    return Offset(left, size.height - childSize.height);
  }

  @override
  bool shouldRelayout(_BubbleLayout oldDelegate) => oldDelegate.x != x;
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color;
}

class _ChapterBarPainter extends CustomPainter {
  _ChapterBarPainter({
    required this.segments,
    required this.playedFraction,
    required this.bufferedFraction,
    required this.activeSegment,
    required this.previousSegment,
    required this.switchProgress,
    required this.grow,
    required this.barHeight,
    required this.expandedBarHeight,
    required this.activeSegmentHeight,
    required this.gap,
    required this.inset,
    required this.roundedCaps,
    required this.thumbRadius,
    required this.playedColor,
    required this.bufferedColor,
    required this.backgroundColor,
    required this.thumbColor,
  });

  final List<NativeVideoPlayerChapterSegment> segments;
  final double playedFraction;
  final double bufferedFraction;
  final int activeSegment;
  final int previousSegment;
  final double switchProgress;
  final double grow;
  final double barHeight;
  final double expandedBarHeight;
  final double activeSegmentHeight;
  final double gap;
  final double inset;
  final bool roundedCaps;
  final double thumbRadius;
  final Color playedColor;
  final Color bufferedColor;
  final Color backgroundColor;
  final Color thumbColor;

  double _heightOf(int i) {
    final base = lerpDouble(barHeight, expandedBarHeight, grow)!;
    final active = math.max(
      base,
      lerpDouble(barHeight, activeSegmentHeight, grow)!,
    );
    if (i == activeSegment) return lerpDouble(base, active, switchProgress)!;
    if (i == previousSegment) return lerpDouble(active, base, switchProgress)!;
    return base;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    // The track runs between the insets; x = inset + fraction * track.
    final track = size.width - 2 * inset;
    double xOf(double fraction) => inset + fraction * track;
    final playedX = xOf(playedFraction);
    final bufferedX = xOf(bufferedFraction);
    // An unknown duration still draws an empty track.
    final drawn = segments.isEmpty
        ? const [
            NativeVideoPlayerChapterSegment(
              index: -1,
              chapter: null,
              start: Duration.zero,
              end: Duration.zero,
              startFraction: 0,
              endFraction: 1,
            ),
          ]
        : segments;

    for (var i = 0; i < drawn.length; i++) {
      final segment = drawn[i];
      final left = xOf(segment.startFraction) + (i > 0 ? gap / 2 : 0);
      final right =
          xOf(segment.endFraction) - (i < drawn.length - 1 ? gap / 2 : 0);
      if (right <= left) continue;
      final height = _heightOf(i);
      final rect = RRect.fromLTRBR(
        left,
        centerY - height / 2,
        right,
        centerY + height / 2,
        roundedCaps ? Radius.circular(height / 2) : Radius.zero,
      );
      canvas
        ..save()
        ..clipRRect(rect)
        ..drawRect(rect.outerRect, Paint()..color = backgroundColor);
      if (bufferedX > left) {
        canvas.drawRect(
          Rect.fromLTRB(left, rect.top, bufferedX, rect.bottom),
          Paint()..color = bufferedColor,
        );
      }
      if (playedX > left) {
        canvas.drawRect(
          Rect.fromLTRB(left, rect.top, playedX, rect.bottom),
          Paint()..color = playedColor,
        );
      }
      canvas.restore();
    }

    if (thumbRadius > 0) {
      canvas.drawCircle(
        Offset(playedX, centerY),
        thumbRadius,
        Paint()..color = thumbColor,
      );
    }
  }

  @override
  bool shouldRepaint(_ChapterBarPainter old) =>
      !listEquals(old.segments, segments) ||
      old.playedFraction != playedFraction ||
      old.bufferedFraction != bufferedFraction ||
      old.activeSegment != activeSegment ||
      old.previousSegment != previousSegment ||
      old.switchProgress != switchProgress ||
      old.grow != grow ||
      old.barHeight != barHeight ||
      old.expandedBarHeight != expandedBarHeight ||
      old.activeSegmentHeight != activeSegmentHeight ||
      old.gap != gap ||
      old.inset != inset ||
      old.roundedCaps != roundedCaps ||
      old.thumbRadius != thumbRadius ||
      old.playedColor != playedColor ||
      old.bufferedColor != bufferedColor ||
      old.backgroundColor != backgroundColor ||
      old.thumbColor != thumbColor;
}

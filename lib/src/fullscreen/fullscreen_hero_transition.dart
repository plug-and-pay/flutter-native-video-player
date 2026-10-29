import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// Where the video is in a fullscreen flight, from the inline player's
/// point of view.
enum FullscreenFlightPhase {
  /// No fullscreen flight: the inline player shows the video.
  none,

  /// Flying out or in fullscreen (also while a swipe drags it): the inline
  /// slot is empty.
  out,

  /// Landing (the last bit of the way back): the inline slot shows the
  /// video (or its poster) again, right under the landing flight.
  returning,
}

/// What the Dart fullscreen route needs to grow the video out of the inline
/// player and shrink it back into it: where the inline player is, and a still
/// frame to fly between the two.
///
/// A frame flies instead of the video itself: a platform view cannot be
/// resized smoothly every frame, and the fullscreen route's own view needs
/// a moment to show its first frame. The live fullscreen video takes over
/// once the route is fully open.
class FullscreenHeroFlight {
  FullscreenHeroFlight({
    required this.poster,
    required this.startRect,
    required this.inlineRect,
    required this.capturePoster,
    this.videoAspectRatio,
    this.currentAspectRatio,
    this.inlineBorderRadius = BorderRadius.zero,
    this.createLiveTexture,
    this.disposeLiveTexture,
    this.liveTextureId,
    this.onReturn,
    this.onLanding,
    this.onDone,
    this.sharedTexture,
  });

  /// Called once the flight is over (the fullscreen route is gone, or
  /// opened and closed without flying).
  final VoidCallback? onDone;

  /// Called when the way back has nearly landed (the flight covers the
  /// inline slot from then on, so the slot can show the video again without
  /// it showing twice).
  final VoidCallback? onLanding;

  /// The player's active texture (Android texture mode): flown live as is,
  /// with no texture of its own for the flight.
  final ValueListenable<int?>? sharedTexture;

  /// Called when the way back starts.
  final VoidCallback? onReturn;

  /// The frame that flies (JPEG). Refreshed by [refreshPoster] before the
  /// way back, since the video kept playing in fullscreen. Painted under
  /// [liveTextureId], so it only shows until the live video has a frame.
  Uint8List? poster;

  /// A live engine texture of the player that flies on top of [poster], so
  /// the video keeps playing during the flight. One per leg: created right
  /// before it ([prepareReturn] for the way back) and released when it ends,
  /// so nothing copies frames while fullscreen is open. Null flies the frame.
  int? liveTextureId;

  final Future<int?> Function()? createLiveTexture;
  final void Function(int textureId)? disposeLiveTexture;

  /// Releases the current leg's live texture.
  void releaseLiveTexture() {
    final int? textureId = liveTextureId;
    liveTextureId = null;
    if (textureId != null) disposeLiveTexture?.call(textureId);
  }

  /// The inline player's global rect when fullscreen opened.
  final Rect startRect;

  /// The inline player's global rect now, or null when it is gone. Read when
  /// fullscreen closes: a rotation in fullscreen moves the inline player.
  final Rect? Function() inlineRect;

  /// Captures the frame the player shows now.
  final Future<Uint8List?> Function() capturePoster;

  /// Width / height of the video. Both players letterbox it (aspect fit),
  /// so the frame flies between the video's own rects inside the inline box
  /// and inside the screen, never a black box around it. Null flies the
  /// boxes themselves. Updated from [currentAspectRatio] for the way back.
  double? videoAspectRatio;

  /// The video's aspect ratio now, or null while there is no video frame
  /// (a video that only loaded in fullscreen flies back as a video).
  final double? Function()? currentAspectRatio;

  /// The corners of the inline player's clip, which the frame takes on as it
  /// lands inline and sheds (square) in fullscreen.
  final BorderRadius inlineBorderRadius;

  /// The video's aspect-fit rect inside [box].
  Rect videoRectIn(Rect box) {
    final double? aspectRatio = videoAspectRatio;
    if (aspectRatio == null || aspectRatio <= 0 || box.isEmpty) return box;
    final Size fitted = applyBoxFit(
      BoxFit.contain,
      Size(aspectRatio, 1),
      box.size,
    ).destination;
    return Alignment.center.inscribe(fitted, box);
  }

  /// Where the page's content was when a swipe dismissed it, so the way back
  /// starts there instead of jumping to full screen first.
  Rect? dismissedFromRect;

  /// The backdrop's opacity when the swipe dismissed it.
  double dismissedBackdropOpacity = 1;

  /// The video's corner radius when the swipe dismissed it (the drag rounds
  /// it), so the way back starts with those corners.
  double dismissedCornerRadius = 0;

  /// Readies the way back: the frame showing now and a live texture.
  Future<void> prepareReturn(BuildContext context) async {
    final Future<int?>? texture = createLiveTexture?.call().timeout(
      const Duration(milliseconds: 250),
      onTimeout: () => null,
    );
    final Uint8List? before = poster;
    await refreshPoster(context);
    final int? textureId = await texture;
    // A new frame (the video loaded in fullscreen) flies at the video's
    // shape; the snapshot it replaces had the player's.
    if (!identical(before, poster)) {
      if (currentAspectRatio?.call() case final double aspectRatio) {
        videoAspectRatio = aspectRatio;
      }
    }
    releaseLiveTexture();
    liveTextureId = textureId;
  }

  /// Replaces [poster] with the frame showing now, decoded and ready to
  /// paint. Gives up after a short wait: closing must not stall.
  Future<void> refreshPoster(BuildContext context) async {
    final Uint8List? frame = await capturePoster().timeout(
      const Duration(milliseconds: 250),
      onTimeout: () => null,
    );
    if (frame == null || !context.mounted) return;
    await precacheImage(MemoryImage(frame), context);
    poster = frame;
  }
}

/// The fullscreen route's transition with a [FullscreenHeroFlight]: the
/// frame grows from the inline player's rect to the full screen while the
/// backdrop darkens, then the live page is shown; closing runs it backwards
/// into wherever the inline player is then.
class FullscreenHeroTransition extends StatefulWidget {
  const FullscreenHeroTransition({
    required this.animation,
    required this.flight,
    required this.child,
    super.key,
  });

  final Animation<double> animation;
  final FullscreenHeroFlight flight;

  /// The fullscreen page. Kept mounted throughout (so its platform view is
  /// created during the flight) but only painted once the route is open.
  final Widget child;

  @override
  State<FullscreenHeroTransition> createState() =>
      _FullscreenHeroTransitionState();
}

class _FullscreenHeroTransitionState extends State<FullscreenHeroTransition> {
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: widget.animation,
    curve: Curves.fastOutSlowIn,
    reverseCurve: Curves.fastOutSlowIn.flipped,
  );

  /// Where the way back lands, read once when it starts.
  Rect? _returnRect;

  bool _landing = false;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_handleStatus);
    widget.animation.addListener(_handleTick);
  }

  void _handleTick() {
    // By time, not distance: the last few frames, when the flight already
    // covers the inline slot.
    if (_landing ||
        widget.animation.status != AnimationStatus.reverse ||
        widget.animation.value > 0.15) {
      return;
    }
    _landing = true;
    widget.flight.onLanding?.call();
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_handleStatus);
    widget.animation.removeListener(_handleTick);
    _finish();
    widget.flight.releaseLiveTexture();
    _curve.dispose();
    super.dispose();
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) {
      _returnRect = widget.flight.inlineRect() ?? widget.flight.startRect;
      widget.flight.onReturn?.call();
    }
    // A leg ended: the live fullscreen view (or the inline one) shows now.
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      widget.flight.releaseLiveTexture();
    }
    if (status == AnimationStatus.dismissed) {
      if (!_landing) {
        _landing = true;
        widget.flight.onLanding?.call();
      }
      _finish();
    }
  }

  bool _done = false;

  void _finish() {
    if (_done) return;
    _done = true;
    widget.flight.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final FullscreenHeroFlight flight = widget.flight;
        final AnimationStatus status = widget.animation.status;
        final bool open = status == AnimationStatus.completed;
        final bool closing =
            status == AnimationStatus.reverse ||
            status == AnimationStatus.dismissed;
        final Rect fullRect = Offset.zero & MediaQuery.sizeOf(context);
        // The way back follows the inline player every frame: the page
        // below relayouts while it runs (system bars coming back), and a
        // target read once would land off and snap.
        final Rect from = flight.videoRectIn(
          closing
              ? flight.inlineRect() ?? _returnRect ?? flight.startRect
              : flight.startRect,
        );
        final Rect to = flight.videoRectIn(
          closing ? flight.dismissedFromRect ?? fullRect : fullRect,
        );
        final double t = _curve.value;
        // Clear while open: the page's own background is there then, and it
        // fades during a swipe-down to show the page underneath.
        final double backdropOpacity = open
            ? 0
            : t * (closing ? flight.dismissedBackdropOpacity : 1);
        final BorderRadius radius = BorderRadius.lerp(
          flight.inlineBorderRadius,
          closing
              ? BorderRadius.circular(flight.dismissedCornerRadius)
              : BorderRadius.zero,
          t,
        )!;

        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: backdropOpacity),
                ),
              ),
            ),
            Positioned.fill(
              child: Visibility(
                visible: open,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: child!,
              ),
            ),
            if (!open)
              Positioned.fromRect(
                rect: Rect.lerp(from, to, t)!,
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: radius,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (flight.poster case final Uint8List poster)
                          Image.memory(
                            poster,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          )
                        else
                          const ColoredBox(color: Colors.black),
                        // Paints nothing until its first frame, so the
                        // still frame shows until then.
                        if (flight.liveTextureId ?? flight.sharedTexture?.value
                            case final int textureId)
                          Texture(textureId: textureId),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

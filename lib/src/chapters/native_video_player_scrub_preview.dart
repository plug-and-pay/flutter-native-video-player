import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/native_video_player_chapter.dart';
import '../subtitles/storyboard_thumbnails.dart';

/// Turns a storyboard image URL into an [ImageProvider]. Swap it to load
/// sprites through your own cache (e.g. `CachedNetworkImageProvider`) or
/// with signed URLs.
typedef StoryboardImageProviderBuilder =
    ImageProvider Function(String url, Map<String, String>? headers);

/// What the seek bar is pointing at while the viewer drags (or hovers),
/// handed to a custom [NativeVideoPlayerProgressBar.previewBuilder].
@immutable
class NativeVideoPlayerScrubDetails {
  const NativeVideoPlayerScrubDetails({
    required this.position,
    required this.duration,
    this.chapter,
    this.chapterIndex = -1,
    this.thumbnail,
    this.snapped = false,
  });

  /// The position under the finger, after snapping.
  final Duration position;

  /// The video's duration.
  final Duration duration;

  /// The chapter at [position], if the video has chapters.
  final NativeVideoPlayerChapter? chapter;

  /// Index of [chapter] in the chapter list, -1 without one.
  final int chapterIndex;

  /// The storyboard frame for [position], if a storyboard was given.
  final StoryboardThumbnail? thumbnail;

  /// Whether [position] snapped to the start of [chapter].
  final bool snapped;
}

/// How the scrub preview bubble looks. The defaults: a frame with rounded
/// corners and the chapter title and time below it, straight on the video.
/// Add a [thumbnailBorder] for YouTube's white frame, or give it a
/// [backgroundColor], [padding] and [arrowSize] for a tooltip-style bubble.
@immutable
class NativeVideoPlayerScrubPreviewStyle {
  const NativeVideoPlayerScrubPreviewStyle({
    this.showThumbnail = true,
    this.showChapterTitle = true,
    this.showTime = true,
    this.thumbnailWidth = 160,
    this.thumbnailMaxHeight,
    this.thumbnailAspectRatio = 16 / 9,
    this.thumbnailBorder,
    this.thumbnailBorderRadius = const BorderRadius.all(Radius.circular(10)),
    this.titleStyle,
    this.timeStyle,
    this.maxTitleLines = 2,
    this.spacing = 4,
    this.backgroundColor,
    this.padding = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
    this.shadows = const [],
    this.arrowSize,
    this.gapToBar = 8,
    this.timeFormatter,
    this.animationDuration = const Duration(milliseconds: 180),
    this.animationCurve = Curves.fastOutSlowIn,
  });

  /// Which parts to show. A preview with nothing to show stays hidden.
  final bool showThumbnail;
  final bool showChapterTitle;
  final bool showTime;

  /// Width of the frame (and of the title, which wraps within it). The
  /// frame keeps its own aspect ratio: landscape frames are this wide,
  /// portrait ones are [thumbnailMaxHeight] tall instead.
  final double thumbnailWidth;

  /// The tallest the frame gets; null is [thumbnailWidth], so the long side
  /// never exceeds it (a 9:16 frame shows at 90 × 160 with the defaults).
  final double? thumbnailMaxHeight;

  /// Aspect ratio used for a frame before its sheet is loaded and measured
  /// (only for sizing; nothing is drawn until the image is there).
  final double thumbnailAspectRatio;

  /// Drawn over the edge of the frame, e.g. `Border.all(color: Colors.white,
  /// width: 2)` for YouTube's white frame. None by default.
  final BoxBorder? thumbnailBorder;

  /// Rounds the frame's corners, with or without a [thumbnailBorder];
  /// [BorderRadius.zero] for square ones.
  final BorderRadius thumbnailBorderRadius;

  /// Text styles; null is white with a soft shadow (title semi-bold, time
  /// bold with tabular figures).
  final TextStyle? titleStyle;
  final TextStyle? timeStyle;
  final int maxTitleLines;

  /// Space between frame, title and time.
  final double spacing;

  /// Bubble fill behind everything; null draws no bubble.
  final Color? backgroundColor;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final List<BoxShadow> shadows;

  /// Size of the arrow under the bubble pointing at the finger (width,
  /// height), in [backgroundColor]. Null draws none.
  final Size? arrowSize;

  /// Distance between the bubble (or its arrow) and the bar.
  final double gapToBar;

  /// Formats the time; null is `m:ss`, or `h:mm:ss` from an hour on.
  final String Function(Duration)? timeFormatter;

  /// The bubble scales and fades in and out with these, and the chapter
  /// title cross-fades when the finger moves to another chapter.
  final Duration animationDuration;
  final Curve animationCurve;

  NativeVideoPlayerScrubPreviewStyle copyWith({
    bool? showThumbnail,
    bool? showChapterTitle,
    bool? showTime,
    double? thumbnailWidth,
    double? thumbnailMaxHeight,
    double? thumbnailAspectRatio,
    BoxBorder? thumbnailBorder,
    BorderRadius? thumbnailBorderRadius,
    TextStyle? titleStyle,
    TextStyle? timeStyle,
    int? maxTitleLines,
    double? spacing,
    Color? backgroundColor,
    EdgeInsetsGeometry? padding,
    BorderRadius? borderRadius,
    List<BoxShadow>? shadows,
    Size? arrowSize,
    double? gapToBar,
    String Function(Duration)? timeFormatter,
    Duration? animationDuration,
    Curve? animationCurve,
  }) => NativeVideoPlayerScrubPreviewStyle(
    showThumbnail: showThumbnail ?? this.showThumbnail,
    showChapterTitle: showChapterTitle ?? this.showChapterTitle,
    showTime: showTime ?? this.showTime,
    thumbnailWidth: thumbnailWidth ?? this.thumbnailWidth,
    thumbnailMaxHeight: thumbnailMaxHeight ?? this.thumbnailMaxHeight,
    thumbnailAspectRatio: thumbnailAspectRatio ?? this.thumbnailAspectRatio,
    thumbnailBorder: thumbnailBorder ?? this.thumbnailBorder,
    thumbnailBorderRadius: thumbnailBorderRadius ?? this.thumbnailBorderRadius,
    titleStyle: titleStyle ?? this.titleStyle,
    timeStyle: timeStyle ?? this.timeStyle,
    maxTitleLines: maxTitleLines ?? this.maxTitleLines,
    spacing: spacing ?? this.spacing,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    padding: padding ?? this.padding,
    borderRadius: borderRadius ?? this.borderRadius,
    shadows: shadows ?? this.shadows,
    arrowSize: arrowSize ?? this.arrowSize,
    gapToBar: gapToBar ?? this.gapToBar,
    timeFormatter: timeFormatter ?? this.timeFormatter,
    animationDuration: animationDuration ?? this.animationDuration,
    animationCurve: animationCurve ?? this.animationCurve,
  );
}

/// The bubble above a seek bar while scrubbing: a storyboard frame (or the
/// chapter's own thumbnail), the chapter title and the time.
///
/// [NativeVideoPlayerProgressBar] shows it by default; use it directly in
/// custom controls that draw their own bar. An image that fails to load
/// (bad URL, 403, offline) is left out; it never throws.
class NativeVideoPlayerScrubPreview extends StatelessWidget {
  const NativeVideoPlayerScrubPreview({
    super.key,
    required this.details,
    this.style = const NativeVideoPlayerScrubPreviewStyle(),
    this.imageHeaders,
    this.imageProviderBuilder,
  });

  final NativeVideoPlayerScrubDetails details;
  final NativeVideoPlayerScrubPreviewStyle style;

  /// HTTP headers for storyboard images (e.g. a `Referer` for a CDN with
  /// hotlink protection).
  final Map<String, String>? imageHeaders;

  /// Builds the provider for storyboard images; null uses
  /// [defaultImageProvider].
  final StoryboardImageProviderBuilder? imageProviderBuilder;

  /// `NetworkImage` (with [headers]) for http(s) URLs, `AssetImage`
  /// otherwise.
  static ImageProvider defaultImageProvider(
    String url,
    Map<String, String>? headers,
  ) => url.startsWith('http://') || url.startsWith('https://')
      ? NetworkImage(url, headers: headers)
      : AssetImage(url);

  /// `m:ss`, or `h:mm:ss` from an hour on.
  static String formatDuration(Duration d) {
    if (d.isNegative) return '-${formatDuration(-d)}';
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
        : '$minutes:$seconds';
  }

  /// Whether [style] leaves anything to show for [details].
  static bool hasContent(
    NativeVideoPlayerScrubDetails details,
    NativeVideoPlayerScrubPreviewStyle style,
  ) =>
      style.showTime ||
      (style.showChapterTitle && details.chapter != null) ||
      (style.showThumbnail &&
          (details.thumbnail != null || details.chapter?.thumbnail != null));

  @override
  Widget build(BuildContext context) {
    const shadow = [Shadow(blurRadius: 6)];
    final titleStyle =
        style.titleStyle ??
        const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          shadows: shadow,
        );
    final timeStyle =
        style.timeStyle ??
        const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          fontFeatures: [FontFeature.tabularFigures()],
          shadows: shadow,
        );
    final duration = style.animationDuration;
    final chapter = style.showChapterTitle ? details.chapter : null;

    final children = <Widget>[
      if (style.showThumbnail) ?_frame(),
      if (chapter != null)
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: style.thumbnailWidth),
          child: AnimatedSwitcher(
            duration: duration,
            switchInCurve: style.animationCurve,
            switchOutCurve: style.animationCurve,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.bottomCenter,
              children: [...previous, ?current],
            ),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.35),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: Text(
              chapter.title,
              key: ValueKey((details.chapterIndex, chapter.title)),
              maxLines: style.maxTitleLines,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: titleStyle,
            ),
          ),
        ),
      if (style.showTime)
        Text(
          (style.timeFormatter ?? formatDuration)(details.position),
          style: timeStyle,
        ),
    ];

    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      spacing: style.spacing,
      children: children,
    );
    content = AnimatedSize(
      duration: duration,
      curve: style.animationCurve,
      alignment: Alignment.bottomCenter,
      child: content,
    );
    if (style.backgroundColor != null || style.padding != EdgeInsets.zero) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          color: style.backgroundColor,
          borderRadius: style.borderRadius,
          boxShadow: style.shadows,
        ),
        child: Padding(padding: style.padding, child: content),
      );
    }
    return content;
  }

  Widget? _frame() {
    final thumbnail = details.thumbnail;
    if (thumbnail != null) {
      final provider = (imageProviderBuilder ?? defaultImageProvider)(
        thumbnail.url,
        imageHeaders,
      );
      return _PreviewFrame(
        key: const ValueKey('storyboard'),
        image: provider,
        thumbnail: thumbnail,
        style: style,
      );
    }
    final chapterImage = details.chapter?.thumbnail;
    if (chapterImage != null) {
      return _PreviewFrame(
        key: const ValueKey('chapter'),
        image: chapterImage,
        style: style,
      );
    }
    return null;
  }
}

/// One frame: a whole image, or the [thumbnail]'s crop of a sprite sheet,
/// drawn at the frame's own aspect ratio (bounded by the style). Takes no
/// room until its first sheet is loaded (the bubble shows the time alone,
/// then grows the frame in), keeps the last frame while the next sheet
/// loads, and disappears when loading fails.
class _PreviewFrame extends StatefulWidget {
  const _PreviewFrame({
    super.key,
    required this.image,
    required this.style,
    this.thumbnail,
  });

  final ImageProvider image;
  final StoryboardThumbnail? thumbnail;
  final NativeVideoPlayerScrubPreviewStyle style;

  @override
  State<_PreviewFrame> createState() => _PreviewFrameState();
}

class _PreviewFrameState extends State<_PreviewFrame> {
  ImageStream? _stream;
  late final ImageStreamListener _listener = ImageStreamListener(
    _onImage,
    onError: _onError,
  );

  /// The last decoded sheet, which provider it came from, and the
  /// thumbnail last shown from it (kept while the next sheet loads).
  ImageInfo? _info;
  ImageProvider? _infoImage;
  StoryboardThumbnail? _infoThumbnail;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_PreviewFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolve();
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    super.dispose();
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _failed = false;
    _stream = stream..addListener(_listener);
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    if (!mounted) {
      info.dispose();
      return;
    }
    setState(() {
      _info?.dispose();
      _info = info;
      _infoImage = widget.image;
      _failed = false;
    });
  }

  void _onError(Object error, StackTrace? stackTrace) {
    // Forget the failure, so the next scrub asks again: a 403 or a dropped
    // connection must not lose the previews for the whole video. This one
    // leaves the frame out.
    PaintingBinding.instance.imageCache.evict(widget.image);
    if (!mounted) return;
    setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    // Nothing to show yet (or ever): no empty box, the time alone.
    if (_failed || info == null) return const SizedBox.shrink();
    final style = widget.style;
    final current =
        identical(_infoImage, widget.image) || _infoImage == widget.image;
    if (current) _infoThumbnail = widget.thumbnail;
    final thumbnail = current ? widget.thumbnail : _infoThumbnail;

    final imageSize = Size(
      info.image.width.toDouble(),
      info.image.height.toDouble(),
    );
    final source = thumbnail?.regionIn(imageSize) ?? Offset.zero & imageSize;
    final aspect = source.height > 0
        ? source.width / source.height
        : style.thumbnailAspectRatio;

    // thumbnailWidth wide, unless that makes it taller than allowed
    // (portrait): then thumbnailMaxHeight tall.
    var width = style.thumbnailWidth;
    var height = width / aspect;
    final maxHeight = style.thumbnailMaxHeight ?? style.thumbnailWidth;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * aspect;
    }

    return CustomPaint(
      size: Size(width, height),
      painter: _FramePainter(
        image: info.image,
        source: source,
        borderRadius: style.thumbnailBorderRadius,
        border: style.thumbnailBorder,
        textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      ),
    );
  }
}

/// The frame clipped to [borderRadius], with [border] painted over its edge.
class _FramePainter extends CustomPainter {
  _FramePainter({
    required this.image,
    required this.source,
    required this.borderRadius,
    required this.border,
    required this.textDirection,
  });

  final ui.Image image;
  final Rect source;
  final BorderRadius borderRadius;
  final BoxBorder? border;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final edges = border?.dimensions.resolve(textDirection);
    // Under a border the image stops halfway beneath it, so none of it shows
    // past the border's anti-aliased outer edge.
    final underBorder = edges == null
        ? 0.0
        : math.min(
                math.min(edges.left, edges.right),
                math.min(edges.top, edges.bottom),
              ) /
              2;
    canvas
      ..save()
      ..clipRRect(borderRadius.toRRect(rect).deflate(underBorder))
      ..drawImageRect(
        image,
        _withinCell(source, size),
        rect,
        Paint()..filterQuality = FilterQuality.medium,
      )
      ..restore();
    border?.paint(
      canvas,
      rect,
      borderRadius: borderRadius,
      textDirection: textDirection,
    );
  }

  /// Scaling down samples a few pixels around each one, which for a sprite
  /// cell reaches into the frames next to it and shows as a line along the
  /// edge. Trims about one drawn pixel's worth of the sheet off the short
  /// side, and the long side in proportion so the frame keeps its shape.
  static Rect _withinCell(Rect source, Size size) {
    if (size.isEmpty || source.isEmpty) return source;
    final sheetPixelsPerPixel = source.width / size.width;
    final trim = math.min(
      math.max(0.5, sheetPixelsPerPixel),
      source.shortestSide / 8,
    );
    final keep = 1 - 2 * trim / source.shortestSide;
    return Rect.fromCenter(
      center: source.center,
      width: source.width * keep,
      height: source.height * keep,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.image != image ||
      old.source != source ||
      old.borderRadius != borderRadius ||
      old.border != border ||
      old.textDirection != textDirection;
}

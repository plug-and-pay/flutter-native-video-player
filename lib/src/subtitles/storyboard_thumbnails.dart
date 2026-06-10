import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'subtitle_loader.dart';
import 'subtitle_parser.dart';

/// One scrub-preview entry: the image (or sprite-sheet region) shown while
/// the scrubber is between [start] and [end].
@immutable
class StoryboardThumbnail {
  const StoryboardThumbnail({
    required this.start,
    required this.end,
    required this.url,
    this.region,
  });

  final Duration start;
  final Duration end;

  /// Image URL (already resolved against the storyboard's base URL).
  final String url;

  /// Sprite-sheet crop from a `#xywh=x,y,w,h` fragment; null = whole image.
  final Rect? region;
}

/// WebVTT storyboard parsing for scrub-bar thumbnail previews.
///
/// Storyboard VTTs are the de-facto thumbnail-preview format (Vimeo, Mux,
/// JWPlayer, Roku all ship them): regular cues whose payload is an image
/// URL, optionally with a `#xywh=` fragment selecting a tile inside a
/// sprite sheet. This class parses them (reusing the tolerant sidecar
/// subtitle parser) and answers "which thumbnail belongs at position X" —
/// the UI side is one `Image.network` (plus a crop for sprite regions, e.g.
/// via a positioned child in a `ClipRect`).
class StoryboardThumbnails {
  StoryboardThumbnails._(this.entries);

  /// Parses storyboard VTT [content]. Relative image URLs are resolved
  /// against [baseUrl] — pass the storyboard's own URL, which is how the
  /// format is meant to be resolved.
  factory StoryboardThumbnails.parseVtt(String content, {Uri? baseUrl}) {
    final cues = SubtitleParser.parse(content, format: SubtitleFormat.vtt);
    final entries = <StoryboardThumbnail>[];
    for (final cue in cues) {
      if (cue.lines.isEmpty) {
        continue;
      }
      final raw = cue.lines.first.trim();
      if (raw.isEmpty) {
        continue;
      }

      var imageRef = raw;
      Rect? region;
      final fragmentStart = raw.indexOf('#xywh=');
      if (fragmentStart != -1) {
        imageRef = raw.substring(0, fragmentStart);
        final parts = raw.substring(fragmentStart + '#xywh='.length).split(',');
        final values = parts
            .map((p) => double.tryParse(p.trim()))
            .toList(growable: false);
        if (values.length == 4 && !values.contains(null)) {
          region = Rect.fromLTWH(
            values[0]!,
            values[1]!,
            values[2]!,
            values[3]!,
          );
        }
      }

      entries.add(
        StoryboardThumbnail(
          start: cue.start,
          end: cue.end,
          url: baseUrl == null
              ? imageRef
              : baseUrl.resolve(imageRef).toString(),
          region: region,
        ),
      );
    }
    entries.sort((a, b) => a.start.compareTo(b.start));
    return StoryboardThumbnails._(entries);
  }

  /// Builds a storyboard from uniform sprite-sheet grids — the format
  /// Vimeo (`thumb_preview` in the player config: one webp, `columns` ×
  /// rows, `frames` tiles) and Bunny Stream (`{video}/seek/_N.jpg`: 6×6
  /// grids, one frame per ~2s) actually serve, since neither ships a VTT
  /// index.
  ///
  /// [spriteUrls] are the sheet images in order; each holds up to
  /// [framesPerSprite] tiles ([columns] per row), every tile covering
  /// [frameInterval] of playback. [totalFrames] caps the count when the
  /// last sheet is partial (e.g. Vimeo's `frames`).
  factory StoryboardThumbnails.fromUniformGrid({
    required List<String> spriteUrls,
    required Duration frameInterval,
    required int columns,
    required double frameWidth,
    required double frameHeight,
    required int framesPerSprite,
    int? totalFrames,
  }) {
    assert(columns > 0 && framesPerSprite > 0);
    assert(frameInterval > Duration.zero);
    final frameCount = totalFrames ?? spriteUrls.length * framesPerSprite;
    final entries = <StoryboardThumbnail>[];
    for (var frame = 0; frame < frameCount; frame++) {
      final sheet = frame ~/ framesPerSprite;
      if (sheet >= spriteUrls.length) {
        break;
      }
      final indexInSheet = frame % framesPerSprite;
      entries.add(
        StoryboardThumbnail(
          start: frameInterval * frame,
          end: frameInterval * (frame + 1),
          url: spriteUrls[sheet],
          region: Rect.fromLTWH(
            (indexInSheet % columns) * frameWidth,
            (indexInSheet ~/ columns) * frameHeight,
            frameWidth,
            frameHeight,
          ),
        ),
      );
    }
    return StoryboardThumbnails._(entries);
  }

  /// Downloads and parses a storyboard VTT from [url].
  static Future<StoryboardThumbnails> fromUrl(String url) async {
    final content = await SubtitleLoader.loadUrl(url);
    return StoryboardThumbnails.parseVtt(content, baseUrl: Uri.parse(url));
  }

  /// Entries sorted by start time.
  final List<StoryboardThumbnail> entries;

  /// The entry whose start is at or before [position] (binary search) —
  /// storyboard cues can have gaps, so "nearest earlier" beats strict
  /// containment for scrub bars. Null before the first entry or when empty.
  StoryboardThumbnail? thumbnailAt(Duration position) {
    var low = 0;
    var high = entries.length - 1;
    var match = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (entries[mid].start <= position) {
        match = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return match == -1 ? null : entries[match];
  }
}

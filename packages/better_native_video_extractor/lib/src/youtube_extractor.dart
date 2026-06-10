import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'extracted_video.dart';
import 'extractor.dart';

/// Extracts YouTube streams + metadata via youtube_explode_dart (the
/// de-facto standard Dart implementation of YouTube's client protocol —
/// re-implementing the signature/cipher dance here would just rot).
///
/// Note YouTube's terms restrict playback outside their players; whether to
/// use this is a product/legal decision for the app. Provided because feed
/// apps commonly need at least metadata (title/thumbnail/duration), which
/// this also returns without committing to stream playback.
class YouTubeExtractor implements VideoSourceExtractor {
  YouTubeExtractor({YoutubeExplode? client}) : _yt = client ?? YoutubeExplode();

  final YoutubeExplode _yt;

  @override
  Future<ExtractedVideo> extract(String videoUrlOrId) async {
    try {
      final video = await _yt.videos.get(videoUrlOrId);
      final id = video.id.value;

      String? hlsUrl;
      String? progressiveUrl;
      try {
        final manifest = await _yt.videos.streamsClient.getManifest(id);
        // Live/some VOD expose HLS; otherwise best muxed progressive.
        final muxed = manifest.muxed.toList()
          ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
        if (muxed.isNotEmpty) {
          progressiveUrl = muxed.first.url.toString();
        }
      } catch (_) {
        // Metadata-only result is still useful (cards/thumbnails).
      }

      return ExtractedVideo(
        provider: 'youtube',
        videoId: id,
        hlsUrl: hlsUrl,
        progressiveUrl: progressiveUrl,
        title: video.title,
        duration: video.duration,
        thumbnails: [
          ExtractedThumbnail(url: video.thumbnails.maxResUrl),
          ExtractedThumbnail(url: video.thumbnails.highResUrl),
          ExtractedThumbnail(url: video.thumbnails.mediumResUrl),
        ],
        expiresAt: VimeoExpiryShim.expiryFromUrl(progressiveUrl),
      );
    } on VideoExtractionException {
      rethrow;
    } catch (e) {
      throw VideoExtractionException('youtube', e.toString());
    }
  }

  void close() => _yt.close();
}

/// YouTube stream URLs carry an `expire=<unix>` token; reuse the same
/// parsing idea as Vimeo's `exp=`.
class VimeoExpiryShim {
  static DateTime? expiryFromUrl(String? url) {
    if (url == null) return null;
    final m = RegExp(r'expire[=/](\d{9,12})').firstMatch(url);
    if (m == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      int.parse(m.group(1)!) * 1000,
      isUtc: true,
    );
  }
}

import 'dart:convert';
import 'dart:io';

import 'extracted_video.dart';
import 'extractor.dart';

/// Extracts Vimeo streams + metadata WITHOUT a WebView.
///
/// Primary path: `GET https://player.vimeo.com/video/{id}/config`, which
/// returns the player config as plain JSON (verified 2026-06: contains
/// `request.files.hls.cdns.*.url`, `video.thumbs`, `video.duration` — the
/// exact fields a player-page WebView would read from
/// `window.playerConfig`). Fallback path: fetch the player page HTML and
/// extract the inline `window.playerConfig = {...}` JSON (server-rendered,
/// no JS execution involved).
///
/// Domain-locked videos: pass the allowed domain via [referer] (and any
/// extra [headers], e.g. tenant auth) — the same header the embed page
/// would have sent. Private-link videos: include the hash in the URL/id
/// ("123456789/abcdef1234").
///
/// Stream URLs are tokenized (`exp=` unix timestamp, typically ~15 min);
/// the result's [ExtractedVideo.expiresAt] carries the parsed deadline so
/// callers (or [VideoExtractionCache]) can refresh proactively instead of
/// hitting a dead URL mid-playback.
class VimeoExtractor implements VideoSourceExtractor {
  VimeoExtractor({this.referer, this.headers = const {}, HttpClient? client})
      : _client = client ?? HttpClient();

  /// Referer header for domain-locked videos (e.g. "https://yourdomain.com").
  final String? referer;

  /// Extra request headers (tenant auth etc.).
  final Map<String, String> headers;

  final HttpClient _client;

  static final RegExp _idPattern = RegExp(
    // vimeo.com/123, vimeo.com/123/hash, player.vimeo.com/video/123,
    // or a bare numeric id (with optional /hash for private links).
    r'(?:vimeo\.com/(?:video/)?)?(\d+)(?:/([0-9a-zA-Z]+))?',
  );

  /// Parses a Vimeo URL or bare id into "id" or "id/privateHash".
  /// Returns null when nothing id-like is found.
  static String? parseVideoId(String urlOrId) {
    final m = _idPattern.firstMatch(urlOrId.trim());
    if (m == null) return null;
    final id = m.group(1)!;
    final hash = m.group(2);
    // Guard against matching the "h=" query parameter style separately:
    final hQuery = RegExp(r'[?&]h=([0-9a-zA-Z]+)').firstMatch(urlOrId);
    final effectiveHash = hash ?? hQuery?.group(1);
    return effectiveHash == null ? id : '$id/$effectiveHash';
  }

  @override
  Future<ExtractedVideo> extract(String videoUrlOrId) async {
    final id = parseVideoId(videoUrlOrId);
    if (id == null) {
      throw VideoExtractionException('vimeo', 'No video id in: $videoUrlOrId');
    }

    Map<String, dynamic> config;
    try {
      config = await _fetchJson('https://player.vimeo.com/video/$id/config');
    } on VideoExtractionException {
      // Fallback: the player page embeds window.playerConfig inline.
      final html = await _fetchBody('https://player.vimeo.com/video/$id');
      config = _configFromHtml(html);
    }
    return parseConfig(config, videoId: id);
  }

  /// Parses a player config JSON object into an [ExtractedVideo].
  /// Exposed for tests (works on fixture JSON without network).
  static ExtractedVideo parseConfig(
    Map<String, dynamic> config, {
    required String videoId,
  }) {
    final video = config['video'] as Map<String, dynamic>?;
    final files = (config['request'] as Map<String, dynamic>?)?['files']
        as Map<String, dynamic>?;

    String? hlsUrl;
    String? hlsAvcUrl;
    final cdns = (files?['hls'] as Map<String, dynamic>?)?['cdns']
        as Map<String, dynamic>?;
    if (cdns != null && cdns.isNotEmpty) {
      final cdn = cdns.values.first as Map<String, dynamic>;
      hlsUrl = cdn['url'] as String?;
      // H.264-only variant; AVPlayer rejects some default variants
      // ("Cannot Decode"), so this is what playbackUrl prefers.
      hlsAvcUrl = cdn['avc_url'] as String?;
    }

    // Progressive MP4s (older/smaller videos expose these).
    String? progressiveUrl;
    final progressive = files?['progressive'];
    if (progressive is List && progressive.isNotEmpty) {
      final sorted = [...progressive.cast<Map<String, dynamic>>()]..sort(
          (a, b) => ((b['height'] as num?) ?? 0).compareTo(
            (a['height'] as num?) ?? 0,
          ),
        );
      progressiveUrl = sorted.first['url'] as String?;
    }

    final thumbnails = <ExtractedThumbnail>[];
    final thumbs = video?['thumbs'] as Map<String, dynamic>?;
    if (thumbs != null) {
      for (final entry in thumbs.entries) {
        final width = int.tryParse(entry.key);
        thumbnails.add(
          ExtractedThumbnail(
            url: entry.value as String,
            width: width,
            // Vimeo thumbs keys are widths ("640", "960", "1280", "base").
          ),
        );
      }
      thumbnails.sort((a, b) => (b.width ?? 0).compareTo(a.width ?? 0));
    }
    final fallbackThumb = video?['thumbnail_url'] as String?;
    if (thumbnails.isEmpty && fallbackThumb != null) {
      thumbnails.add(ExtractedThumbnail(url: fallbackThumb));
    }

    final durationSeconds = (video?['duration'] as num?)?.toInt();

    // Scrub-preview sprite sheet ("thumb_preview": url + frame grid).
    ExtractedStoryboard? storyboard;
    final thumbPreview = (config['request']
        as Map<String, dynamic>?)?['thumb_preview'] as Map<String, dynamic>?;
    final sbUrl = thumbPreview?['url'] as String?;
    final sbFrameWidth = (thumbPreview?['frame_width'] as num?)?.toDouble();
    final sbFrameHeight = (thumbPreview?['frame_height'] as num?)?.toDouble();
    final sbColumns = (thumbPreview?['columns'] as num?)?.toInt();
    final sbFrames = (thumbPreview?['frames'] as num?)?.toInt();
    if (sbUrl != null &&
        sbFrameWidth != null &&
        sbFrameHeight != null &&
        sbColumns != null &&
        sbFrames != null) {
      storyboard = ExtractedStoryboard(
        url: sbUrl,
        frameWidth: sbFrameWidth,
        frameHeight: sbFrameHeight,
        columns: sbColumns,
        frames: sbFrames,
        width: (thumbPreview?['width'] as num?)?.toInt(),
        height: (thumbPreview?['height'] as num?)?.toInt(),
      );
    }

    return ExtractedVideo(
      provider: 'vimeo',
      videoId: videoId,
      hlsUrl: hlsUrl,
      hlsAvcUrl: hlsAvcUrl,
      progressiveUrl: progressiveUrl,
      title: video?['title'] as String?,
      duration:
          durationSeconds == null ? null : Duration(seconds: durationSeconds),
      thumbnails: thumbnails,
      expiresAt: expiryFromUrl(hlsAvcUrl ?? hlsUrl ?? progressiveUrl),
      storyboard: storyboard,
    );
  }

  /// Parses the `exp=<unix seconds>` token Vimeo embeds in stream URLs.
  static DateTime? expiryFromUrl(String? url) {
    if (url == null) return null;
    final m = RegExp(r'exp=(\d{9,12})').firstMatch(url);
    if (m == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      int.parse(m.group(1)!) * 1000,
      isUtc: true,
    );
  }

  static Map<String, dynamic> _configFromHtml(String html) {
    final m = RegExp(
      r'window\.playerConfig\s*=\s*(\{.*?\});?\s*(?:</script>|var |window\.)',
      dotAll: true,
    ).firstMatch(html);
    if (m == null) {
      throw const VideoExtractionException(
        'vimeo',
        'No inline playerConfig in player page',
      );
    }
    return jsonDecode(m.group(1)!) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _fetchJson(String url) async {
    final body = await _fetchBody(url);
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } on FormatException {
      throw VideoExtractionException('vimeo', 'Non-JSON response from $url');
    }
  }

  Future<String> _fetchBody(String url) async {
    final request = await _client.getUrl(Uri.parse(url));
    if (referer != null) {
      request.headers.set(HttpHeaders.refererHeader, referer!);
    }
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw VideoExtractionException(
        'vimeo',
        'HTTP ${response.statusCode} for $url',
        statusCode: response.statusCode,
      );
    }
    return body;
  }

  void close() => _client.close();
}

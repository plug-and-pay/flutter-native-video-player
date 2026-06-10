/// WebView-free extraction of playable streams from hosted video platforms.
///
/// - [VimeoExtractor]: fetches the player config as plain JSON (with
///   optional Referer for domain-locked videos) — HLS URL, thumbnails in
///   multiple sizes, duration, title, and token expiry.
/// - [YouTubeExtractor]: muxed/HLS stream resolution via youtube_explode.
/// - [VideoExtractionCache]: expiry-aware caching so feeds never re-extract
///   while a tokenized URL is still valid.
library;

export 'src/extracted_video.dart';
export 'src/extraction_cache.dart';
export 'src/extractor.dart';
export 'src/vimeo_extractor.dart';
export 'src/youtube_extractor.dart';

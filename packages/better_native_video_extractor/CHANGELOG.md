# Changelog

## [0.1.0] - 2026-06-11

Initial release.

- **VimeoExtractor**: resolves Vimeo URLs/ids (including private-link
  hashes) to playable HLS/MP4 URLs over plain HTTP — no WebView. Supports
  a Referer header for domain-locked videos, prefers the H.264 `avc_url`
  variant for AVPlayer compatibility, and returns title, duration,
  thumbnails in multiple sizes, token expiry (`exp=`), and the
  `thumb_preview` scrub storyboard.
- **YouTubeExtractor**: metadata + muxed stream resolution via
  `youtube_explode_dart`.
- **VideoExtractionCache**: expiry-aware caching (parses the URL token
  deadline), coalesces concurrent extractions, `timeToRefresh()` for
  proactive refresh of the playing video, and a `failures` stream emitting
  `VideoExtractionFailure` for app-wide error reporting.

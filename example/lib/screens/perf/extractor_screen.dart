import 'dart:async';

import 'package:better_native_video_extractor/better_native_video_extractor.dart';
import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

import '../../widgets/storyboard_scrub_bar.dart';

/// Demo + Marionette harness for the WebView-free Vimeo extractor package:
/// extract metadata (title/duration/thumbnail/HLS URL + expiry) over plain
/// HTTP, show the thumbnail, then play the extracted stream natively.
class ExtractorScreen extends StatefulWidget {
  const ExtractorScreen({super.key});

  static const int controllerId = 9950;

  @override
  State<ExtractorScreen> createState() => _ExtractorScreenState();
}

class _ExtractorScreenState extends State<ExtractorScreen> {
  late final NativeVideoPlayerController _controller;
  final _cache = VideoExtractionCache(VimeoExtractor());
  final _urlField = TextEditingController(text: 'https://vimeo.com/76979871');

  ExtractedVideo? _video;
  StoryboardThumbnails? _storyboard;
  StreamSubscription<VideoExtractionFailure>? _failureSub;
  String? _error;
  String? _failureEvent;
  bool _busy = false;
  bool _playerVisible = false;

  @override
  void initState() {
    super.initState();
    _controller = NativeVideoPlayerController(
      id: ExtractorScreen.controllerId,
      autoPlay: true,
      lockToLandscape: false,
      showNativeControls: false,
    );
    // One listener catches EVERY failed extraction through this cache —
    // the place to hook a crash reporter / analytics in a real app.
    _failureSub = _cache.failures.listen((failure) {
      if (mounted) setState(() => _failureEvent = failure.toString());
    });
  }

  Future<void> _extract() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The cache coalesces concurrent calls and honors the URL's exp=
      // token, exactly like a feed should use it.
      final video = await _cache.extract(_urlField.text);
      // Map the extractor's sprite-sheet storyboard onto the plugin's
      // thumbnail API so the scrub bar can preview while dragging.
      StoryboardThumbnails? storyboard;
      final sb = video.storyboard;
      final duration = video.duration;
      if (sb != null && duration != null && sb.frames > 0) {
        storyboard = StoryboardThumbnails.fromUniformGrid(
          spriteUrls: [sb.url],
          frameInterval: duration ~/ sb.frames,
          columns: sb.columns,
          frameWidth: sb.frameWidth,
          frameHeight: sb.frameHeight,
          framesPerSprite: sb.frames,
          totalFrames: sb.frames,
        );
      }
      if (mounted) {
        setState(() {
          _video = video;
          _storyboard = storyboard;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _play() async {
    final url = _video?.playbackUrl;
    if (url == null) return;
    setState(() => _playerVisible = true);
    try {
      await _controller.initialize();
      await _controller.load(url: url, force: true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    unawaited(_failureSub?.cancel());
    _urlField.dispose();
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    return Scaffold(
      appBar: AppBar(title: const Text('Vimeo extractor')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const ValueKey('extractor_url'),
            controller: _urlField,
            decoration: const InputDecoration(
              labelText: 'Vimeo URL or id (referer-locked? set it in code)',
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            key: const ValueKey('extractor_extract'),
            onPressed: _busy ? null : _extract,
            child: Text(_busy ? 'Extracting…' : 'Extract (no WebView)'),
          ),
          if (_error != null)
            Text(
              _error!,
              key: const ValueKey('extractor_error'),
              style: const TextStyle(color: Colors.red),
            ),
          if (_failureEvent != null)
            Text(
              'event: $_failureEvent',
              key: const ValueKey('extractor_failure_event'),
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
          if (video != null) ...[
            ListTile(
              title: Text(
                'title: ${video.title}',
                key: const ValueKey('extractor_title'),
              ),
              subtitle: Text(
                'duration: ${video.duration} — '
                'expires: ${video.expiresAt?.toLocal()} — '
                'thumbs: ${video.thumbnails.length} — '
                'storyboard: ${video.storyboard?.frames ?? 0} frames',
                key: const ValueKey('extractor_meta'),
              ),
            ),
            if (video.bestThumbnail != null)
              Image.network(
                video.bestThumbnail!.url,
                key: const ValueKey('extractor_thumb'),
                height: 180,
                fit: BoxFit.contain,
              ),
            const SizedBox(height: 8),
            ElevatedButton(
              key: const ValueKey('extractor_play'),
              onPressed: _play,
              child: const Text('Play extracted stream'),
            ),
          ],
          if (_playerVisible) ...[
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                color: Colors.black,
                child: NativeVideoPlayer(controller: _controller),
              ),
            ),
            // Drag to scrub — the Vimeo storyboard sprite shows a frame
            // preview of the target position while dragging.
            StoryboardScrubBar(
              controller: _controller,
              storyboard: _storyboard,
            ),
          ],
        ],
      ),
    );
  }
}

import 'package:better_native_video_extractor/better_native_video_extractor.dart';
import 'package:test/test.dart';

void main() {
  group('parseVideoId', () {
    test('accepts URLs, player URLs, bare ids and private hashes', () {
      expect(VimeoExtractor.parseVideoId('https://vimeo.com/76979871'),
          '76979871');
      expect(
        VimeoExtractor.parseVideoId('https://player.vimeo.com/video/76979871'),
        '76979871',
      );
      expect(VimeoExtractor.parseVideoId('76979871'), '76979871');
      expect(
        VimeoExtractor.parseVideoId('https://vimeo.com/123456789/abcdef1234'),
        '123456789/abcdef1234',
      );
      expect(
        VimeoExtractor.parseVideoId(
          'https://player.vimeo.com/video/123456789?h=fffff00000',
        ),
        '123456789/fffff00000',
      );
      expect(VimeoExtractor.parseVideoId('not a vimeo url'), isNull);
    });
  });

  group('parseConfig', () {
    final fixture = <String, dynamic>{
      'request': {
        'files': {
          'hls': {
            'cdns': {
              'akfire': {
                'url': 'https://cdn.test/master.m3u8?exp=1781131250~x',
                'avc_url': 'https://cdn.test/avc.m3u8?exp=1781131250~x',
              },
              'fastly': {'url': 'https://cdn2.test/master.m3u8'},
            },
          },
          'progressive': [
            {'height': 360, 'url': 'https://cdn.test/360.mp4'},
            {'height': 720, 'url': 'https://cdn.test/720.mp4?exp=1781131250'},
          ],
        },
        'thumb_preview': {
          'url': 'https://sprites.test/board.webp',
          'width': 4260,
          'height': 2880,
          'frame_width': 426,
          'frame_height': 240,
          'columns': 10,
          'frames': 120,
        },
      },
      'video': {
        'title': 'Test video',
        'duration': 125,
        'thumbs': {
          '640': 'https://i.test/640.jpg',
          '1280': 'https://i.test/1280.jpg',
          'base': 'https://i.test/base',
        },
      },
    };

    test('extracts hls, progressive, thumbnails, duration, expiry', () {
      final video = VimeoExtractor.parseConfig(fixture, videoId: '42');

      expect(video.provider, 'vimeo');
      expect(video.hlsUrl, startsWith('https://cdn.test/master.m3u8'));
      expect(video.hlsAvcUrl, startsWith('https://cdn.test/avc.m3u8'));
      expect(video.progressiveUrl, contains('720.mp4'));
      // Compatibility-first: the H.264 variant wins (AVPlayer rejects some
      // default Vimeo variants with "Cannot Decode").
      expect(video.playbackUrl, video.hlsAvcUrl);
      expect(video.title, 'Test video');
      expect(video.duration, const Duration(minutes: 2, seconds: 5));
      expect(video.thumbnails, hasLength(3));
      expect(video.bestThumbnail!.url, 'https://i.test/1280.jpg');
      expect(
        video.expiresAt,
        DateTime.fromMillisecondsSinceEpoch(1781131250 * 1000, isUtc: true),
      );
    });

    test('parses the thumb_preview storyboard sprite sheet', () {
      final video = VimeoExtractor.parseConfig(fixture, videoId: '42');

      final sb = video.storyboard!;
      expect(sb.url, 'https://sprites.test/board.webp');
      expect(sb.frameWidth, 426);
      expect(sb.frameHeight, 240);
      expect(sb.columns, 10);
      expect(sb.frames, 120);
      expect(sb.width, 4260);
      expect(sb.height, 2880);
    });

    test('storyboard is null when thumb_preview is absent or partial', () {
      expect(
        VimeoExtractor.parseConfig({
          'video': {'title': 'x'},
        }, videoId: '1')
            .storyboard,
        isNull,
      );
      expect(
        VimeoExtractor.parseConfig({
          'request': {
            'thumb_preview': {'url': 'https://sprites.test/only-url.webp'},
          },
        }, videoId: '1')
            .storyboard,
        isNull,
      );
    });

    test('thumbnail_url fallback when thumbs missing', () {
      final video = VimeoExtractor.parseConfig({
        'video': {'thumbnail_url': 'https://i.test/fallback.jpg'},
      }, videoId: '1');
      expect(video.bestThumbnail!.url, 'https://i.test/fallback.jpg');
      expect(video.hlsUrl, isNull);
      expect(video.expiresAt, isNull);
    });

    test('isFresh respects expiry and margin', () {
      final fresh = ExtractedVideo(
        provider: 'vimeo',
        videoId: '1',
        hlsUrl: 'x',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      );
      final stale = ExtractedVideo(
        provider: 'vimeo',
        videoId: '1',
        hlsUrl: 'x',
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(fresh.isFresh(), isTrue);
      expect(stale.isFresh(), isFalse);
      expect(stale.isFresh(margin: Duration.zero), isTrue);
    });
  });

  group('VideoExtractionCache', () {
    test('caches fresh results and coalesces concurrent calls', () async {
      var calls = 0;
      final cache = VideoExtractionCache(
        _FakeExtractor(() async {
          calls++;
          return ExtractedVideo(
            provider: 'vimeo',
            videoId: '1',
            hlsUrl: 'url$calls',
            expiresAt: DateTime.now().add(const Duration(minutes: 10)),
          );
        }),
      );

      final results = await Future.wait([
        cache.extract('1'),
        cache.extract('1'),
        cache.extract('1'),
      ]);
      expect(calls, 1, reason: 'concurrent extractions must coalesce');
      expect(results.map((r) => r.hlsUrl).toSet(), {'url1'});

      await cache.extract('1');
      expect(calls, 1, reason: 'fresh result must come from cache');
    });

    test('expired entries re-extract', () async {
      var calls = 0;
      final cache = VideoExtractionCache(
        _FakeExtractor(() async {
          calls++;
          return ExtractedVideo(
            provider: 'vimeo',
            videoId: '1',
            hlsUrl: 'url$calls',
            expiresAt: DateTime.now().add(const Duration(seconds: 1)),
          );
        }),
      );
      await cache.extract('1');
      await cache.extract('1'); // within margin -> stale -> re-extract
      expect(calls, 2);
    });

    test('failed extraction throws AND emits on failures stream', () async {
      final cache = VideoExtractionCache(
        _FakeExtractor(() async {
          throw const VideoExtractionException('vimeo', 'config 403');
        }),
      );
      final events = <VideoExtractionFailure>[];
      final sub = cache.failures.listen(events.add);

      await expectLater(
        cache.extract('https://vimeo.com/123'),
        throwsA(isA<VideoExtractionException>()),
      );
      await Future<void>.delayed(Duration.zero); // let the event deliver

      expect(events, hasLength(1));
      expect(events.single.videoUrlOrId, 'https://vimeo.com/123');
      expect(events.single.error, isA<VideoExtractionException>());
      await sub.cancel();
      cache.dispose();
    });

    test('successful extraction emits nothing on failures', () async {
      final cache = VideoExtractionCache(
        _FakeExtractor(() async => const ExtractedVideo(
              provider: 'vimeo',
              videoId: '1',
              hlsUrl: 'url',
            )),
      );
      final events = <VideoExtractionFailure>[];
      final sub = cache.failures.listen(events.add);
      await cache.extract('1');
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await sub.cancel();
      cache.dispose();
    });
  });
}

class _FakeExtractor implements VideoSourceExtractor {
  _FakeExtractor(this._fn);
  final Future<ExtractedVideo> Function() _fn;
  @override
  Future<ExtractedVideo> extract(String videoUrlOrId) => _fn();
}

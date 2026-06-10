import 'package:better_native_video_extractor/better_native_video_extractor.dart';

Future<void> main() async {
  final extractor = VimeoExtractor(referer: 'https://vimeo.com');
  final video = await extractor.extract('https://vimeo.com/76979871');
  print('title: ${video.title}');
  print('duration: ${video.duration}');
  print('hls: ${video.hlsUrl?.substring(0, 60)}...');
  print(
      'thumbs: ${video.thumbnails.length}, best: ${video.bestThumbnail?.url}');
  print('expiresAt: ${video.expiresAt} (fresh: ${video.isFresh()})');
  extractor.close();
}

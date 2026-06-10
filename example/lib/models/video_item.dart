class VideoItem {
  final int id;
  final String title;
  final String description;
  final String url;
  final String artworkUrl;
  final bool shouldLoop, autoPlay;

  VideoItem({
    required this.id,
    required this.title,
    required this.description,
    required this.url,
    required this.artworkUrl,
    this.shouldLoop = false,
    this.autoPlay = false,
  });

  /// Videos for the performance/stress harness: [count] items alternating
  /// HLS and MP4 sources with unique controller IDs in the 9000+ range so
  /// they never collide with the regular sample videos.
  static List<VideoItem> getStressVideos(int count, {int idOffset = 9000}) {
    const hlsUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
    // Note: the BigBuckBunny googleapis URL used by the sample list returns
    // 403 from some networks, so the stress harness uses the W3C-hosted
    // Sintel trailer as its MP4 source instead.
    const mp4Url = 'https://media.w3.org/2010/05/sintel/trailer.mp4';
    return List<VideoItem>.generate(count, (i) {
      final isHls = i.isEven;
      return VideoItem(
        id: idOffset + i,
        title: 'Stress ${i + 1} (${isHls ? 'HLS' : 'MP4'})',
        description: 'Stress test video ${i + 1}',
        url: isHls ? hlsUrl : mp4Url,
        artworkUrl: 'https://picsum.photos/id/${20 + i}/200/300',
      );
    });
  }

  static List<VideoItem> getSampleVideos() {
    return [
      VideoItem(
        id: 1,
        title: 'Big Buck Bunny (MP4)',
        description:
            'A large and lovable rabbit deals with three tiny bullies. This is a direct MP4 URL example.',
        url:
            'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
        artworkUrl: 'https://picsum.photos/id/1/200/300',
        shouldLoop: true,
      ),
      VideoItem(
        id: 14,
        title: 'Elephant Dream (Local File)',
        description:
            'Local file test - The first open movie from the Blender Foundation loaded from app assets.',
        url: 'assets/ElephantsDream.mp4',
        artworkUrl: 'https://picsum.photos/id/14/200/300',
      ),
      VideoItem(
        id: 2,
        title: 'CNN',
        description: 'CNN livestream',
        url:
            'https://dai.google.com/linear/hls/pa/event/Sid4xiTQTkCT1SLu6rjUSQ/stream/40960d7a-2d93-425e-b3cd-157ecc1bc5f5:GRQ/variant/bbe09487996e4026304507dc92286621/bandwidth/4231000.m3u8',
        artworkUrl: 'https://picsum.photos/id/2/200/300',
        autoPlay: true,
      ),
      VideoItem(
        id: 3,
        title: 'Tears of Steel (HLS)',
        description:
            'A group of warriors and scientists unite to fight against a robot army. This is an HLS stream example.',
        url:
            'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.mp4/.m3u8',
        artworkUrl: 'https://picsum.photos/id/3/200/300',
      ),
      VideoItem(
        id: 4,
        title: 'Tears of Steel',
        description:
            'A group of warriors and scientists unite to fight against a robot army and save the future of mankind.',
        url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        artworkUrl: 'https://picsum.photos/id/4/200/300',
      ),
      VideoItem(
        id: 5,
        title: 'For Bigger Blazes',
        description:
            'Experience the power and beauty of fire in stunning high definition quality.',
        url:
            'http://d3rlna7iyyu8wu.cloudfront.net/skip_armstrong/skip_armstrong_multichannel_subs.m3u8',
        artworkUrl: 'https://picsum.photos/id/5/200/300',
      ),
      VideoItem(
        id: 6,
        title: 'Sintel',
        description:
            'A lonely young woman, Sintel, helps and befriends a dragon, whom she calls Scales. But when he is kidnapped by an adult dragon, Sintel decides to embark on a dangerous quest to find her lost friend.',
        url:
            'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.mp4/.m3u8',
        artworkUrl: 'https://picsum.photos/id/6/200/300',
      ),
      VideoItem(
        id: 7,
        title: 'Sintel',
        description:
            'A lonely young woman, Sintel, helps and befriends a dragon, whom she calls Scales. But when he is kidnapped by an adult dragon, Sintel decides to embark on a dangerous quest to find her lost friend.',
        url:
            'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.mp4/.m3u8',
        artworkUrl: 'https://picsum.photos/id/7/200/300',
      ),
      VideoItem(
        id: 8,
        title: 'Sintel',
        description:
            'A lonely young woman, Sintel, helps and befriends a dragon, whom she calls Scales. But when he is kidnapped by an adult dragon, Sintel decides to embark on a dangerous quest to find her lost friend.',
        url:
            'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.mp4/.m3u8',
        artworkUrl: 'https://picsum.photos/id/8/200/300',
      ),
      VideoItem(
        id: 9,
        title: 'Sintel',
        description:
            'A lonely young woman, Sintel, helps and befriends a dragon, whom she calls Scales. But when he is kidnapped by an adult dragon, Sintel decides to embark on a dangerous quest to find her lost friend.',
        url:
            'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.mp4/.m3u8',
        artworkUrl: 'https://picsum.photos/id/9/200/300',
      ),
      VideoItem(
        id: 10,
        title: 'Sintel',
        description:
            'A lonely young woman, Sintel, helps and befriends a dragon, whom she calls Scales. But when he is kidnapped by an adult dragon, Sintel decides to embark on a dangerous quest to find her lost friend.',
        url:
            'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.mp4/.m3u8',
        artworkUrl: 'https://picsum.photos/id/10/200/300',
      ),
      VideoItem(
        id: 11,
        title: 'Sintel',
        description:
            'A lonely young woman, Sintel, helps and befriends a dragon, whom she calls Scales. But when he is kidnapped by an adult dragon, Sintel decides to embark on a dangerous quest to find her lost friend.',
        url:
            'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.mp4/.m3u8',
        artworkUrl: 'https://picsum.photos/id/11/200/300',
      ),
      VideoItem(
        id: 12,
        title: 'Sintel',
        description:
            'A lonely young woman, Sintel, helps and befriends a dragon, whom she calls Scales. But when he is kidnapped by an adult dragon, Sintel decides to embark on a dangerous quest to find her lost friend.',
        url:
            'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.mp4/.m3u8',
        artworkUrl: 'https://picsum.photos/id/12/200/300',
      ),
      VideoItem(
        id: 13,
        title: 'Sintel',
        description:
            'A lonely young woman, Sintel, helps and befriends a dragon, whom she calls Scales. But when he is kidnapped by an adult dragon, Sintel decides to embark on a dangerous quest to find her lost friend.',
        url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        artworkUrl: 'https://picsum.photos/id/13/200/300',
      ),
    ];
  }
}

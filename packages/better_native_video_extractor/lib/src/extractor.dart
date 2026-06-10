import 'extracted_video.dart';

/// Common interface for platform extractors so apps can register them
/// uniformly (and tests can fake them).
// ignore: one_member_abstracts
abstract class VideoSourceExtractor {
  /// Extracts stream URL + metadata for [videoUrlOrId].
  Future<ExtractedVideo> extract(String videoUrlOrId);
}

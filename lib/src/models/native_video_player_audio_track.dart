/// Represents an alternate audio track of the current media (multiple
/// languages, audio description, commentary) — the audio counterpart of
/// [NativeVideoPlayerSubtitleTrack]. Requested in issues #23 and #16.
class NativeVideoPlayerAudioTrack {
  const NativeVideoPlayerAudioTrack({
    required this.index,
    required this.language,
    required this.displayName,
    this.isSelected = false,
    this.isOriginal = false,
  });

  factory NativeVideoPlayerAudioTrack.fromMap(Map<dynamic, dynamic> map) {
    return NativeVideoPlayerAudioTrack(
      index: map['index'] as int,
      language: map['language'] as String,
      displayName: map['displayName'] as String,
      isSelected: map['isSelected'] as bool? ?? false,
      isOriginal: map['isOriginal'] as bool? ?? false,
    );
  }

  /// Track index within the platform's audio track enumeration.
  final int index;

  /// Language code (e.g. "en", "nl", "en-US").
  final String language;

  /// Human-readable name (e.g. "English", "English (audio description)").
  final String displayName;

  /// Whether this track is currently playing.
  final bool isSelected;

  /// Whether this is the original-language track of a stream that also has
  /// dubbed tracks: the stream marks at least one other audio track as dubbed
  /// (HLS `CHARACTERISTICS="public.translation.dubbed"`) and this one isn't.
  /// At most one track is original, the stream's DEFAULT when several
  /// qualify. A stream without dub markings has no original track.
  final bool isOriginal;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'index': index,
    'language': language,
    'displayName': displayName,
    'isSelected': isSelected,
    'isOriginal': isOriginal,
  };

  @override
  String toString() =>
      'NativeVideoPlayerAudioTrack(index: $index, language: $language, '
      'displayName: $displayName, isSelected: $isSelected, '
      'isOriginal: $isOriginal)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NativeVideoPlayerAudioTrack &&
          runtimeType == other.runtimeType &&
          index == other.index &&
          language == other.language &&
          displayName == other.displayName &&
          isSelected == other.isSelected &&
          isOriginal == other.isOriginal;

  @override
  int get hashCode =>
      Object.hash(index, language, displayName, isSelected, isOriginal);
}

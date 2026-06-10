/// Represents an alternate audio track of the current media (multiple
/// languages, audio description, commentary) — the audio counterpart of
/// [NativeVideoPlayerSubtitleTrack]. Requested in issues #23 and #16.
class NativeVideoPlayerAudioTrack {
  const NativeVideoPlayerAudioTrack({
    required this.index,
    required this.language,
    required this.displayName,
    this.isSelected = false,
  });

  factory NativeVideoPlayerAudioTrack.fromMap(Map<dynamic, dynamic> map) {
    return NativeVideoPlayerAudioTrack(
      index: map['index'] as int,
      language: map['language'] as String,
      displayName: map['displayName'] as String,
      isSelected: map['isSelected'] as bool? ?? false,
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

  Map<String, dynamic> toMap() => <String, dynamic>{
    'index': index,
    'language': language,
    'displayName': displayName,
    'isSelected': isSelected,
  };

  @override
  String toString() =>
      'NativeVideoPlayerAudioTrack(index: $index, language: $language, '
      'displayName: $displayName, isSelected: $isSelected)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NativeVideoPlayerAudioTrack &&
          runtimeType == other.runtimeType &&
          index == other.index &&
          language == other.language &&
          displayName == other.displayName &&
          isSelected == other.isSelected;

  @override
  int get hashCode => Object.hash(index, language, displayName, isSelected);
}

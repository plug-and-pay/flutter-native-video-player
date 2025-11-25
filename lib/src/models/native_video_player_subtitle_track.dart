/// Represents a subtitle/closed caption track in the video player
class NativeVideoPlayerSubtitleTrack {
  const NativeVideoPlayerSubtitleTrack({
    required this.index,
    required this.language,
    required this.displayName,
    this.isSelected = false,
  });

  factory NativeVideoPlayerSubtitleTrack.fromMap(Map<dynamic, dynamic> map) {
    return NativeVideoPlayerSubtitleTrack(
      index: map['index'] as int,
      language: map['language'] as String,
      displayName: map['displayName'] as String,
      isSelected: map['isSelected'] as bool? ?? false,
    );
  }

  /// Represents an "Off" or "None" subtitle option
  factory NativeVideoPlayerSubtitleTrack.off() =>
      const NativeVideoPlayerSubtitleTrack(
        index: -1,
        language: 'off',
        displayName: 'Off',
        isSelected: false,
      );

  /// The index of the subtitle track (platform-specific identifier)
  final int index;

  /// The language code (e.g., "en", "es", "fr", "en-US")
  final String language;

  /// The display name for the subtitle track (e.g., "English", "Spanish (Latin America)")
  final String displayName;

  /// Whether this subtitle track is currently selected
  final bool isSelected;

  /// Whether this is the "Off" option
  bool get isOff => index == -1;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'index': index,
        'language': language,
        'displayName': displayName,
        'isSelected': isSelected,
      };

  NativeVideoPlayerSubtitleTrack copyWith({
    int? index,
    String? language,
    String? displayName,
    bool? isSelected,
  }) {
    return NativeVideoPlayerSubtitleTrack(
      index: index ?? this.index,
      language: language ?? this.language,
      displayName: displayName ?? this.displayName,
      isSelected: isSelected ?? this.isSelected,
    );
  }

  @override
  String toString() =>
      'NativeVideoPlayerSubtitleTrack(index: $index, language: $language, displayName: $displayName, isSelected: $isSelected)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NativeVideoPlayerSubtitleTrack &&
          runtimeType == other.runtimeType &&
          index == other.index &&
          language == other.language &&
          displayName == other.displayName &&
          isSelected == other.isSelected;

  @override
  int get hashCode => Object.hash(index, language, displayName, isSelected);
}

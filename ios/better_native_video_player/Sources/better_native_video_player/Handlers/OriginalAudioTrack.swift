import AVFoundation

/// Finds the original-language audio track of a stream that also has dubbed
/// ones (Vimeo's AI dubs mark each dub `CHARACTERISTICS="public.translation.dubbed"`).
/// The same rule runs on Android (OriginalAudioTrack.kt).
enum OriginalAudioTrack {
    static let dubbed = AVMediaCharacteristic(rawValue: "public.translation.dubbed")
    static let original = AVMediaCharacteristic(rawValue: "public.original-content")

    struct Track {
        let isDubbed: Bool
        let isMarkedOriginal: Bool
        let isDefault: Bool
    }

    /// The index of the original track among [options], or nil.
    static func index(in group: AVMediaSelectionGroup) -> Int? {
        index(of: group.options.map { option in
            Track(
                isDubbed: option.hasMediaCharacteristic(dubbed),
                isMarkedOriginal: option.hasMediaCharacteristic(original),
                isDefault: option == group.defaultOption
            )
        })
    }

    /// Only a stream that marks at least one track dubbed has an original: a
    /// track that isn't dubbed, preferring one marked original, then the
    /// DEFAULT one, then the first. Without dub markings there is none, so a
    /// plain multi-language stream gets no "original" label.
    static func index(of tracks: [Track]) -> Int? {
        guard tracks.contains(where: { $0.isDubbed }) else { return nil }

        let candidates = tracks.indices.filter { !tracks[$0].isDubbed }
        return candidates.first { tracks[$0].isMarkedOriginal }
            ?? candidates.first { tracks[$0].isDefault }
            ?? candidates.first
    }
}

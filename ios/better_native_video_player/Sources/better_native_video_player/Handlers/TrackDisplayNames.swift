import Foundation
import AVFoundation

/// Names audio and subtitle tracks by their language, in the device language
/// ("Duits" on a Dutch phone), the same way on iOS and Android.
///
/// AVFoundation's own `displayName` is that language name too, but it only
/// sometimes tells two tracks of the same language apart: angel-one's second
/// English track shows "stream_6 - English", while a playlist with
/// "Commentary", "English" and "English 5.1" (all `LANGUAGE=en`) shows
/// "English" three times. So the HLS `NAME` comes in whenever tracks of the
/// same kind share a language: "English (Commentary)", or just "English 5.1"
/// when the name already says which language it is.
enum TrackDisplayNames {
    struct Track {
        let language: String?
        let name: String?
        /// Used when the track has no usable language (e.g. AVFoundation's "CC").
        let fallback: String?
    }

    static func displayNames(for options: [AVMediaSelectionOption], locale: Locale = .current) -> [String] {
        displayNames(
            for: options.map { option in
                Track(
                    language: option.extendedLanguageTag ?? option.locale?.identifier,
                    name: AVMetadataItem.metadataItems(
                        from: option.commonMetadata,
                        filteredByIdentifier: .commonIdentifierTitle
                    ).first?.stringValue,
                    fallback: option.displayName
                )
            },
            locale: locale
        )
    }

    /// One display name per track, in the same order.
    static func displayNames(for tracks: [Track], locale: Locale = .current) -> [String] {
        let languageNames = tracks.map { languageName($0.language, locale: locale) }
        var languageCounts: [String: Int] = [:]
        for case let name? in languageNames {
            languageCounts[name, default: 0] += 1
        }

        return tracks.enumerated().map { index, track in
            let name = nonEmpty(track.name)
            guard let languageName = languageNames[index] else {
                return name ?? nonEmpty(track.fallback) ?? nonEmpty(track.language) ?? "Unknown"
            }

            guard (languageCounts[languageName] ?? 0) > 1, let name = name else {
                return languageName
            }

            if name.range(of: languageName, options: .caseInsensitive) != nil {
                return name
            }

            return "\(languageName) (\(name))"
        }
    }

    /// The language of a BCP 47 tag in [locale], with its region or script
    /// when the tag has one ("Portuguese (Brazil)"), capitalised. Nil for a
    /// missing, undetermined or unknown language.
    static func languageName(_ language: String?, locale: Locale = .current) -> String? {
        guard let tag = nonEmpty(language),
              let code = Locale.components(fromIdentifier: tag)[NSLocale.Key.languageCode.rawValue],
              !["und", "mul", "zxx", "mis"].contains(code),
              let name = locale.localizedString(forIdentifier: tag),
              !name.isEmpty,
              name.caseInsensitiveCompare(code) != .orderedSame,
              name.caseInsensitiveCompare(tag) != .orderedSame
        else { return nil }

        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }
}

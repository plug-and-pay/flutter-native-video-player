import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer

// Embedded subtitle and audio track listing/selection.
// Split from VideoPlayerMethodHandler.swift for maintainability;
// all members keep full access to VideoPlayerView state.
extension VideoPlayerView {
    func handleGetAvailableSubtitleTracks(result: @escaping FlutterResult) {
        guard let playerItem = player?.currentItem,
              let asset = playerItem.asset as? AVURLAsset else {
            result([])
            return
        }

        // Get all media selection options for legible characteristics (subtitles/captions)
        guard let mediaSelectionGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            npLog("📝 No subtitle tracks available")
            result([])
            return
        }

        var tracks: [[String: Any]] = []

        // Get currently selected subtitle option
        let currentSelection = playerItem.currentMediaSelection.selectedMediaOption(in: mediaSelectionGroup)

        // Add each subtitle option
        for (index, option) in mediaSelectionGroup.options.enumerated() {
            let isSelected = option == currentSelection

            // Get language code (e.g., "en", "es", "fr")
            let languageCode = option.extendedLanguageTag ?? option.locale?.identifier ?? "unknown"

            // Get display name (e.g., "English", "Spanish", "French")
            var displayName = option.displayName

            // If display name is empty, try to get it from locale
            if displayName.isEmpty, let locale = option.locale {
                displayName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? languageCode
            }

            // If still empty, use language code
            if displayName.isEmpty {
                displayName = languageCode
            }

            let trackInfo: [String: Any] = [
                "index": index,
                "language": languageCode,
                "displayName": displayName,
                "isSelected": isSelected
            ]

            tracks.append(trackInfo)
            npLog("📝 Found subtitle track: \(displayName) (\(languageCode)) - Selected: \(isSelected)")
        }

        npLog("📝 Total subtitle tracks found: \(tracks.count)")
        result(tracks)
    }

    /// Mirror of handleGetAvailableSubtitleTracks for the AUDIBLE media
    /// characteristic: lists alternate audio renditions (languages, audio
    /// description, commentary) of HLS/multi-track content. Issues #23/#16.
    func handleGetAvailableAudioTracks(result: @escaping FlutterResult) {
        guard let playerItem = player?.currentItem,
              let asset = playerItem.asset as? AVURLAsset,
              let mediaSelectionGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            result([])
            return
        }

        let currentSelection = playerItem.currentMediaSelection.selectedMediaOption(in: mediaSelectionGroup)
        var tracks: [[String: Any]] = []
        for (index, option) in mediaSelectionGroup.options.enumerated() {
            let languageCode = option.extendedLanguageTag ?? option.locale?.identifier ?? "unknown"
            var displayName = option.displayName
            if displayName.isEmpty, let locale = option.locale {
                displayName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? languageCode
            }
            if displayName.isEmpty {
                displayName = languageCode
            }
            tracks.append([
                "index": index,
                "language": languageCode,
                "displayName": displayName,
                "isSelected": option == currentSelection
            ])
        }
        npLog("🔊 Total audio tracks found: \(tracks.count)")
        result(tracks)
    }

    /// Selects an alternate audio rendition by index (audible group).
    func handleSetAudioTrack(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let trackInfo = args["track"] as? [String: Any],
              let index = trackInfo["index"] as? Int else {
            result(FlutterError(code: "INVALID_TRACK", message: "Invalid audio track data", details: nil))
            return
        }

        guard let playerItem = player?.currentItem,
              let asset = playerItem.asset as? AVURLAsset,
              let mediaSelectionGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            result(FlutterError(code: "NO_AUDIO_TRACKS", message: "No alternate audio tracks available", details: nil))
            return
        }

        guard index >= 0 && index < mediaSelectionGroup.options.count else {
            result(FlutterError(code: "INVALID_INDEX", message: "Invalid audio track index", details: nil))
            return
        }

        let option = mediaSelectionGroup.options[index]
        playerItem.select(option, in: mediaSelectionGroup)

        let languageCode = option.extendedLanguageTag ?? option.locale?.identifier ?? "unknown"
        var displayName = option.displayName
        if displayName.isEmpty, let locale = option.locale {
            displayName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? languageCode
        }
        if displayName.isEmpty {
            displayName = languageCode
        }
        npLog("🔊 Selected audio track: \(displayName) (\(languageCode))")

        sendEvent("audioTrackChange", data: [
            "index": index,
            "language": languageCode,
            "displayName": displayName,
            "isSelected": true
        ])
        result(nil)
    }

    func handleSetSubtitleTrack(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let trackInfo = args["track"] as? [String: Any],
              let index = trackInfo["index"] as? Int else {
            result(FlutterError(code: "INVALID_TRACK", message: "Invalid subtitle track data", details: nil))
            return
        }

        guard let playerItem = player?.currentItem,
              let asset = playerItem.asset as? AVURLAsset else {
            result(FlutterError(code: "NO_PLAYER", message: "No player item available", details: nil))
            return
        }

        guard let mediaSelectionGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            result(FlutterError(code: "NO_SUBTITLES", message: "No subtitle tracks available", details: nil))
            return
        }

        // Index -1 means disable subtitles
        if index == -1 {
            npLog("📝 Disabling subtitles")
            rememberLegibleSelection(-1)
            playerItem.select(nil, in: mediaSelectionGroup)
            sendEvent("subtitleChange", data: [
                "index": -1,
                "language": "off",
                "displayName": "Off",
                "isSelected": false
            ])
            result(nil)
            return
        }

        // Validate index
        guard index >= 0 && index < mediaSelectionGroup.options.count else {
            result(FlutterError(code: "INVALID_INDEX", message: "Invalid subtitle track index", details: nil))
            return
        }

        // Select the subtitle option
        let option = mediaSelectionGroup.options[index]
        rememberLegibleSelection(index)
        playerItem.select(option, in: mediaSelectionGroup)

        npLog("📝 Selected subtitle track: \(option.displayName) (\(languageCode(of: option)))")

        sendEvent("subtitleChange", data: subtitleChangePayload(index: index, option: option))

        result(nil)
    }

    /// Records Dart's subtitle choice on the shared player so it survives view
    /// (re)attachment, and marks it as already reported so the media-selection
    /// observer doesn't echo it a second time.
    private func rememberLegibleSelection(_ index: Int) {
        lastReportedLegibleIndex = index
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setLegibleSelection(index, for: controllerIdValue)
        }
    }

    /// Reports the item's current legible selection to Dart when it differs
    /// from what was last reported by this view — the selection can change
    /// without a setSubtitleTrack call (AVKit's attach-time media selection,
    /// the native fullscreen controls' CC menu), and the Dart side must
    /// mirror what the player actually renders.
    func reportLegibleSelectionIfChanged() {
        guard let playerItem = player?.currentItem,
              let asset = playerItem.asset as? AVURLAsset,
              let mediaSelectionGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            return
        }

        let selectedOption = playerItem.currentMediaSelection.selectedMediaOption(in: mediaSelectionGroup)
        let selectedIndex = selectedOption.flatMap { mediaSelectionGroup.options.firstIndex(of: $0) } ?? -1

        guard selectedIndex != lastReportedLegibleIndex else { return }
        lastReportedLegibleIndex = selectedIndex

        if let option = selectedOption, selectedIndex >= 0 {
            npLog("📝 Legible selection changed outside setSubtitleTrack: \(option.displayName) (\(selectedIndex))")
            sendEvent("subtitleChange", data: subtitleChangePayload(index: selectedIndex, option: option))
        } else {
            npLog("📝 Legible selection changed outside setSubtitleTrack: off")
            sendEvent("subtitleChange", data: [
                "index": -1,
                "language": "off",
                "displayName": "Off",
                "isSelected": false
            ])
        }
    }

    private func languageCode(of option: AVMediaSelectionOption) -> String {
        option.extendedLanguageTag ?? option.locale?.identifier ?? "unknown"
    }

    private func subtitleChangePayload(index: Int, option: AVMediaSelectionOption) -> [String: Any] {
        let languageCode = languageCode(of: option)
        var displayName = option.displayName

        if displayName.isEmpty, let locale = option.locale {
            displayName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? languageCode
        }

        if displayName.isEmpty {
            displayName = languageCode
        }

        return [
            "index": index,
            "language": languageCode,
            "displayName": displayName,
            "isSelected": true
        ]
    }
}

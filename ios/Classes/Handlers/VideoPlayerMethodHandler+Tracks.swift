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
            // HLS legible renditions resolve after the item reports ready, and a
            // choice made in that window used to be dropped with NO_SUBTITLES —
            // leaving nothing to oppose the rendition the manifest flagged
            // DEFAULT, on this attach and every later one. Record it instead and
            // apply it as soon as the group shows up (onLegibleSelectionChanged
            // and the readyToPlay observer); the index is validated there.
            rememberLegibleSelection(index)
            npLog("📝 Subtitle choice \(index) recorded before the legible group resolved; applying once it does")
            result(nil)
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

    /// Handles a change of the item's legible selection that nobody asked for:
    /// the rendition an HLS manifest flags DEFAULT, or AVKit's media selection
    /// re-run when a view controller attaches. The recorded choice wins, so the
    /// selection is put back and the re-select's own change reports instead.
    ///
    /// The exception is a view showing native playback controls: its CC menu is
    /// the user picking a track, and that must stick. The item's very first
    /// selection after a load is still corrected there — no user could have made
    /// it that early — so a DEFAULT rendition never sneaks past.
    func onLegibleSelectionChanged() {
        onMainQueue { [weak self] in
            self?.handleLegibleSelectionChange()
        }
    }

    /// Applies the recorded subtitle choice to the current item, for callers that
    /// know the legible group may just have resolved.
    func applyRecordedLegibleSelection() {
        onMainQueue { [weak self] in
            guard let self = self, let controllerIdValue = self.controllerId else { return }

            SharedPlayerManager.shared.applyLegibleSelection(for: controllerIdValue)
        }
    }

    /// Runs [work] on the main queue, straight away when already there. KVO
    /// notifications arrive on whichever queue AVFoundation used, while the
    /// recorded selection, this view's report state and the Flutter event sink
    /// are all main-thread only.
    func onMainQueue(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func handleLegibleSelectionChange() {
        let hasUserReachableCCMenu = usesViewControllerDisplay
            && playerViewController.showsPlaybackControls
            && hasCorrectedInitialLegibleSelection

        if !hasUserReachableCCMenu, let controllerIdValue = controllerId {
            hasCorrectedInitialLegibleSelection = true

            if SharedPlayerManager.shared.applyLegibleSelection(for: controllerIdValue) {
                // The re-select fires this observer again; report from that pass.
                return
            }
        }

        reportLegibleSelectionIfChanged()
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

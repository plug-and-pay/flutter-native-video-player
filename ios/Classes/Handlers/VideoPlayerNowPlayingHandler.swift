import MediaPlayer
import AVFoundation

// MARK: - Remote Command Manager
/// Singleton to manage MPRemoteCommandCenter ownership
/// Ensures only one VideoPlayerView owns the remote commands at a time
class RemoteCommandManager {
    static let shared = RemoteCommandManager()

    /// Track which view currently owns the remote commands
    private var currentOwnerViewId: Int64?

    /// Lock to prevent race conditions during ownership transfer
    private let lock = NSLock()

    private init() {}

    /// Check if a specific view is the current owner
    func isOwner(_ viewId: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentOwnerViewId == viewId
    }

    /// Set a new owner for remote commands
    func setOwner(_ viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        currentOwnerViewId = viewId
        npLog("🎛️ Remote command ownership transferred to view \(viewId)")
    }

    /// Clear ownership (e.g., when owner is disposed)
    func clearOwner(_ viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if currentOwnerViewId == viewId {
            currentOwnerViewId = nil
            npLog("🎛️ Remote command ownership cleared from view \(viewId)")
        }
    }

    /// Get the current owner view ID
    func getCurrentOwner() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return currentOwnerViewId
    }

    /// Remove all remote command targets
    func removeAllTargets() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        npLog("🎛️ Removed all remote command targets")
    }

    /// Atomically set owner and remove all targets
    /// This prevents race conditions when multiple views try to register concurrently
    func atomicallySetOwnerAndRemoveTargets(_ viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        currentOwnerViewId = viewId
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        npLog("🎛️ Atomically transferred ownership to view \(viewId) and cleared targets")
    }
}

extension VideoPlayerView {
    /// Sets up the Now Playing info for the Control Center and Lock Screen
    func setupNowPlayingInfo(mediaInfo: [String: Any]) {
        npLog("🎵 setupNowPlayingInfo called for view \(viewId)")
        npLog("   → Media title: \(mediaInfo["title"] ?? "Unknown")")

        // Short-circuit: this fires on every transition to .playing (including
        // after buffering stalls). If this view already owns the remote
        // commands and the metadata is unchanged, a position/rate refresh is
        // all that's needed — skip the audio-session activation, artwork
        // download and remote-command re-registration.
        let infoKey = "\(mediaInfo["title"] ?? "")|\(mediaInfo["subtitle"] ?? "")|\(mediaInfo["artworkUrl"] ?? "")"
        if hasRegisteredRemoteCommands,
           RemoteCommandManager.shared.isOwner(viewId),
           lastAppliedNowPlayingInfoKey == infoKey {
            updateNowPlayingPlaybackTime()
            return
        }
        lastAppliedNowPlayingInfoKey = infoKey

        // CRITICAL: Ensure audio session is active
        // iOS won't show Now Playing info if the audio session is not active
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            npLog("   → Audio session activated successfully")
        } catch {
            npLog("   ⚠️ Failed to activate audio session: \(error.localizedDescription)")
        }

        var nowPlayingInfo: [String: Any] = [:]

        // --- Core metadata ---
        if let title = mediaInfo["title"] as? String {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }

        if let subtitle = mediaInfo["subtitle"] as? String {
            nowPlayingInfo[MPMediaItemPropertyArtist] = subtitle
        }

        if let album = mediaInfo["album"] as? String {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        }

        // --- Playback duration & elapsed time ---
        if let duration = player?.currentItem?.asset.duration {
            let durationSeconds = CMTimeGetSeconds(duration)
            if durationSeconds.isFinite {
                nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = durationSeconds
            }
        }

        if let currentTime = player?.currentTime() {
            let elapsedSeconds = CMTimeGetSeconds(currentTime)
            if elapsedSeconds.isFinite {
                nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedSeconds
            }
        }

        // --- Playback rate (0 = paused, 1 = playing) ---
        let playbackRate = player?.rate ?? 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        npLog("   → Playback rate: \(playbackRate)")

        // --- Commit initial metadata immediately (before artwork loads) ---
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        npLog("   → Now Playing info SET to: \(nowPlayingInfo[MPMediaItemPropertyTitle] ?? "Unknown")")

        // --- Load artwork asynchronously (if available) ---
        if let artworkUrlString = mediaInfo["artworkUrl"] as? String,
           let artworkUrl = URL(string: artworkUrlString) {

            loadArtwork(from: artworkUrl) { [weak self] image in
                guard let self = self,
                      let image = image
                else {
                    return
                }

                var updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                    image
                }
                updatedInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
            }
        }

        // --- Setup remote commands (if not already done) ---
        setupRemoteCommandCenter()
    }

    /// Loads artwork image from URL
    private func loadArtwork(from url: URL, completion: @escaping (UIImage?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let image = UIImage(data: data) else {
                completion(nil)
                return
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
        .resume()
    }

    /// Sets up remote command center for Control Center controls
    /// Only registers if this view should be the owner
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Check if we've already registered handlers for this view
        // If so, skip the registration to avoid clearing and re-adding targets
        // This prevents iOS from clearing Now Playing info
        if hasRegisteredRemoteCommands {
            // We've registered before - check if we're still the owner
            if RemoteCommandManager.shared.isOwner(viewId) {
                npLog("🎛️ View \(viewId) already has remote commands registered and is still owner - skipping re-registration")
                return
            } else {
                // We registered before but lost ownership - take it back without clearing
                npLog("🎛️ View \(viewId) re-taking ownership without clearing targets")
                RemoteCommandManager.shared.setOwner(viewId)
                return
            }
        }

        npLog("🎛️ View \(viewId) registering remote commands for the first time")

        // Atomically take ownership and clear all existing targets
        // This prevents race conditions when multiple views try to register concurrently
        RemoteCommandManager.shared.atomicallySetOwnerAndRemoveTargets(viewId)
        hasRegisteredRemoteCommands = true

        // --- Play ---
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }

            // Only handle if we still own the remote commands
            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                npLog("⚠️ View \(self.viewId) received play command but is not owner")
                return .commandFailed
            }

            // Ensure audio session is active before resuming playback
            // This is critical after interruptions (e.g., phone calls)
            self.prepareAudioSession()

            self.player?.play()
            self.sendEvent("play")
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        // --- Pause ---
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }

            // Only handle if we still own the remote commands
            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                npLog("⚠️ View \(self.viewId) received pause command but is not owner")
                return .commandFailed
            }

            self.player?.pause()
            self.sendEvent("pause")
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        // --- Skip forward/backward ---
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.preferredIntervals = [15]

        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self = self,
                  let skipEvent = event as? MPSkipIntervalCommandEvent,
                  let player = self.player
            else {
                return .commandFailed
            }

            // Only handle if we still own the remote commands
            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                npLog("⚠️ View \(self.viewId) received skip forward command but is not owner")
                return .commandFailed
            }

            let currentTime = player.currentTime()
            let newTime = CMTimeAdd(currentTime, CMTime(seconds: skipEvent.interval, preferredTimescale: 600))
            player.seek(to: newTime)
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self = self,
                  let skipEvent = event as? MPSkipIntervalCommandEvent,
                  let player = self.player
            else {
                return .commandFailed
            }

            // Only handle if we still own the remote commands
            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                npLog("⚠️ View \(self.viewId) received skip backward command but is not owner")
                return .commandFailed
            }

            let currentTime = player.currentTime()
            let newTime = CMTimeSubtract(currentTime, CMTime(seconds: skipEvent.interval, preferredTimescale: 600))
            player.seek(to: max(newTime, .zero))
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        npLog("🎛️ View \(viewId) registered remote command handlers")

        // Verify remote commands are enabled
        npLog("   → Play command enabled: \(commandCenter.playCommand.isEnabled)")
        npLog("   → Pause command enabled: \(commandCenter.pauseCommand.isEnabled)")
        npLog("   → Skip forward enabled: \(commandCenter.skipForwardCommand.isEnabled)")
        npLog("   → Skip backward enabled: \(commandCenter.skipBackwardCommand.isEnabled)")
    }

    /// Updates playback time and rate dynamically (e.g., every second or on state change)
    func updateNowPlayingPlaybackTime() {
        guard let player = player else {
            return
        }

        let isPlaying = player.rate > 0

        // Only allow updates if this view owns the remote commands
        // This prevents multiple views from fighting over Now Playing info
        guard RemoteCommandManager.shared.isOwner(viewId) else {
            if isPlaying {
                npLog("⚠️ View \(viewId) is playing but doesn't own remote commands")
            }
            return
        }

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        let currentTime = player.currentTime()
        let elapsedSeconds = CMTimeGetSeconds(currentTime)
        if elapsedSeconds.isFinite {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedSeconds
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}

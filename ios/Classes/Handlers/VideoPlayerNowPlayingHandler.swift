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
        print("🎛️ Remote command ownership transferred to view \(viewId)")
    }

    /// Clear ownership (e.g., when owner is disposed)
    func clearOwner(_ viewId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if currentOwnerViewId == viewId {
            currentOwnerViewId = nil
            print("🎛️ Remote command ownership cleared from view \(viewId)")
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
        print("🎛️ Removed all remote command targets")
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
        print("🎛️ Atomically transferred ownership to view \(viewId) and cleared targets")
    }
}

extension VideoPlayerView {
    /// Sets up the Now Playing info for the Control Center and Lock Screen
    func setupNowPlayingInfo(mediaInfo: [String: Any]) {
        print("🎵 setupNowPlayingInfo called for view \(viewId)")
        print("   → Media title: \(mediaInfo["title"] ?? "Unknown")")
        print("   → Current Now Playing info before update: \(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String ?? "nil")")

        // CRITICAL: Ensure audio session is active
        // iOS won't show Now Playing info if the audio session is not active
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            print("   → Audio session activated successfully")
        } catch {
            print("   ⚠️ Failed to activate audio session: \(error.localizedDescription)")
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
        print("   → Playback rate: \(playbackRate)")

        // --- Commit initial metadata immediately (before artwork loads) ---
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        print("   → Now Playing info SET to: \(nowPlayingInfo[MPMediaItemPropertyTitle] ?? "Unknown")")

        // Verify immediately
        let immediateCheck = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String ?? "nil"
        print("   → Verified Now Playing info immediately after set: \(immediateCheck)")

        // Check again after a delay to see if something clears it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let delayedCheck = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String ?? "nil"
            print("   → Delayed check (0.5s later): Now Playing info is: \(delayedCheck)")
            if delayedCheck == "nil" {
                print("   ⚠️ WARNING: Now Playing info was CLEARED by something after we set it!")
            }

            // Diagnostic: Check audio session state
            let audioSession = AVAudioSession.sharedInstance()
            print("   → Audio session category: \(audioSession.category.rawValue)")
            print("   → Audio session is active: \(audioSession.isOtherAudioPlaying ? "No (other audio playing)" : "Yes")")

            // Diagnostic: Check remote command center
            let commandCenter = MPRemoteCommandCenter.shared()
            print("   → Play command has targets: \(commandCenter.playCommand.isEnabled)")
            print("   → Pause command has targets: \(commandCenter.pauseCommand.isEnabled)")

            // Diagnostic: Dump all Now Playing info
            if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                print("   → Complete Now Playing info:")
                for (key, value) in info {
                    print("      • \(key): \(value)")
                }
            } else {
                print("   → Now Playing info is completely nil!")
            }
        }

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
                print("🎛️ View \(viewId) already has remote commands registered and is still owner - skipping re-registration")
                return
            } else {
                // We registered before but lost ownership - take it back without clearing
                print("🎛️ View \(viewId) re-taking ownership without clearing targets")
                RemoteCommandManager.shared.setOwner(viewId)
                return
            }
        }

        print("🎛️ View \(viewId) registering remote commands for the first time")

        // Atomically take ownership and clear all existing targets
        // This prevents race conditions when multiple views try to register concurrently
        RemoteCommandManager.shared.atomicallySetOwnerAndRemoveTargets(viewId)
        hasRegisteredRemoteCommands = true

        // --- Play ---
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }

            // Only handle if we still own the remote commands
            guard RemoteCommandManager.shared.isOwner(self.viewId) else {
                print("⚠️ View \(self.viewId) received play command but is not owner")
                return .commandFailed
            }

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
                print("⚠️ View \(self.viewId) received pause command but is not owner")
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
                print("⚠️ View \(self.viewId) received skip forward command but is not owner")
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
                print("⚠️ View \(self.viewId) received skip backward command but is not owner")
                return .commandFailed
            }

            let currentTime = player.currentTime()
            let newTime = CMTimeSubtract(currentTime, CMTime(seconds: skipEvent.interval, preferredTimescale: 600))
            player.seek(to: max(newTime, .zero))
            self.updateNowPlayingPlaybackTime()
            return .success
        }

        print("🎛️ View \(viewId) registered remote command handlers")

        // Verify remote commands are enabled
        print("   → Play command enabled: \(commandCenter.playCommand.isEnabled)")
        print("   → Pause command enabled: \(commandCenter.pauseCommand.isEnabled)")
        print("   → Skip forward enabled: \(commandCenter.skipForwardCommand.isEnabled)")
        print("   → Skip backward enabled: \(commandCenter.skipBackwardCommand.isEnabled)")
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
                print("⚠️ View \(viewId) is playing but doesn't own remote commands")
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

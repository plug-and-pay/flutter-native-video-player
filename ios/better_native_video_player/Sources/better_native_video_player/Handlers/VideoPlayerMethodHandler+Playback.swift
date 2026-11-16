import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer

// Playback commands, disposal, and the periodic time observer.
// Split from VideoPlayerMethodHandler.swift for maintainability;
// all members keep full access to VideoPlayerView state.
extension VideoPlayerView {
    func handlePlay(result: @escaping FlutterResult) {
        // Playing counts as "use" for the total-player LRU cap
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.touchController(controllerIdValue)
        }

        // Prepare audio session, Now Playing info, and PiP before playback
        prepareForPlayback()

        npLog("Playing with speed: \(desiredPlaybackSpeed)")
        player?.play()
        // Apply the desired playback speed
        player?.rate = desiredPlaybackSpeed
        npLog("Applied playback rate: \(player?.rate ?? 0)")
        updateNowPlayingPlaybackTime()
        // Play event will be sent automatically by timeControlStatus observer
        result(nil)
    }

    func handlePause(result: @escaping FlutterResult) {
        player?.pause()
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setPlaybackRequested(false, for: controllerIdValue)
        }
        updateNowPlayingPlaybackTime()

        // DON'T disable automatic PiP on pause anymore
        // The system will handle when to trigger automatic PiP based on playback state
        // Disabling it here causes issues when exiting manual PiP (video might pause during transition)
        // and prevents automatic PiP from working afterward
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId {
                npLog("🎬 Video paused, but keeping automatic PiP state unchanged")
            }
        }

        // Pause event will be sent automatically by timeControlStatus observer
        result(nil)
    }

    func handleSeekTo(call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let args = call.arguments as? [String: Any],
           let milliseconds = args["milliseconds"] as? Int {
            var target = CMTime(value: CMTimeValue(milliseconds), timescale: 1000)
            // Live positions are relative to the seekable (DVR) window, the
            // way timeUpdate reports them.
            if let item = player?.currentItem, let window = liveSeekableWindow(of: item) {
                target = CMTimeAdd(window.start, target)
            }
            player?.seek(to: target) { _ in
                // Texture views must render the seeked frame even while
                // paused (the engine shows the last copied buffer otherwise)
                self.textureRenderer?.expectFrame()
                self.sendEvent("seek", data: ["position": milliseconds])
                self.updateNowPlayingPlaybackTime()
            }
        }
        result(nil)
    }

    /// Seeks a live stream to the end of its seekable window (the live
    /// edge). A no-op for VOD.
    func handleSeekToLiveEdge(result: @escaping FlutterResult) {
        guard let item = player?.currentItem, let window = liveSeekableWindow(of: item) else {
            result(nil)
            return
        }
        let windowMs = Int(CMTimeGetSeconds(CMTimeSubtract(window.end, window.start)) * 1000)
        player?.seek(to: window.end) { _ in
            self.textureRenderer?.expectFrame()
            self.sendEvent("seek", data: ["position": windowMs])
            self.updateNowPlayingPlaybackTime()
        }
        result(nil)
    }

    /// The seekable (DVR) window of a live item, or nil for VOD and for a
    /// live item that has no seekable range yet.
    func liveSeekableWindow(of item: AVPlayerItem) -> (start: CMTime, end: CMTime)? {
        guard item.duration.isIndefinite,
              let first = item.seekableTimeRanges.first?.timeRangeValue,
              let last = item.seekableTimeRanges.last?.timeRangeValue else {
            return nil
        }
        return (first.start, CMTimeRangeGetEnd(last))
    }

    func handleSetVolume(call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let args = call.arguments as? [String: Any],
           let volume = args["volume"] as? Double {
            player?.volume = Float(volume)
        }
        result(nil)
    }

    func handleSetSpeed(call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let args = call.arguments as? [String: Any],
           let speed = args["speed"] as? Double {
            npLog("Setting playback speed to: \(speed)")

            // Store the desired speed
            desiredPlaybackSpeed = Float(speed)

            npLog("Player status: \(player?.timeControlStatus.rawValue ?? -1)")

            // If currently playing, apply the speed immediately
            if player?.timeControlStatus == .playing {
                npLog("Player is playing, applying speed immediately")
                player?.rate = Float(speed)
            } else {
                npLog("Player is not playing, speed will be applied on next play")
            }

            sendEvent("speedChange", data: ["speed": speed])
            result(nil)
        } else {
            result(FlutterError(code: "INVALID_SPEED", message: "Invalid speed value", details: nil))
        }
    }

    func handleSetLooping(call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let args = call.arguments as? [String: Any],
           let looping = args["looping"] as? Bool {
            npLog("Setting looping to: \(looping)")

            // Update the enableLooping property
            enableLooping = looping

            result(nil)
        } else {
            result(FlutterError(code: "INVALID_LOOPING", message: "Invalid looping value", details: nil))
        }
    }

    func handleDispose(result: @escaping FlutterResult) {
        npLog("🗑️ [VideoPlayerMethodHandler] handleDispose called for controllerId: \(String(describing: controllerId))")

        // Pause the player first
        player?.pause()
        npLog("⏸️ [VideoPlayerMethodHandler] Player paused")

        // Clean up DRM handler
        drmHandler?.cleanup()
        drmHandler = nil

        // Clean up remote command ownership (transfer to another view if possible)
        cleanupRemoteCommandOwnership()

        // Remove from shared manager if this is a shared player
        if let controllerId = controllerId {
            npLog("🔄 [VideoPlayerMethodHandler] Calling SharedPlayerManager.removePlayer for controllerId: \(controllerId)")
            SharedPlayerManager.shared.removePlayer(for: controllerId)
            npLog("✅ [VideoPlayerMethodHandler] SharedPlayerManager.removePlayer completed for controllerId: \(controllerId)")
        } else {
            npLog("⚠️ [VideoPlayerMethodHandler] No controllerId - cannot remove from SharedPlayerManager")
        }

        // Clear local player reference (observers first, while they can still
        // be removed from the player they were added to)
        prepareForPlayerEviction()
        player = nil
        npLog("🧹 [VideoPlayerMethodHandler] Local player reference cleared")

        sendEvent("stopped")
        result(nil)
    }

    /// Sets up periodic time observer to update Now Playing elapsed time
    func setupPeriodicTimeObserver() {
        // Remove existing observer if any
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        // Emit timeUpdate events at the configured interval while playing
        let intervalSeconds = Double(timeUpdateIntervalMs) / 1000.0
        let interval = CMTime(seconds: intervalSeconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        // Resync Now Playing roughly every 5 seconds regardless of interval
        let nowPlayingResyncEvery = max(1, Int((5000.0 / Double(timeUpdateIntervalMs)).rounded()))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self = self, let player = self.player, let currentItem = player.currentItem else { return }

            // Resync Now Playing elapsed time only every ~5s: the system
            // extrapolates position from the playback rate, and the
            // play/pause/seek paths push immediate updates. Writing the
            // MPNowPlayingInfoCenter dictionary is an XPC call — doing it
            // every tick per view is wasted work.
            self.nowPlayingResyncTick += 1
            if self.nowPlayingResyncTick >= nowPlayingResyncEvery {
                self.nowPlayingResyncTick = 0
                self.updateNowPlayingPlaybackTime()
            }

            // Get current playback position
            let currentTime = player.currentTime()
            var positionSeconds = CMTimeGetSeconds(currentTime)
            var durationSeconds: Double = 0.0

            // For HLS live streams (indefinite duration), use seekableTimeRanges to get duration
            // Regular VOD content (including VOD HLS) uses the item's duration
            let isLive = currentItem.duration.isIndefinite
            // Live times are reported relative to the seekable window start
            var windowStartSeconds = 0.0
            if isLive {
                // Live stream - use seekable ranges
                if let window = self.liveSeekableWindow(of: currentItem) {
                    let rangeStart = window.start
                    windowStartSeconds = CMTimeGetSeconds(rangeStart)

                    // Duration is the full seekable window
                    durationSeconds = CMTimeGetSeconds(CMTimeSubtract(window.end, rangeStart))

                    // Position is relative to the start of the seekable window
                    positionSeconds = CMTimeGetSeconds(CMTimeSubtract(currentTime, rangeStart))

                    // Ensure position is within valid range
                    if positionSeconds < 0 {
                        positionSeconds = 0
                    } else if positionSeconds > durationSeconds {
                        positionSeconds = durationSeconds
                    }
                }
            } else {
                // Regular VOD content (including VOD HLS) - use item duration
                let duration = currentItem.duration
                durationSeconds = CMTimeGetSeconds(duration)
            }

            // Get buffered position
            var bufferedSeconds = 0.0
            let loadedRanges = currentItem.loadedTimeRanges
            if !loadedRanges.isEmpty {
                // Get the most recent buffered range
                let bufferedRange = loadedRanges.last!.timeRangeValue
                let bufferedEnd = CMTimeAdd(bufferedRange.start, bufferedRange.duration)
                bufferedSeconds = max(0, CMTimeGetSeconds(bufferedEnd) - windowStartSeconds)
            }

            // Check if currently buffering
            let isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate

            // Only send event if values are valid (not NaN or Infinity)
            if positionSeconds.isFinite && !positionSeconds.isNaN &&
               durationSeconds.isFinite && !durationSeconds.isNaN && durationSeconds > 0 {
                let position = Int(positionSeconds * 1000) // milliseconds
                let totalDuration = Int(durationSeconds * 1000) // milliseconds
                let bufferedPosition = Int(bufferedSeconds * 1000) // milliseconds

                self.sendEvent("timeUpdate", data: [
                    "position": position,
                    "duration": totalDuration,
                    "bufferedPosition": bufferedPosition,
                    "isBuffering": isBuffering,
                    "isLive": isLive
                ])
            }
        }
    }
}

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
            let seconds = Double(milliseconds) / 1000.0
            player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000)) { _ in
                // Texture views must render the seeked frame even while
                // paused (the engine shows the last copied buffer otherwise)
                self.textureRenderer?.expectFrame()
                self.sendEvent("seek", data: ["position": milliseconds])
                self.updateNowPlayingPlaybackTime()
            }
        }
        result(nil)
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

        // Clear local player reference
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
            if currentItem.duration.isIndefinite {
                // Live stream - use seekable ranges
                let seekableRanges = currentItem.seekableTimeRanges
                if !seekableRanges.isEmpty {
                    // HLS live stream - calculate duration from seekable range
                    let firstRange = seekableRanges.first!.timeRangeValue
                    let lastRange = seekableRanges.last!.timeRangeValue

                    let rangeStart = firstRange.start
                    let rangeEnd = CMTimeAdd(lastRange.start, lastRange.duration)

                    // Duration is the full seekable window
                    durationSeconds = CMTimeGetSeconds(CMTimeSubtract(rangeEnd, rangeStart))

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
                bufferedSeconds = CMTimeGetSeconds(bufferedEnd)
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
                    "isBuffering": isBuffering
                ])
            }
        }
    }
}

import AVFoundation
import Foundation

extension VideoPlayerView {
    func addObservers(to item: AVPlayerItem) {
        // Called once per load: drop the previous item's registrations first
        // so removal at teardown stays balanced (KVO throws on removing a
        // never-registered observer, and double-adds deliver twice).
        removeItemObservers()

        item.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
        item.addObserver(self, forKeyPath: "playbackBufferEmpty", options: [.new], context: nil)
        item.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: [.new], context: nil)
        // Report the video's display size so the Dart subtitle overlay can pin
        // captions to the video's content rect (platform views don't emit this
        // the way the texture renderer does).
        item.addObserver(self, forKeyPath: "presentationSize", options: [.new, .initial], context: nil)
        observedItem = item

        // Player-level observers are registered once per view, not per load
        if !hasPlayerStateObservers, let player = player {
            // Observe player's timeControlStatus to track play/pause state changes
            player.addObserver(self, forKeyPath: "timeControlStatus", options: [.new, .old], context: nil)

            // Observe AirPlay connection status
            player.addObserver(self, forKeyPath: "externalPlaybackActive", options: [.new, .initial], context: nil)
            hasPlayerStateObservers = true
        }

        // Observe audio route changes to detect AirPlay device changes
        // (remove first so re-loads don't stack duplicate deliveries)
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemFailedToPlay),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item
        )
    }

    /// Removes the KVO registrations made on [observedItem], if any.
    func removeItemObservers() {
        guard let item = observedItem else { return }
        item.removeObserver(self, forKeyPath: "status")
        item.removeObserver(self, forKeyPath: "playbackBufferEmpty")
        item.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
        item.removeObserver(self, forKeyPath: "presentationSize")
        NotificationCenter.default.removeObserver(
            self,
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item
        )
        observedItem = nil
    }

    /// Removes the player-level KVO registrations, if registered.
    func removePlayerStateObservers() {
        guard hasPlayerStateObservers else { return }
        player?.removeObserver(self, forKeyPath: "timeControlStatus")
        player?.removeObserver(self, forKeyPath: "externalPlaybackActive")
        hasPlayerStateObservers = false
    }

    public override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        // Handle AVPlayerItem observations
        if let item = object as? AVPlayerItem {
            switch keyPath {
            case "status":
                switch item.status {
                case .readyToPlay:
                    // Only send isInitialized for new players, not for shared players
                    // Shared players already sent their state in the init
                    if !isSharedPlayer {
                        sendEvent("isInitialized")
                    }
                case .failed:
                    sendEvent("error", data: ["message": item.error?.localizedDescription ?? "Unknown"])
                default: break
                }
            case "playbackBufferEmpty":
                // Only send buffering event when buffer is empty AND playback has stalled
                // This prevents false buffering events when the player has enough buffer to continue
                if item.isPlaybackBufferEmpty, let player = player {
                    // Only send buffering if the player is waiting to play (actually stalled)
                    // or if we're seeking (reasonForWaitingToPlay is not nil)
                    if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                        sendEvent("buffering")
                    }
                }
            case "playbackLikelyToKeepUp":
                // Send loading event when buffer is ready, then restore playback state
                // This is important for seeking while paused - user needs to know buffering is done
                if item.isPlaybackLikelyToKeepUp {
                    sendEvent("loading")

                    // Restore the playback state after buffering completes
                    // This tells the UI whether the video is playing or paused
                    if let player = player {
                        if player.rate > 0 && player.timeControlStatus == .playing {
                            sendEvent("play")
                        } else if player.timeControlStatus == .paused && player.reasonForWaitingToPlay == nil {
                            sendEvent("pause")
                        }
                    }
                }
            case "presentationSize":
                // Display size (rotation already applied by AVFoundation), so the
                // Dart overlay can letterbox-match captions. Mirror the texture
                // renderer's payload shape.
                let size = item.presentationSize
                if size.width > 0 && size.height > 0 {
                    sendEvent("videoSize", data: [
                        "width": Double(size.width),
                        "height": Double(size.height),
                        "rotationCorrection": 0,
                    ])
                }
            default: break
            }
        }

        // Handle AVPlayer observations
        if let observedPlayer = object as? AVPlayer, observedPlayer == player {
            switch keyPath {
            case "timeControlStatus":
                guard let player = player else { return }

                // The texture frame pump only runs while playing (plus
                // one-shot expectFrame renders while paused)
                textureRenderer?.setRunning(player.timeControlStatus == .playing)

                switch player.timeControlStatus {
                case .playing:
                    // ALWAYS update Now Playing info when playback starts
                    // This ensures media controls show the correct info whether in normal view or PiP
                    var mediaInfo = currentMediaInfo

                    // Fallback: Try to retrieve from SharedPlayerManager if not available locally
                    if mediaInfo == nil, let controllerIdValue = controllerId {
                        mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
                        if mediaInfo != nil {
                            npLog("📱 [Observer] Retrieved media info from SharedPlayerManager for playback")
                            currentMediaInfo = mediaInfo // Update local copy
                        }
                    }

                    if let mediaInfo = mediaInfo {
                        npLog("📱 [Observer] Player started playing, updating Now Playing info for: \(mediaInfo["title"] ?? "Unknown")")
                        setupNowPlayingInfo(mediaInfo: mediaInfo)
                    } else {
                        npLog("⚠️ [Observer] No media info available when playing - media controls may not show correctly")
                    }

                    // Enable automatic PiP when playback starts (even from native controls)
                    // This ensures auto PiP works whether the user taps Flutter controls or native controls
                    if #available(iOS 14.2, *) {
                        if let controllerIdValue = controllerId {
                            // Check if there's already a primary view for this controller
                            let hasPrimaryView = SharedPlayerManager.shared.getPrimaryViewId(for: controllerIdValue) != nil

                            if !hasPrimaryView {
                                // No primary view set yet - this means the user started playback via native controls
                                // Set THIS view as primary
                                SharedPlayerManager.shared.setPrimaryView(viewId, for: controllerIdValue)
                                npLog("📱 [Observer] No primary view set, making this view (ViewId \(viewId)) primary for controller \(controllerIdValue)")
                            }

                            // Check if THIS view is the primary view for this controller
                            if SharedPlayerManager.shared.isPrimaryView(viewId, for: controllerIdValue) {
                                // For shared players, check the shared settings instead of instance variable
                                // This ensures the second view uses the same PiP settings as the first view
                                let shouldEnableAutoPiP: Bool
                                if let sharedSettings = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue) {
                                    shouldEnableAutoPiP = sharedSettings.canStartPictureInPictureAutomatically
                                    npLog("📱 [Observer] Using shared PiP settings for controller \(controllerIdValue): \(shouldEnableAutoPiP)")
                                } else {
                                    shouldEnableAutoPiP = canStartPictureInPictureAutomatically
                                    npLog("📱 [Observer] Using instance PiP settings: \(shouldEnableAutoPiP)")
                                }

                                if shouldEnableAutoPiP {
                                    npLog("📱 [Observer] Enabling automatic PiP for controller \(controllerIdValue) (triggered by native controls)")
                                    SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)

                                    // Ensure media info is set again after enabling PiP
                                    // This guarantees media controls work correctly in PiP mode
                                    if let mediaInfo = currentMediaInfo {
                                        setupNowPlayingInfo(mediaInfo: mediaInfo)
                                        npLog("✅ [Observer] Media info updated for PiP mode")
                                    }
                                } else {
                                    npLog("📱 [Observer] Automatic PiP not enabled (canStartPictureInPictureAutomatically = false)")
                                }
                            } else {
                                npLog("📱 [Observer] Skipping auto PiP enable - this view (ViewId \(viewId)) is not primary for controller \(controllerIdValue)")
                            }
                        }
                    }

                    sendEvent("play")
                case .paused:
                    // Only send pause if not waiting to play (buffering)
                    // This prevents sending pause when seeking to unbuffered position
                    if player.reasonForWaitingToPlay == nil {
                        // DON'T disable automatic PiP on pause
                        // The system will handle when to trigger automatic PiP based on playback state
                        // Disabling it here causes issues:
                        // 1. When exiting manual PiP (video might pause during transition)
                        // 2. Prevents automatic PiP from working afterward
                        // The automatic PiP system already checks if video is playing before triggering
                        if #available(iOS 14.2, *) {
                            if let controllerIdValue = controllerId {
                                npLog("📱 [Observer] Video paused, but keeping automatic PiP state unchanged for controller \(controllerIdValue)")
                            }
                        }

                        sendEvent("pause")
                    }
                case .waitingToPlayAtSpecifiedRate:
                    // Player is buffering, event already sent by playbackBufferEmpty observer
                    break
                @unknown default:
                    break
                }
            case "externalPlaybackActive":
                guard let player = player else { return }
                let isActive = player.isExternalPlaybackActive

                if isActive {
                    // When AirPlay connects, try to get device name with multiple retry attempts
                    npLog("🎯 AVPlayer externalPlaybackActive changed to: \(isActive)")

                    // The receiver (TV) renders beyond the inline view's size:
                    // lift the viewport quality cap while external playback is on
                    liftViewportCap()

                    // Try to get device name immediately
                    let deviceName = getAirPlayDeviceName()
                    npLog("📱 Initial device name check: \(deviceName ?? "nil")")

                    // Send initial event (might have deviceName or might be nil)
                    var eventData: [String: Any] = ["isConnected": isActive, "isConnecting": false]
                    if let deviceName = deviceName {
                        eventData["deviceName"] = deviceName
                    }

                    // Send through per-view event channel (legacy)
                    sendEvent("airPlayConnectionChanged", data: eventData)

                    // Send through controller-level event channel (persists when views disposed)
                    if let controllerIdValue = controllerId {
                        SharedPlayerManager.shared.sendControllerEvent(
                            "airPlayConnectionChanged",
                            data: eventData,
                            for: controllerIdValue
                        )
                    }

                    // If device name is nil, retry multiple times with increasing delays
                    if deviceName == nil {
                        npLog("⏳ Device name not available yet, starting retry sequence...")
                        retryGetAirPlayDeviceName(attempt: 1, maxAttempts: 4)
                    }
                } else {
                    // Disconnected from AirPlay
                    npLog("🎯 AVPlayer externalPlaybackActive changed to: \(isActive)")

                    // Back to local rendering: restore the viewport quality cap
                    applyViewportCapIfAppropriate()

                    var eventData: [String: Any] = ["isConnected": false, "isConnecting": false]

                    // Send through per-view event channel (legacy)
                    sendEvent("airPlayConnectionChanged", data: eventData)

                    // Send through controller-level event channel (persists when views disposed)
                    if let controllerIdValue = controllerId {
                        SharedPlayerManager.shared.sendControllerEvent(
                            "airPlayConnectionChanged",
                            data: eventData,
                            for: controllerIdValue
                        )
                    }
                }
            default: break
            }
        }

        // Note: AirPlay availability changes are observed by the app-wide
        // route detector in SharedPlayerManager, which fans the event out to
        // all per-view and controller-level channels.
    }

    @objc func playerItemFailedToPlay(notification: Notification) {
        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            sendEvent("error", data: ["message": error.localizedDescription])
        } else {
            sendEvent("error", data: ["message": "Unknown error"])
        }
    }

    @objc func videoDidEnd() {
        if enableLooping {
            // For smooth looping, seek to beginning and continue playing
            player?.seek(to: .zero) { [weak self] finished in
                if finished {
                    // Continue playing for seamless loop
                    self?.player?.play()
                }
            }
            // Don't send completed event when looping to match Android behavior
            // (Android with REPEAT_MODE_ONE doesn't reach STATE_ENDED)
        } else {
            // Reset video to the beginning and pause
            player?.seek(to: .zero)
            player?.pause()
            sendEvent("completed")
        }
    }

    // MARK: - AirPlay Route Detection

    /// Gets the name of the currently connected AirPlay device
    func getAirPlayDeviceName() -> String? {
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute

        npLog("🔍 Checking audio route for AirPlay device")
        npLog("   - Route description: \(currentRoute)")
        npLog("   - Output count: \(currentRoute.outputs.count)")
        npLog("   - Input count: \(currentRoute.inputs.count)")

        // Look for AirPlay output in the current route
        for (index, output) in currentRoute.outputs.enumerated() {
            npLog("   - Output[\(index)]: type=\(output.portType.rawValue), name='\(output.portName)', uid=\(output.uid)")

            // AirPlay outputs have port type .airPlay
            if output.portType == .airPlay {
                npLog("✅ Found AirPlay device at output[\(index)]: '\(output.portName)'")
                return output.portName
            }
        }

        // Log all output types we found for debugging
        let outputTypes = currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", ")
        npLog("⚠️ No AirPlay device found. Current output types: [\(outputTypes)]")

        // Also check if video is being sent via AirPlay but audio route hasn't updated
        if let player = player, player.isExternalPlaybackActive {
            npLog("ℹ️ Note: Player shows externalPlaybackActive=true but no AirPlay in audio route")
            npLog("   This may indicate video-only AirPlay where audio route lags behind")
        }

        return nil
    }

    /// Retries getting the AirPlay device name with exponential backoff
    ///
    /// This function recursively retries getting the device name because iOS sometimes
    /// takes time to update the audio route when AirPlay video streaming starts.
    ///
    /// - Parameters:
    ///   - attempt: Current attempt number (1-based)
    ///   - maxAttempts: Maximum number of retry attempts
    func retryGetAirPlayDeviceName(attempt: Int, maxAttempts: Int) {
        guard attempt <= maxAttempts else {
            npLog("❌ Failed to get device name after \(maxAttempts) attempts")
            return
        }

        // Calculate delay with exponential backoff: 0.1s, 0.3s, 0.6s, 1.0s
        let delay: Double
        switch attempt {
        case 1: delay = 0.1
        case 2: delay = 0.3
        case 3: delay = 0.6
        default: delay = 1.0
        }

        npLog("🔄 Retry attempt \(attempt)/\(maxAttempts) - waiting \(delay)s...")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }

            let deviceName = self.getAirPlayDeviceName()
            npLog("🔍 Attempt \(attempt) result: \(deviceName ?? "still nil")")

            if let deviceName = deviceName {
                // Success! Send event with device name
                npLog("✅ Device name found on attempt \(attempt): \(deviceName)")
                var eventData: [String: Any] = ["isConnected": true, "isConnecting": false]
                eventData["deviceName"] = deviceName

                // Send through per-view event channel (legacy)
                self.sendEvent("airPlayConnectionChanged", data: eventData)

                // Send through controller-level event channel (persists when views disposed)
                if let controllerIdValue = self.controllerId {
                    SharedPlayerManager.shared.sendControllerEvent(
                        "airPlayConnectionChanged",
                        data: eventData,
                        for: controllerIdValue
                    )
                }
            } else if attempt < maxAttempts {
                // Try again
                self.retryGetAirPlayDeviceName(attempt: attempt + 1, maxAttempts: maxAttempts)
            } else {
                // Exhausted all retries
                npLog("⚠️ Device name still not available after \(maxAttempts) attempts")
                // Send event without device name - the Dart caching layer will handle it
                var eventData: [String: Any] = ["isConnected": true, "isConnecting": false]

                // Send through per-view event channel (legacy)
                self.sendEvent("airPlayConnectionChanged", data: eventData)

                // Send through controller-level event channel (persists when views disposed)
                if let controllerIdValue = self.controllerId {
                    SharedPlayerManager.shared.sendControllerEvent(
                        "airPlayConnectionChanged",
                        data: eventData,
                        for: controllerIdValue
                    )
                }
            }
        }
    }

    /// Handles audio route changes to detect AirPlay device changes
    @objc func handleAudioRouteChange(notification: Notification) {
        npLog("🔔 Audio route change notification received")

        // Log the reason for the route change
        if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt {
            let reasonString: String
            switch AVAudioSession.RouteChangeReason(rawValue: reason) {
            case .newDeviceAvailable: reasonString = "NewDeviceAvailable"
            case .oldDeviceUnavailable: reasonString = "OldDeviceUnavailable"
            case .categoryChange: reasonString = "CategoryChange"
            case .override: reasonString = "Override"
            case .wakeFromSleep: reasonString = "WakeFromSleep"
            case .noSuitableRouteForCategory: reasonString = "NoSuitableRouteForCategory"
            case .routeConfigurationChange: reasonString = "RouteConfigurationChange"
            default: reasonString = "Unknown(\(reason))"
            }
            npLog("   - Reason: \(reasonString)")
        }

        guard let player = player else { return }

        let deviceName = getAirPlayDeviceName()
        let isPlayerActive = player.isExternalPlaybackActive

        // Use same logic as initial state check:
        // We're connected if EITHER the player is using AirPlay OR device is in audio route
        let isSystemActive = deviceName != nil
        let isConnected = isPlayerActive || isSystemActive

        // Determine if we're in a connecting state:
        // - AirPlay device is present in audio route (systemActive)
        // - But player hasn't started streaming yet (!playerActive)
        // - AND we consider this "connected" at system level (isConnected)
        let isConnecting = isSystemActive && !isPlayerActive && isConnected

        // Only send events for AirPlay-related changes
        if deviceName != nil || isPlayerActive {
            npLog("📡 AirPlay state change detected:")
            npLog("   - Device: \(deviceName ?? "none")")
            npLog("   - Player active: \(isPlayerActive)")
            npLog("   - System active: \(isSystemActive)")
            npLog("   - Connected: \(isConnected)")
            npLog("   - Connecting: \(isConnecting)")

            var eventData: [String: Any] = [
                "isConnected": isConnected,
                "isConnecting": isConnecting
            ]
            if let deviceName = deviceName {
                eventData["deviceName"] = deviceName
            }

            // Send through per-view event channel (legacy)
            sendEvent("airPlayConnectionChanged", data: eventData)

            // Send through controller-level event channel (persists when views disposed)
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.sendControllerEvent(
                    "airPlayConnectionChanged",
                    data: eventData,
                    for: controllerIdValue
                )
            }
        } else {
            npLog("   - No AirPlay-related changes (device=nil, playerActive=false)")
        }
    }
}
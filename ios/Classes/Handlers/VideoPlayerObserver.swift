import AVFoundation
import Foundation

extension VideoPlayerView {
    func addObservers(to item: AVPlayerItem) {
        item.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
        item.addObserver(self, forKeyPath: "playbackBufferEmpty", options: [.new], context: nil)
        item.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: [.new], context: nil)

        // Observe player's timeControlStatus to track play/pause state changes
        player?.addObserver(self, forKeyPath: "timeControlStatus", options: [.new, .old], context: nil)

        // Observe AirPlay connection status
        player?.addObserver(self, forKeyPath: "externalPlaybackActive", options: [.new, .initial], context: nil)

        // Observe audio route changes to detect AirPlay device changes
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
            default: break
            }
        }

        // Handle AVPlayer observations
        if let observedPlayer = object as? AVPlayer, observedPlayer == player {
            switch keyPath {
            case "timeControlStatus":
                guard let player = player else { return }

                switch player.timeControlStatus {
                case .playing:
                    // ALWAYS update Now Playing info when playback starts
                    // This ensures media controls show the correct info whether in normal view or PiP
                    var mediaInfo = currentMediaInfo

                    // Fallback: Try to retrieve from SharedPlayerManager if not available locally
                    if mediaInfo == nil, let controllerIdValue = controllerId {
                        mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
                        if mediaInfo != nil {
                            print("📱 [Observer] Retrieved media info from SharedPlayerManager for playback")
                            currentMediaInfo = mediaInfo // Update local copy
                        }
                    }

                    if let mediaInfo = mediaInfo {
                        print("📱 [Observer] Player started playing, updating Now Playing info for: \(mediaInfo["title"] ?? "Unknown")")
                        setupNowPlayingInfo(mediaInfo: mediaInfo)
                    } else {
                        print("⚠️ [Observer] No media info available when playing - media controls may not show correctly")
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
                                print("📱 [Observer] No primary view set, making this view (ViewId \(viewId)) primary for controller \(controllerIdValue)")
                            }

                            // Check if THIS view is the primary view for this controller
                            if SharedPlayerManager.shared.isPrimaryView(viewId, for: controllerIdValue) {
                                // For shared players, check the shared settings instead of instance variable
                                // This ensures the second view uses the same PiP settings as the first view
                                let shouldEnableAutoPiP: Bool
                                if let sharedSettings = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue) {
                                    shouldEnableAutoPiP = sharedSettings.canStartPictureInPictureAutomatically
                                    print("📱 [Observer] Using shared PiP settings for controller \(controllerIdValue): \(shouldEnableAutoPiP)")
                                } else {
                                    shouldEnableAutoPiP = canStartPictureInPictureAutomatically
                                    print("📱 [Observer] Using instance PiP settings: \(shouldEnableAutoPiP)")
                                }

                                if shouldEnableAutoPiP {
                                    print("📱 [Observer] Enabling automatic PiP for controller \(controllerIdValue) (triggered by native controls)")
                                    SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)

                                    // Ensure media info is set again after enabling PiP
                                    // This guarantees media controls work correctly in PiP mode
                                    if let mediaInfo = currentMediaInfo {
                                        setupNowPlayingInfo(mediaInfo: mediaInfo)
                                        print("✅ [Observer] Media info updated for PiP mode")
                                    }
                                } else {
                                    print("📱 [Observer] Automatic PiP not enabled (canStartPictureInPictureAutomatically = false)")
                                }
                            } else {
                                print("📱 [Observer] Skipping auto PiP enable - this view (ViewId \(viewId)) is not primary for controller \(controllerIdValue)")
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
                                print("📱 [Observer] Video paused, but keeping automatic PiP state unchanged for controller \(controllerIdValue)")
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
                let deviceName = isActive ? getAirPlayDeviceName() : nil
                print("AVPlayer externalPlaybackActive changed to: \(isActive), device: \(deviceName ?? "none")")
                var eventData: [String: Any] = ["isConnected": isActive, "isConnecting": false]
                if let deviceName = deviceName {
                    eventData["deviceName"] = deviceName
                }
                sendEvent("airPlayConnectionChanged", data: eventData)
            default: break
            }
        }

        // Handle AVRouteDetector observations
        if #available(iOS 11.0, *) {
            if let detector = object as? AVRouteDetector, detector == routeDetector {
                switch keyPath {
                case "multipleRoutesDetected":
                    let isAvailable = routeDetector?.multipleRoutesDetected ?? false
                    print("AVRouteDetector multipleRoutesDetected changed to: \(isAvailable)")
                    sendEvent("airPlayAvailabilityChanged", data: ["isAvailable": isAvailable])
                default: break
                }
            }
        }
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

    /// Sets up AVRouteDetector to monitor AirPlay availability
    @available(iOS 11.0, *)
    func setupAirPlayRouteDetector() {
        print("Setting up AirPlay route detector")
        routeDetector = AVRouteDetector()
        routeDetector?.isRouteDetectionEnabled = true

        // Observe changes to multipleRoutesDetected
        routeDetector?.addObserver(
            self,
            forKeyPath: "multipleRoutesDetected",
            options: [.new, .initial],
            context: nil
        )

        print("AirPlay route detector setup complete, multipleRoutesDetected: \(routeDetector?.multipleRoutesDetected ?? false)")
    }

    /// Observes AirPlay route availability changes
    @objc func handleAirPlayRouteChange() {
        if #available(iOS 11.0, *) {
            if let isAvailable = routeDetector?.multipleRoutesDetected {
                sendEvent("airPlayAvailabilityChanged", data: ["isAvailable": isAvailable])
            }
        }
    }

    /// Gets the name of the currently connected AirPlay device
    func getAirPlayDeviceName() -> String? {
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute

        // Look for AirPlay output in the current route
        for output in currentRoute.outputs {
            // AirPlay outputs have port type .airPlay
            if output.portType == .airPlay {
                return output.portName
            }
        }

        return nil
    }

    /// Handles audio route changes to detect AirPlay device changes
    @objc func handleAudioRouteChange(notification: Notification) {
        guard let player = player else { return }

        let deviceName = getAirPlayDeviceName()
        let isConnected = player.isExternalPlaybackActive

        // Determine if we're in a connecting state:
        // - AirPlay device is present in audio route
        // - But video playback hasn't started yet (isExternalPlaybackActive = false)
        let isConnecting = deviceName != nil && !isConnected

        // Only send events for AirPlay-related changes
        if deviceName != nil || isConnected {
            print("Audio route changed - device: \(deviceName ?? "none"), connected: \(isConnected), connecting: \(isConnecting)")

            var eventData: [String: Any] = [
                "isConnected": isConnected,
                "isConnecting": isConnecting
            ]
            if let deviceName = deviceName {
                eventData["deviceName"] = deviceName
            }
            sendEvent("airPlayConnectionChanged", data: eventData)
        }
    }
}
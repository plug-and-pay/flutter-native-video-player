import Flutter
import AVFoundation
import AVKit
import MediaPlayer

// Add reference to VideoPlayerView in the extension scope
extension VideoPlayerView {

    func handleLoad(call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("handleLoad called with arguments: \(String(describing: call.arguments))")

        guard let arguments = call.arguments as? [String: Any],
              let urlString = arguments["url"] as? String,
              let url = URL(string: urlString)
        else {
            let error = FlutterError(code: "INVALID_URL", message: "Invalid URL provided", details: nil)
            result(error)
            return
        }

        let autoPlay = arguments["autoPlay"] as? Bool ?? false
        let headers = arguments["headers"] as? [String: String]
        let mediaInfo = arguments["mediaInfo"] as? [String: Any]

        // Store media info for Now Playing
        if let mediaInfo = mediaInfo {
            currentMediaInfo = mediaInfo
            print("📱 Stored media info during load: \(mediaInfo["title"] ?? "Unknown")")

            // Also store in SharedPlayerManager to persist across view recreations
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setMediaInfo(for: controllerIdValue, mediaInfo: mediaInfo)
            }
        } else {
            print("⚠️ No media info provided during load")
        }

        sendEvent("loading")

        // Determine if this is likely an HLS stream
        let isHls = isHlsUrl(url)
        print("🎬 Loading video - URL: \(urlString), isHLS: \(isHls)")

        // Fetch qualities (async) only for HLS streams
        if isHls {
            VideoPlayerQualityHandler.fetchHLSQualities(from: url) { [weak self] qualities in
            guard let self = self else { return }

            self.qualityLevels = qualities

            // Convert to Flutter format
            var result: [[String: Any]] = []

            // Add auto quality option
            result.append([
                "label": "Auto",
                "url": qualities.first?.url ?? "",
                "isAuto": true
            ])

            // Add all available qualities
            result.append(contentsOf: qualities.map { quality in
                [
                    "label": quality.label,
                    "url": quality.url,
                    "bitrate": quality.bitrate,
                    "width": Int(quality.resolution.width),
                    "height": Int(quality.resolution.height),
                    "isAuto": false
                ]
            })

            // Send qualities to Flutter
            self.availableQualities = result

            // Store in SharedPlayerManager if this is a shared player
            if let controllerIdValue = self.controllerId {
                SharedPlayerManager.shared.setQualities(
                    for: controllerIdValue,
                    qualities: result,
                    qualityLevels: qualities
                )
            }
            }
        } else {
            print("🎬 Skipping quality fetch for non-HLS content")
        }

        // --- Build player item ---
        let playerItem: AVPlayerItem
        if let headers = headers {
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            playerItem = AVPlayerItem(asset: asset)
        } else {
            let asset = AVURLAsset(url: url)
            playerItem = AVPlayerItem(asset: asset)
        }

        // Replace current item immediately - don't wait for HDR configuration
        // This allows the video to start loading right away
        player?.replaceCurrentItem(with: playerItem)

        // --- Configure HDR settings asynchronously (doesn't block video loading) ---
        // Only apply color space correction if HDR is explicitly disabled AND we detect this might be HDR content
        // For most standard videos, the default handling is fine
        if !self.enableHDR {
            // Note: We skip the video composition entirely to avoid performance issues
            // The video composition causes significant overhead during loading, especially for network assets
            // Most videos will display correctly without it
            print("🎨 HDR disabled - skipping video composition for better performance")
            
            // Original HDR correction code - disabled for performance
            // Only re-enable this if you encounter actual HDR color issues
            print("🎨 HDR disabled - will apply SDR color space via videoComposition asynchronously")
            if let asset = playerItem.asset as? AVURLAsset {
                // Load ALL properties that AVMutableVideoComposition(propertiesOf:) will need
                // This prevents synchronous property access on the main thread
                let assetKeys = ["tracks", "duration"]
                asset.loadValuesAsynchronously(forKeys: assetKeys) { [weak self, weak playerItem] in
                    guard let self = self, let playerItem = playerItem else { return }

                    // Check if asset properties loaded successfully
                    for key in assetKeys {
                        var error: NSError?
                        let status = asset.statusOfValue(forKey: key, error: &error)
                        if status != .loaded {
                            print("⚠️ Failed to load asset property '\(key)': \(error?.localizedDescription ?? "unknown error")")
                            return
                        }
                    }

                    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                        print("⚠️ No video track found, skipping video composition")
                        return
                    }

                    // Load ALL track properties that AVMutableVideoComposition(propertiesOf:) will need
                    let trackPropertyKeys = ["naturalSize", "preferredTransform", "nominalFrameRate", "enabled", "segments"]
                    videoTrack.loadValuesAsynchronously(forKeys: trackPropertyKeys) {
                        // Check if track properties loaded successfully
                        for key in trackPropertyKeys {
                            var error: NSError?
                            let status = videoTrack.statusOfValue(forKey: key, error: &error)
                            if status != .loaded {
                                print("⚠️ Failed to load track property '\(key)': \(error?.localizedDescription ?? "unknown error")")
                                // Continue anyway - some properties might be optional
                            }
                        }

                        let naturalSize = videoTrack.naturalSize

                        // Create video composition on background thread to avoid blocking main thread
                        // AVMutableVideoComposition(propertiesOf:) can be expensive, especially for network assets
                        DispatchQueue.global(qos: .utility).async {
                            // Now that all properties are loaded, create the composition off the main thread
                            let videoComposition = AVMutableVideoComposition(propertiesOf: asset)

                            // Ensure renderSize is set (required for videoComposition)
                            if videoComposition.renderSize.width <= 0 || videoComposition.renderSize.height <= 0 {
                                videoComposition.renderSize = naturalSize
                            }

                            // Use Rec.709 color space for HD SDR content
                            videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
                            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
                            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

                            // Apply the completed video composition on main thread
                            DispatchQueue.main.async {
                                playerItem.videoComposition = videoComposition
                                print("✅ Applied SDR color space (Rec.709) to video composition with size: \(videoComposition.renderSize)")
                            }
                        }
                    }
                }
            }
            
        } else {
            print("🎨 HDR enabled - allowing native HDR playback")
        }

        // --- Set up observers for buffer status and player state ---
        addObservers(to: playerItem)

        // --- Set up periodic time observer for Now Playing elapsed time updates ---
        setupPeriodicTimeObserver()

        // --- Set up audio session ---
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

        // --- Listen for end of playback ---
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(videoDidEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        // --- Observe status (wait for ready) ---
        var statusObserver: NSKeyValueObservation?
        statusObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self = self else {
                return
            }

            switch item.status {
            case .readyToPlay:
                print("🎬 Video ready to play")

                // Get duration
                let duration = item.duration
                let durationSeconds = CMTimeGetSeconds(duration)

                // Send Flutter event with duration (only if valid)
                if durationSeconds.isFinite && !durationSeconds.isNaN {
                    let totalDuration = Int(durationSeconds * 1000) // milliseconds
                    self.sendEvent("loaded", data: [
                        "duration": totalDuration
                    ])
                } else {
                    self.sendEvent("loaded")
                }

                // Set up PiP controller if available
                // Note: We need to get the player layer from the AVPlayerViewController
                // Check PiP support and send availability
                // Note: Do NOT create custom AVPictureInPictureController here
                // as it interferes with automatic PiP from AVPlayerViewController
                if #available(iOS 14.0, *) {
                    if AVPictureInPictureController.isPictureInPictureSupported() {
                        print("🎬 PiP is supported on this device")
                        // Send availability immediately
                        self.sendEvent("pipAvailabilityChanged", data: ["isAvailable": true])
                    } else {
                        print("🎬 PiP is NOT supported on this device")
                        self.sendEvent("pipAvailabilityChanged", data: ["isAvailable": false])
                    }
                } else {
                    // iOS version too old for PiP
                    self.sendEvent("pipAvailabilityChanged", data: ["isAvailable": false])
                }

                // Auto play if requested
                if autoPlay {
                    self.player?.play()
                    // Play event will be sent automatically by timeControlStatus observer
                }

                // Release observer (avoid leaks)
                statusObserver?.invalidate()

                result(nil)

            case .failed:
                let error = item.error?.localizedDescription ?? "Unknown error"
                result(FlutterError(code: "LOAD_ERROR", message: error, details: nil))

            case .unknown:
                break

            @unknown default:
                break
            }
        }
    }


    func handlePlay(result: @escaping FlutterResult) {
        try? AVAudioSession.sharedInstance().setActive(true)

        // ALWAYS set media item on play to ensure this player has control
        // This is critical for both normal playback and PiP mode
        var mediaInfo = currentMediaInfo

        // Fallback: Try to retrieve from SharedPlayerManager if not available locally
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                print("📱 Retrieved media info from SharedPlayerManager for play")
                currentMediaInfo = mediaInfo // Update local copy
            }
        }

        if let mediaInfo = mediaInfo {
            let title = mediaInfo["title"] ?? "Unknown"
            print("📱 Setting Now Playing info for: \(title)")
            setupNowPlayingInfo(mediaInfo: mediaInfo)

            // Verify it was set correctly
            if let nowPlayingTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String {
                print("✅  Now Playing info confirmed: \(nowPlayingTitle)")
            } else {
                print("⚠️  Failed to set Now Playing info")
            }
        } else {
            print("⚠️  No media info available when playing - media controls will not work correctly")
            print("   → currentMediaInfo was nil and SharedPlayerManager has no cached info for controller \(controllerId ?? -1)")
        }
        
        // Mark this view as the primary (active) view for this controller
        // This ensures automatic PiP will be enabled on THIS view, not other views
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setPrimaryView(viewId, for: controllerIdValue)
        }
        
        // Enable automatic PiP for this controller and disable for all others
        // Only if automatic PiP was requested in creation params
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId {
                // Only enable if the user requested it in creation params
                let shouldEnableAutoPiP = canStartPictureInPictureAutomatically
                if shouldEnableAutoPiP {
                    SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                } else {
                    print("🎬 Automatic PiP not enabled (canStartPictureInPictureAutomatically = false)")
                }
            }
        }

        print("Playing with speed: \(desiredPlaybackSpeed)")
        player?.play()
        // Apply the desired playback speed
        player?.rate = desiredPlaybackSpeed
        print("Applied playback rate: \(player?.rate ?? 0)")
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
                print("🎬 Video paused, but keeping automatic PiP state unchanged")
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
            print("Setting playback speed to: \(speed)")

            // Store the desired speed
            desiredPlaybackSpeed = Float(speed)

            print("Player status: \(player?.timeControlStatus.rawValue ?? -1)")

            // If currently playing, apply the speed immediately
            if player?.timeControlStatus == .playing {
                print("Player is playing, applying speed immediately")
                player?.rate = Float(speed)
            } else {
                print("Player is not playing, speed will be applied on next play")
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
            print("Setting looping to: \(looping)")

            // Update the enableLooping property
            enableLooping = looping

            result(nil)
        } else {
            result(FlutterError(code: "INVALID_LOOPING", message: "Invalid looping value", details: nil))
        }
    }

    // Auto-quality handling
    
    func handleSetQuality(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let qualityInfo = args["quality"] as? [String: Any] else {
            result(FlutterError(code: "INVALID_QUALITY", message: "Invalid quality data", details: nil))
            return
        }
        
        let isAuto = qualityInfo["isAuto"] as? Bool ?? false
        isAutoQuality = isAuto
        
        if isAuto {
            // Start with the middle quality for auto mode
            let midIndex = max(0, qualityLevels.count / 2 - 1)
            guard midIndex < qualityLevels.count else {
                result(FlutterError(code: "NO_QUALITIES", message: "No qualities available", details: nil))
                return
            }
            
            let initialQuality = qualityLevels[midIndex]
            switchToQuality(initialQuality, result: result)
            
            // Enable quality monitoring
            startQualityMonitoring()
        } else {
            guard let urlString = qualityInfo["url"] as? String,
                  let url = URL(string: urlString) else {
                result(FlutterError(code: "INVALID_URL", message: "Invalid quality URL", details: nil))
                return
            }
            
            sendEvent("loading")
            
            // Store current playback state and position
            let wasPlaying = player?.rate != 0
            let currentTime = player?.currentTime() ?? CMTime.zero
            
            let newItem = AVPlayerItem(url: url)
            player?.replaceCurrentItem(with: newItem)
            player?.seek(to: currentTime)
            
            // Only resume playback if it was playing before
            if wasPlaying {
                player?.play()
            }
            
            sendEvent("qualityChange", data: [
                "url": urlString,
                "label": qualityInfo["label"] as? String ?? "",
                "isAuto": false
            ])
            result(nil)
        }
    }
    
    private func startQualityMonitoring() {
        // Remove existing observer if any
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        
        // Monitor playback every second for auto-quality
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.checkAndAdjustQuality()
        }
    }
    
    private func checkAndAdjustQuality() {
        guard isAutoQuality,
              !qualityLevels.isEmpty,
              CACurrentMediaTime() - lastBitrateCheck >= bitrateCheckInterval else {
            return
        }
        
        lastBitrateCheck = CACurrentMediaTime()
        
        // Get current playback statistics
        let loadedTimeRanges = player?.currentItem?.loadedTimeRanges ?? []
        let currentTime = player?.currentTime() ?? CMTime.zero
        
        // Calculate buffer health
        var bufferHealth: TimeInterval = 0
        for range in loadedTimeRanges {
            let timeRange = range.timeRangeValue
            if timeRange.start <= currentTime {
                bufferHealth += timeRange.duration.seconds
            }
        }
        
        // Get current quality index
        guard let urlAsset = player?.currentItem?.asset as? AVURLAsset,
              let currentUrl = urlAsset.url.absoluteString as String?,
              let currentIndex = qualityLevels.firstIndex(where: { $0.url == currentUrl }) else {
            return
        }
        
        // Adjust quality based on buffer health
        var targetIndex = currentIndex
        
        if bufferHealth < 3.0 && currentIndex > 0 {
            // Buffer is low, decrease quality
            targetIndex = currentIndex - 1
        } else if bufferHealth > 10.0 && currentIndex < qualityLevels.count - 1 {
            // Buffer is healthy, try increasing quality
            targetIndex = currentIndex + 1
        }
        
        if targetIndex != currentIndex {
            switchToQuality(qualityLevels[targetIndex], result: nil)
        }
    }
    
    private func switchToQuality(_ quality: VideoPlayer.QualityLevel, result: FlutterResult?) {
        guard let url = URL(string: quality.url) else {
            result?(FlutterError(code: "INVALID_URL", message: "Invalid quality URL", details: nil))
            return
        }
        
        sendEvent("loading")
        
        let wasPlaying = player?.rate != 0
        let currentTime = player?.currentTime() ?? CMTime.zero
        
        let newItem = AVPlayerItem(url: url)
        player?.replaceCurrentItem(with: newItem)
        player?.seek(to: currentTime)
        
        if wasPlaying {
            player?.play()
        }
        
        sendEvent("qualityChange", data: [
            "url": quality.url,
            "label": quality.label,
            "isAuto": isAutoQuality
        ])
        
        result?(nil)
    }

    func handleSetShowNativeControls(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let show = arguments["show"] as? Bool else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
        }

        // Set controls visibility for embedded player
        playerViewController.showsPlaybackControls = show

        // Also set for fullscreen player if it exists
        if let fullscreenVC = fullscreenPlayerViewController {
            fullscreenVC.showsPlaybackControls = show
        }

        result(nil)
    }

    func handleIsAirPlayAvailable(result: @escaping FlutterResult) {
        // Check if AirPlay is supported on this device
        // AVRoutePickerView requires iOS 11.0+
        if #available(iOS 11.0, *) {
            // AirPlay is available on iOS 11.0+
            // Note: This checks if the device supports AirPlay, not if AirPlay devices
            // are currently available on the network (which changes dynamically)
            result(true)
        } else {
            // AirPlay requires iOS 11.0+
            result(false)
        }
    }

    func handleShowAirPlayPicker(result: @escaping FlutterResult) {
        // Check iOS version - AVRoutePickerView requires iOS 11.0+
        guard #available(iOS 11.0, *) else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "AirPlay picker requires iOS 11.0+", details: nil))
            return
        }

        // Find the root view controller
        guard let rootViewController = UIApplication.shared.keyWindow?.rootViewController else {
            result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "Could not find root view controller", details: nil))
            return
        }

        // Create an AVRoutePickerView
        let routePickerView = AVRoutePickerView()
        routePickerView.frame = CGRect(x: 0, y: 0, width: 0, height: 0)
        routePickerView.isHidden = true

        // Add it temporarily to the view hierarchy
        rootViewController.view.addSubview(routePickerView)

        // Find the button inside the route picker view and simulate a tap
        DispatchQueue.main.async {
            for subview in routePickerView.subviews {
                if let button = subview as? UIButton {
                    button.sendActions(for: .touchUpInside)
                    break
                }
            }

            // Clean up - remove the route picker after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                routePickerView.removeFromSuperview()
            }

            result(nil)
        }
    }

    func handleDispose(result: @escaping FlutterResult) {
        print("🗑️ [VideoPlayerMethodHandler] handleDispose called for controllerId: \(String(describing: controllerId))")

        // Pause the player first
        player?.pause()
        print("⏸️ [VideoPlayerMethodHandler] Player paused")

        // Clean up remote command ownership (transfer to another view if possible)
        cleanupRemoteCommandOwnership()

        // Remove from shared manager if this is a shared player
        if let controllerId = controllerId {
            print("🔄 [VideoPlayerMethodHandler] Calling SharedPlayerManager.removePlayer for controllerId: \(controllerId)")
            SharedPlayerManager.shared.removePlayer(for: controllerId)
            print("✅ [VideoPlayerMethodHandler] SharedPlayerManager.removePlayer completed for controllerId: \(controllerId)")
        } else {
            print("⚠️ [VideoPlayerMethodHandler] No controllerId - cannot remove from SharedPlayerManager")
        }

        // Clear local player reference
        player = nil
        print("🧹 [VideoPlayerMethodHandler] Local player reference cleared")

        sendEvent("stopped")
        result(nil)
    }

    func handleEnterFullScreen(result: @escaping FlutterResult) {
        if let viewController = UIApplication.shared.keyWindow?.rootViewController {
            // Create a NEW player view controller for fullscreen
            // This prevents the embedded view from being removed from Flutter's view hierarchy
            let fullscreenPlayerViewController = AVPlayerViewController()
            fullscreenPlayerViewController.player = player
            fullscreenPlayerViewController.showsPlaybackControls = true
            fullscreenPlayerViewController.delegate = self

            // Store reference to dismiss later
            self.fullscreenPlayerViewController = fullscreenPlayerViewController

            viewController.present(fullscreenPlayerViewController, animated: true) {
                // Send event after animation completes
                self.sendEvent("fullscreenChange", data: ["isFullscreen": true])
                result(nil)
            }
        } else {
            result(FlutterError(code: "FULLSCREEN_ERROR", message: "Could not present fullscreen player", details: nil))
        }
    }

    func handleExitFullScreen(result: @escaping FlutterResult) {
        // Store the playback state before dismissing
        let wasPlaying = player?.rate != 0
        
        // Dismiss the fullscreen player view controller if it exists
        if let fullscreenVC = fullscreenPlayerViewController {
            fullscreenVC.dismiss(animated: true) {
                // Clear the reference
                self.fullscreenPlayerViewController = nil
                
                // Resume playback if it was playing before
                if wasPlaying {
                    self.player?.play()
                }

                self.sendEvent("fullscreenChange", data: ["isFullscreen": false])
                result(nil)
            }
        } else {
            // Fallback: dismiss the embedded player controller (shouldn't happen)
            playerViewController.dismiss(animated: true) {
                // Resume playback if it was playing before
                if wasPlaying {
                    self.player?.play()
                }
                
                self.sendEvent("fullscreenChange", data: ["isFullscreen": false])
                result(nil)
            }
        }
    }

    func handleIsPictureInPictureAvailable(result: @escaping FlutterResult) {
        if #available(iOS 14.0, *) {
            // Check if PiP is supported on this device
            let isPipSupported = AVPictureInPictureController.isPictureInPictureSupported()
            result(isPipSupported)
        } else {
            // PiP requires iOS 14.0+
            result(false)
        }
    }

    func handleEnterPictureInPicture(result: @escaping FlutterResult) {
        if #available(iOS 14.0, *) {
            // Check if video is loaded and ready
            guard let player = player, let currentItem = player.currentItem else {
                print("❌ No video loaded for PiP")
                result(FlutterError(code: "NO_VIDEO", message: "No video loaded.", details: nil))
                return
            }
            
            guard currentItem.status == .readyToPlay else {
                print("❌ Video not ready for PiP")
                result(FlutterError(code: "NOT_READY", message: "Video is not ready to play.", details: nil))
                return
            }
            
            // Check if PiP is supported on device
            guard AVPictureInPictureController.isPictureInPictureSupported() else {
                print("❌ PiP not supported on this device")
                result(FlutterError(code: "NOT_SUPPORTED", message: "Picture-in-Picture is not supported on this device.", details: nil))
                return
            }

            print("🎬 Starting manual PiP")

            // Mark manual PiP as active for this controller
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: true)
            }

            // CRITICAL: Temporarily disable AVPlayerViewController's PiP while using custom controller
            // This prevents the AVPlayerViewController from starting its own PiP simultaneously
            // NOTE: We do this AFTER the checks, so it doesn't interfere with the next manual PiP attempt
            playerViewController.allowsPictureInPicturePlayback = false
            print("   → Temporarily disabled AVPlayerViewController PiP during manual start")

            // Also disable automatic inline PiP
            if #available(iOS 14.2, *) {
                playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
                print("   → Temporarily disabled automatic inline PiP during manual start")
            }

            // Get or create the PiP controller for this player layer
            // Reuse existing controller if available, or create new one
            if pipController == nil {
                if let playerLayer = findPlayerLayer() {
                    pipController = try? AVPictureInPictureController(playerLayer: playerLayer)
                    pipController?.delegate = self
                    print("✅ Created PiP controller for manual entry")
                } else {
                    print("❌ Could not find player layer")
                    if let controllerIdValue = controllerId {
                        SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
                    }
                    result(FlutterError(code: "NO_LAYER", message: "Could not find player layer", details: nil))
                    return
                }
            }

            // Start PiP using the controller
            // Wait for the controller to be ready with retries
            var attempt = 0
            let maxAttempts = 3

            func tryStartPip() {
                attempt += 1
                print("🎬 Attempt \(attempt)/\(maxAttempts) to start PiP")

                if let pipController = pipController {
                    print("   → isPictureInPicturePossible: \(pipController.isPictureInPicturePossible)")

                    if pipController.isPictureInPicturePossible {
                        print("🎬 Starting manual PiP now")
                        pipController.startPictureInPicture()
                        result(true)
                    } else if attempt < maxAttempts {
                        // Retry after a short delay
                        print("   → PiP not ready yet, retrying in 0.2s...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            guard self != nil else { return }
                            tryStartPip()
                        }
                    } else {
                        print("❌ PiP not possible after \(maxAttempts) attempts")
                        if let controllerIdValue = controllerId {
                            SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
                            // Re-enable AVPlayerViewController PiP since we're not starting
                            playerViewController.allowsPictureInPicturePlayback = true
                        }
                        result(FlutterError(code: "PIP_NOT_POSSIBLE", message: "Picture-in-Picture is not possible at this time. Make sure the video is playing and loaded.", details: nil))
                    }
                } else {
                    print("❌ PiP controller is nil")
                    result(FlutterError(code: "NO_CONTROLLER", message: "PiP controller is not available", details: nil))
                }
            }

            // Start the first attempt after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard self != nil else {
                    result(FlutterError(code: "DISPOSED", message: "View was disposed", details: nil))
                    return
                }
                tryStartPip()
            }
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "PiP requires iOS 14.0+", details: nil))
        }
    }
    
    /// Finds the AVPlayerLayer in the view hierarchy
    private func findPlayerLayer() -> AVPlayerLayer? {
        // Get the player layer from the AVPlayerViewController's view
        if let playerView = playerViewController.view {
            return findPlayerLayerInView(playerView)
        }
        return nil
    }
    
    /// Recursively searches for AVPlayerLayer in view hierarchy
    private func findPlayerLayerInView(_ view: UIView) -> AVPlayerLayer? {
        // Check if this view's layer is an AVPlayerLayer
        if let playerLayer = view.layer as? AVPlayerLayer {
            return playerLayer
        }
        
        // Check sublayers
        if let sublayers = view.layer.sublayers {
            for sublayer in sublayers {
                if let playerLayer = sublayer as? AVPlayerLayer {
                    return playerLayer
                }
            }
        }
        
        // Recursively check subviews
        for subview in view.subviews {
            if let playerLayer = findPlayerLayerInView(subview) {
                return playerLayer
            }
        }
        
        return nil
    }
    

    func handleExitPictureInPicture(result: @escaping FlutterResult) {
        if #available(iOS 14.0, *) {
            // First check this view's pipController
            if let pipController = pipController {
                if pipController.isPictureInPictureActive {
                    print("🛑 Stopping PiP from current view")
                    pipController.stopPictureInPicture()
                    result(true)
                    return
                }
            }

            // If this view doesn't have an active PiP, check other views for the same controller
            // This handles the case where user navigated away from the detail screen back to list
            if let controllerIdValue = controllerId {
                print("🔍 Checking other views for controller \(controllerIdValue) to stop PiP")
                let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)

                for view in allViews {
                    if let otherPipController = view.pipController,
                       otherPipController.isPictureInPictureActive {
                        print("🛑 Found active PiP on view \(view.viewId), stopping it")
                        otherPipController.stopPictureInPicture()
                        result(true)
                        return
                    }
                }
            }

            // No active PiP found on any view
            print("⚠️ No active PiP found for this controller")
            result(false)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "PiP not supported on this iOS version", details: nil))
        }
    }

    /// Sets up periodic time observer to update Now Playing elapsed time
    func setupPeriodicTimeObserver() {
        // Remove existing observer if any
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        // Update Now Playing info every second
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self = self, let player = self.player else { return }

            // Update Now Playing info
            self.updateNowPlayingPlaybackTime()

            // Send timeUpdate event to Flutter
            let currentTime = player.currentTime()
            let duration = player.currentItem?.duration ?? CMTime.zero

            let positionSeconds = CMTimeGetSeconds(currentTime)
            let durationSeconds = CMTimeGetSeconds(duration)

            // Get buffered position
            var bufferedSeconds = 0.0
            if let timeRanges = player.currentItem?.loadedTimeRanges, !timeRanges.isEmpty {
                // Get the most recent buffered range
                let bufferedRange = timeRanges.last!.timeRangeValue
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

    /// Determines if a URL is an HLS stream
    /// Checks for .m3u8 extension or common HLS patterns
    private func isHlsUrl(_ url: URL) -> Bool {
        let urlString = url.absoluteString.lowercased()

        // Check for .m3u8 extension (most reliable indicator)
        if urlString.contains(".m3u8") {
            return true
        }

        // Check for /hls/ as a path segment (not substring to avoid false positives like "english")
        if urlString.range(of: "/hls/", options: .regularExpression) != nil {
            return true
        }

        // Check for manifest in path
        if urlString.contains("manifest.m3u8") {
            return true
        }

        return false
    }
}

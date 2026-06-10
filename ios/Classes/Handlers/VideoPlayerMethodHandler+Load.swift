import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer

// Loading: asset/URL resolution, player item creation, DRM, buffer tuning.
// Split from VideoPlayerMethodHandler.swift for maintainability;
// all members keep full access to VideoPlayerView state.
extension VideoPlayerView {
    func handleLoad(call: FlutterMethodCall, result: @escaping FlutterResult) {
        npLog("handleLoad called with arguments: \(String(describing: call.arguments))")

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
        let drmConfig = arguments["drmConfig"] as? [String: Any]
        let startAtMs = arguments["startAtMs"] as? Int ?? 0

        // Store media info for Now Playing
        if let mediaInfo = mediaInfo {
            currentMediaInfo = mediaInfo
            npLog("📱 Stored media info during load: \(mediaInfo["title"] ?? "Unknown")")

            // Also store in SharedPlayerManager to persist across view recreations
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setMediaInfo(for: controllerIdValue, mediaInfo: mediaInfo)
            }
        } else {
            npLog("⚠️ No media info provided during load")
        }

        sendEvent("loading")

        // Determine if this is likely an HLS stream
        let isHls = isHlsUrl(url)
        npLog("🎬 Loading video - URL: \(urlString), isHLS: \(isHls)")

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

            // Send qualityChange event to notify Flutter that qualities are loaded
            if !result.isEmpty, let defaultQuality = result.first {
                self.sendEvent("qualityChange", data: [
                    "url": defaultQuality["url"] as? String ?? "",
                    "label": defaultQuality["label"] as? String ?? "Auto",
                    "isAuto": defaultQuality["isAuto"] as? Bool ?? true
                ])
                npLog("🎬 Sent qualityChange event with \(result.count) available qualities")
            }
            }
        } else {
            npLog("🎬 Skipping quality fetch for non-HLS content")
        }

        // --- Build player item ---
        let playerItem: AVPlayerItem
        let asset: AVURLAsset
        
        // Create asset with headers if provided
        if let headers = headers {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: url)
        }
        
        // Setup DRM if configured
        if let drmConfig = drmConfig {
            // Clean up existing DRM handler if any
            self.drmHandler?.cleanup()
            
            let drmHandler = VideoPlayerDrmHandler(drmConfig: drmConfig)
            self.drmHandler = drmHandler
            
            // Setup DRM asynchronously
            drmHandler.setupDRM(asset: asset) { [weak self] success, error in
                if let error = error {
                    npLog("🔐 DRM: Setup failed: \(error.localizedDescription)")
                    // Continue with playback even if DRM setup fails
                    // The player will attempt to play and may fail later
                } else {
                    npLog("🔐 DRM: Setup completed successfully")
                }
            }
        }
        
        playerItem = AVPlayerItem(asset: asset)

        // Optional buffer tuning from NativeVideoPlayerConfig (0/default =
        // AVPlayer decides automatically)
        if let preferredForwardBufferDuration = preferredForwardBufferDuration {
            playerItem.preferredForwardBufferDuration = preferredForwardBufferDuration
        }
        player?.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling

        // Viewport-based quality cap (only the default adaptive load path;
        // manual quality switches create their own uncapped items)
        if qualityForViewport, let size = viewportCapSize,
           fullscreenPlayerViewController == nil,
           !(player?.isExternalPlaybackActive ?? false) {
            playerItem.preferredMaximumResolution = size
        }

        // Resume position: seek the item BEFORE attaching it, so loading
        // starts at the target position and the first rendered frame is
        // already there (no visible jump after playback starts).
        if startAtMs > 0 {
            let target = CMTime(value: CMTimeValue(startAtMs), timescale: 1000)
            playerItem.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
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
            npLog("🎨 HDR disabled - skipping video composition for better performance")
            
            // Original HDR correction code - disabled for performance
            // Only re-enable this if you encounter actual HDR color issues
            npLog("🎨 HDR disabled - will apply SDR color space via videoComposition asynchronously")
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
                            npLog("⚠️ Failed to load asset property '\(key)': \(error?.localizedDescription ?? "unknown error")")
                            return
                        }
                    }

                    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                        npLog("⚠️ No video track found, skipping video composition")
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
                                npLog("⚠️ Failed to load track property '\(key)': \(error?.localizedDescription ?? "unknown error")")
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
                                npLog("✅ Applied SDR color space (Rec.709) to video composition with size: \(videoComposition.renderSize)")
                            }
                        }
                    }
                }
            }
            
        } else {
            npLog("🎨 HDR enabled - allowing native HDR playback")
        }

        // --- Set up observers for buffer status and player state ---
        addObservers(to: playerItem)

        // --- Set up periodic time observer for Now Playing elapsed time updates ---
        setupPeriodicTimeObserver()

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
                npLog("🎬 Video ready to play")

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
                        npLog("🎬 PiP is supported on this device")
                        // Send availability immediately
                        self.sendEvent("pipAvailabilityChanged", data: ["isAvailable": true])
                    } else {
                        npLog("🎬 PiP is NOT supported on this device")
                        self.sendEvent("pipAvailabilityChanged", data: ["isAvailable": false])
                    }
                } else {
                    // iOS version too old for PiP
                    self.sendEvent("pipAvailabilityChanged", data: ["isAvailable": false])
                }

                // Auto play if requested
                if autoPlay {
                    // Prepare audio session, Now Playing info, and PiP before playback
                    self.prepareForPlayback()

                    // Start playback
                    npLog("Auto-playing with speed: \(self.desiredPlaybackSpeed)")
                    self.player?.play()
                    self.player?.rate = self.desiredPlaybackSpeed
                    self.updateNowPlayingPlaybackTime()
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

    /// Prepares the player for playback by setting up audio session, Now Playing info, and PiP
    /// This should be called before starting playback to ensure proper background audio and lock screen controls
    func prepareForPlayback() {
        // CRITICAL: Activate audio session BEFORE calling player.play()
        // This ensures audio continues when the screen locks
        prepareAudioSession()

        // ALWAYS set media item on play to ensure this player has control
        // This is critical for both normal playback and PiP mode
        var mediaInfo = currentMediaInfo

        // Fallback: Try to retrieve from SharedPlayerManager if not available locally
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                npLog("📱 Retrieved media info from SharedPlayerManager for play")
                currentMediaInfo = mediaInfo // Update local copy
            }
        }

        if let mediaInfo = mediaInfo {
            let title = mediaInfo["title"] ?? "Unknown"
            npLog("📱 Setting Now Playing info for: \(title)")
            setupNowPlayingInfo(mediaInfo: mediaInfo)

            // Verify it was set correctly
            if let nowPlayingTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String {
                npLog("✅  Now Playing info confirmed: \(nowPlayingTitle)")
            } else {
                npLog("⚠️  Failed to set Now Playing info")
            }
        } else {
            npLog("⚠️  No media info available when playing - media controls will not work correctly")
            npLog("   → currentMediaInfo was nil and SharedPlayerManager has no cached info for controller \(controllerId ?? -1)")
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
                    npLog("🎬 Automatic PiP not enabled (canStartPictureInPictureAutomatically = false)")
                }
            }
        }
    }

    /// Determines if a URL is an HLS stream
    /// Checks for .m3u8 extension or common HLS patterns
    func isHlsUrl(_ url: URL) -> Bool {
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

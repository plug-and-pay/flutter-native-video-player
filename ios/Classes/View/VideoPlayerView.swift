import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer
import QuartzCore

// MARK: - Main Video Player View

@objc public class VideoPlayerView: NSObject, FlutterPlatformView, FlutterStreamHandler {
    var playerViewController: AVPlayerViewController
    var player: AVPlayer?
    private var methodChannel: FlutterMethodChannel
    private var channelName: String
    var eventSink: FlutterEventSink?
    var availableQualities: [[String: Any]] = []
    var qualityLevels: [VideoPlayer.QualityLevel] = []
    var isAutoQuality = false
    var lastBitrateCheck: TimeInterval = 0
    let bitrateCheckInterval: TimeInterval = 5.0 // Check every 5 seconds
    var controllerId: Int?
    var pipController: AVPictureInPictureController?

    // Track if PiP is currently active (for both automatic and manual PiP)
    var isPipCurrentlyActive: Bool = false

    // Track if we're currently in the middle of a PiP restoration
    // This is true from when restoreUserInterfaceForPictureInPictureStop is called
    // until after didStopPictureInPicture completes
    var isPipRestoringUI: Bool = false

    // Track if we've already registered remote command handlers
    // This prevents re-registering and clearing targets unnecessarily
    var hasRegisteredRemoteCommands: Bool = false

    /// Force re-registration of remote commands
    /// Call this when you know the targets might have been removed externally
    func forceReregisterRemoteCommands() {
        print("🔄 Checking if need to re-register remote commands for view \(viewId)")

        // Only force re-registration if we don't already own the commands
        // or if the commands aren't properly set up
        let commandCenter = MPRemoteCommandCenter.shared()
        let hasTargets = commandCenter.playCommand.isEnabled && commandCenter.pauseCommand.isEnabled

        if RemoteCommandManager.shared.isOwner(viewId) && hasTargets {
            print("   → View \(viewId) already owns commands and they're active - skipping re-registration")
            // Just restore Now Playing info without touching remote commands
            if let mediaInfo = currentMediaInfo {
                setupNowPlayingInfo(mediaInfo: mediaInfo)
            }
            return
        }

        print("   → Re-registering remote commands for view \(viewId)")
        hasRegisteredRemoteCommands = false
        if let mediaInfo = currentMediaInfo {
            setupNowPlayingInfo(mediaInfo: mediaInfo)
        }
    }

    // Store the platform view ID for registration
    var viewId: Int64 = 0
    
    // Store whether automatic PiP was requested in creation params
    var canStartPictureInPictureAutomatically: Bool = true

    // Separate player view controller for fullscreen (prevents removing embedded view)
    var fullscreenPlayerViewController: AVPlayerViewController?

    // Store media info for Now Playing
    var currentMediaInfo: [String: Any]?
    var timeObserver: Any?

    // Track if this is a shared player (to avoid sending duplicate initialization events)
    var isSharedPlayer: Bool = false

    // AirPlay route detector
    var routeDetector: AVRouteDetector?

    // Store desired playback speed
    var desiredPlaybackSpeed: Float = 1.0

    // Store HDR setting
    var enableHDR: Bool = false

    // Store looping setting
    var enableLooping: Bool = false

    public init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        print("Creating VideoPlayerView with id: \(viewId)")
        self.viewId = viewId
        channelName = "native_video_player_\(viewId)"
        methodChannel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: messenger
        )

        // Always create a new AVPlayerViewController for each platform view
        playerViewController = AVPlayerViewController()

        // Extract controller ID from args to get shared player
        if let args = args as? [String: Any],
           let controllerIdValue = args["controllerId"] as? Int {
            controllerId = controllerIdValue

            // Get or create shared player (but new view controller each time)
            let (sharedPlayer, alreadyExisted) = SharedPlayerManager.shared.getOrCreatePlayer(for: controllerIdValue)
            player = sharedPlayer
            isSharedPlayer = alreadyExisted

            if alreadyExisted {
                print("Using existing shared player for controller ID: \(controllerIdValue)")
            } else {
                print("Creating new shared player for controller ID: \(controllerIdValue)")
            }
        } else {
            // Fallback: create new instances if no controller ID provided
            print("No controller ID provided, creating new player")
            player = AVPlayer()
        }

        super.init()

        // Assign the shared player to this new view controller
        playerViewController.player = player

        // Configure playback controls
        let showControls = (args as? [String: Any])?["showNativeControls"] as? Bool ?? true
        playerViewController.showsPlaybackControls = showControls
        playerViewController.delegate = self

        // Disable automatic Now Playing updates - we'll handle it manually
        playerViewController.updatesNowPlayingInfoCenter = false

        // Extract configuration from Flutter args
        if let args = args as? [String: Any] {
            // PiP configuration from args
            let argsAllowsPiP = args["allowsPictureInPicture"] as? Bool ?? true
            let argsCanStartAutomatically = args["canStartPictureInPictureAutomatically"] as? Bool ?? true
            let argsShowNativeControls = args["showNativeControls"] as? Bool ?? true

            // HDR configuration from args
            enableHDR = args["enableHDR"] as? Bool ?? false

            // Looping configuration from args
            enableLooping = args["enableLooping"] as? Bool ?? false

            // For shared players, try to get PiP settings from SharedPlayerManager
            // This ensures PiP settings persist across all views using the same controller
            if let controllerIdValue = controllerId {
                if let sharedSettings = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue) {
                    // Use existing shared settings
                    self.canStartPictureInPictureAutomatically = sharedSettings.canStartPictureInPictureAutomatically
                    playerViewController.allowsPictureInPicturePlayback = sharedSettings.allowsPictureInPicture
                    print("✅ Using shared PiP settings for controller \(controllerIdValue) - allows: \(sharedSettings.allowsPictureInPicture), autoStart: \(sharedSettings.canStartPictureInPictureAutomatically)")
                } else {
                    // First view for this controller - store the settings
                    self.canStartPictureInPictureAutomatically = argsCanStartAutomatically
                    playerViewController.allowsPictureInPicturePlayback = argsAllowsPiP
                    SharedPlayerManager.shared.setPipSettings(
                        for: controllerIdValue,
                        allowsPictureInPicture: argsAllowsPiP,
                        canStartPictureInPictureAutomatically: argsCanStartAutomatically,
                        showNativeControls: argsShowNativeControls
                    )
                    print("✅ Stored new PiP settings for controller \(controllerIdValue) - allows: \(argsAllowsPiP), autoStart: \(argsCanStartAutomatically)")
                }
            } else {
                // Non-shared player - use settings from args
                self.canStartPictureInPictureAutomatically = argsCanStartAutomatically
                playerViewController.allowsPictureInPicturePlayback = argsAllowsPiP
                print("✅ PiP settings for non-shared player - allows: \(argsAllowsPiP), autoStart: \(argsCanStartAutomatically)")
            }

            if #available(iOS 14.2, *) {
                // Start with automatic PiP DISABLED
                // It will be enabled when this specific player starts playing (if allowed)
                // This prevents conflicts when multiple players exist
                playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
                print("✅ PiP configured, automatic PiP will be enabled on play if allowed")
            } else {
                print("⚠️ Automatic PiP requires iOS 14.2+, current device doesn't support it")
            }

            // Store media info if provided during initialization
            // This ensures we have the correct media info even for shared players
            if let mediaInfo = args["mediaInfo"] as? [String: Any] {
                currentMediaInfo = mediaInfo
                print("📱 Stored media info during init: \(mediaInfo["title"] ?? "Unknown")")

                // Also store in SharedPlayerManager to persist across view recreations
                if let controllerIdValue = controllerId {
                    SharedPlayerManager.shared.setMediaInfo(for: controllerIdValue, mediaInfo: mediaInfo)
                }
            }
        }
        
        // Register this view with the SharedPlayerManager
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.registerVideoPlayerView(self, viewId: viewId)
            print("✅ Registered VideoPlayerView for controller \(controllerIdValue), viewId: \(viewId)")

            // If this controller is currently the one with automatic PiP enabled OR if the player is playing,
            // this new view should become the primary view and get automatic PiP
            // BUT ONLY if manual PiP is not active
            if #available(iOS 14.2, *) {
                let isActiveForAutoPiP = SharedPlayerManager.shared.isControllerActiveForAutoPiP(controllerIdValue)
                let isPlaying = player?.rate ?? 0 > 0

                if isActiveForAutoPiP || isPlaying {
                    print("🎬 Controller state - activeForAutoPiP: \(isActiveForAutoPiP), isPlaying: \(isPlaying)")
                    if canStartPictureInPictureAutomatically {
                        // Check if manual PiP is active - if so, skip re-enabling automatic PiP
                        if SharedPlayerManager.shared.isManualPiPActive(controllerIdValue) {
                            print("   ⚠️ Skipping automatic PiP re-enable - manual PiP is active")
                        } else {
                            // Set this new view as the primary view
                            SharedPlayerManager.shared.setPrimaryView(viewId, for: controllerIdValue)
                            // Re-apply automatic PiP settings to enable it on this new view
                            SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                            print("   → Set new view as primary and enabled automatic PiP (viewId: \(viewId))")
                        }
                    } else {
                        print("   ⚠️ Cannot enable automatic PiP - canStartPictureInPictureAutomatically is false")
                    }
                }
            }
        }

        // Background audio setup - required for automatic PiP
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            print("✅ AVAudioSession configured for playback")
        } catch {
            print("❌ Failed to configure AVAudioSession: \(error.localizedDescription)")
        }
        try? AVAudioSession.sharedInstance().setActive(true)

        print("Setting up method channel: \(channelName)")
        // Set up method call handler
        print("Setting method handler for channel: \(channelName)")
        methodChannel.setMethodCallHandler({ [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard let self = self else {
                result(FlutterError(code: "DISPOSED", message: "VideoPlayerView was disposed", details: nil))
                return
            }
            print("[\(self.channelName)] Received method call: \(call.method)")
            self.handleMethodCall(call: call, result: result)
        })
        
        // Set up event channel
        let eventChannel = FlutterEventChannel(
            name: "native_video_player_\(viewId)",
            binaryMessenger: messenger
        )
        eventChannel.setStreamHandler(self)

        // Set up observers for shared players if there's already a loaded video
        // The initial state event will be sent when onListen is called
        if isSharedPlayer, let currentItem = player?.currentItem {
            addObservers(to: currentItem)
            // Also set up periodic time observer for this new view
            setupPeriodicTimeObserver()
        }

        // Observe app entering foreground to restore Now Playing info
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        print("✅ Registered foreground notification observer for view \(viewId)")

        // Observe audio session interruptions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        print("✅ Registered audio session interruption observer for view \(viewId)")

        // Set up AirPlay route detector (iOS 11.0+)
        if #available(iOS 11.0, *) {
            setupAirPlayRouteDetector()
        }
    }

    public func view() -> UIView {
        return playerViewController.view
    }

    public func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("Handling method call: \(call.method) on channel: \(channelName)")
        switch call.method {
        case "load":
            handleLoad(call: call, result: result)
        case "play":
            handlePlay(result: result)
        case "pause":
            handlePause(result: result)
        case "seekTo":
            handleSeekTo(call: call, result: result)
        case "setVolume":
            handleSetVolume(call: call, result: result)
        case "setSpeed":
            handleSetSpeed(call: call, result: result)
        case "setLooping":
            handleSetLooping(call: call, result: result)
        case "setQuality":
            handleSetQuality(call: call, result: result)
        case "getAvailableQualities":
            // First check if we have qualities in this view instance
            if !availableQualities.isEmpty {
                result(availableQualities)
            } else if let controllerIdValue = controllerId,
                      let cachedQualities = SharedPlayerManager.shared.getQualities(for: controllerIdValue) {
                // If view instance is empty but cache has qualities, restore them
                availableQualities = cachedQualities
                if let cachedQualityLevels = SharedPlayerManager.shared.getQualityLevels(for: controllerIdValue) {
                    qualityLevels = cachedQualityLevels
                }
                print("🔄 Restored \(cachedQualities.count) qualities from cache for controller \(controllerIdValue)")
                result(cachedQualities)
            } else {
                result(availableQualities)
            }
        case "enterFullScreen":
            handleEnterFullScreen(result: result)
        case "exitFullScreen":
            handleExitFullScreen(result: result)
        case "isPictureInPictureAvailable":
            handleIsPictureInPictureAvailable(result: result)
        case "enterPictureInPicture":
            handleEnterPictureInPicture(result: result)
        case "exitPictureInPicture":
            handleExitPictureInPicture(result: result)
        case "setShowNativeControls":
            handleSetShowNativeControls(call: call, result: result)
        case "isAirPlayAvailable":
            handleIsAirPlayAvailable(result: result)
        case "showAirPlayPicker":
            handleShowAirPlayPicker(result: result)
        case "dispose":
            handleDispose(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func sendEvent(_ name: String, data: [String: Any]? = nil) {
        var event: [String: Any] = ["event": name]
        if let data = data {
            event.merge(data) { (_, new) in
                new
            }
        }
        eventSink?(event)
    }

    /// Cleans up remote command ownership, attempting to transfer to another view if possible
    /// This is called from both deinit and handleDispose to avoid duplication
    func cleanupRemoteCommandOwnership() {
        // Only proceed if this view owns the remote commands
        guard RemoteCommandManager.shared.isOwner(viewId) else {
            return
        }

        print("🎛️ View \(viewId) owned remote commands - attempting transfer")

        // Try to transfer ownership to another view with the same controller
        var ownershipTransferred = false
        if let controllerIdValue = controllerId,
           let alternativeView = SharedPlayerManager.shared.findAnotherViewForController(controllerIdValue, excluding: viewId) {
            print("🎛️ Transferring ownership to view \(alternativeView.viewId)")

            // Transfer ownership by setting up Now Playing info on the alternative view
            var mediaInfo = alternativeView.currentMediaInfo

            // Fallback: Try to get media info from SharedPlayerManager
            if mediaInfo == nil {
                mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
                if mediaInfo != nil {
                    print("📱 Retrieved media info from SharedPlayerManager for ownership transfer")
                    alternativeView.currentMediaInfo = mediaInfo
                }
            }

            if let mediaInfo = mediaInfo {
                alternativeView.setupNowPlayingInfo(mediaInfo: mediaInfo)
                ownershipTransferred = true
                print("✅ Ownership transferred to view \(alternativeView.viewId)")
            } else {
                print("⚠️ Alternative view has no media info - cannot transfer")
            }
        }

        // CRITICAL: If no transfer was possible BUT PiP is active OR restoring, DO NOT clear Now Playing info
        // PiP needs the media controls to work, so we must preserve them
        if !ownershipTransferred {
            // Check if PiP is active:
            // 1. On this view (isPipCurrentlyActive)
            // 2. On ANY view for this controller (isPipActiveForController)
            // 3. Currently restoring UI (isPipRestoringUI)
            let isPipActiveForController = controllerId.flatMap { SharedPlayerManager.shared.isPipActiveForController($0) } ?? false

            if isPipCurrentlyActive || isPipRestoringUI || isPipActiveForController {
                if isPipCurrentlyActive {
                    print("⚠️ No transfer possible but PiP is active on this view - keeping Now Playing info")
                } else if isPipRestoringUI {
                    print("⚠️ No transfer possible but PiP is restoring UI - keeping Now Playing info")
                } else {
                    print("⚠️ No transfer possible but PiP is active on another view for controller \(controllerId ?? -1) - keeping Now Playing info")
                }
                // Just clear the ownership flag, but keep the Now Playing info and remote commands active
                RemoteCommandManager.shared.clearOwner(viewId)
                // Do NOT clear nowPlayingInfo or remove targets while PiP is active or restoring
            } else {
                print("🗑️ No transfer possible and PiP is not active - clearing ownership and Now Playing info")
                RemoteCommandManager.shared.clearOwner(viewId)
                RemoteCommandManager.shared.removeAllTargets()
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
        }
    }

    /// Emits all current player states to ensure UI is in sync
    /// This is useful after events like exiting PiP where the UI needs to refresh
    public func emitCurrentState() {
        guard let player = player, let currentItem = player.currentItem else {
            print("[\(channelName)] No player or item available to emit state")
            return
        }

        print("[\(channelName)] Emitting current state after PiP exit")

        // Emit current time and duration
        let currentTimeSeconds = CMTimeGetSeconds(player.currentTime())
        let durationSeconds = CMTimeGetSeconds(currentItem.duration)

        if !currentTimeSeconds.isNaN && !durationSeconds.isNaN && durationSeconds > 0 {
            let duration = Int(durationSeconds * 1000)
            let position = Int(currentTimeSeconds * 1000)

            // Get buffered position
            var bufferedSeconds = 0.0
            let timeRanges = currentItem.loadedTimeRanges
            if !timeRanges.isEmpty {
                let bufferedRange = timeRanges.last!.timeRangeValue
                let bufferedEnd = CMTimeAdd(bufferedRange.start, bufferedRange.duration)
                bufferedSeconds = CMTimeGetSeconds(bufferedEnd)
            }
            let bufferedPosition = Int(bufferedSeconds * 1000)

            sendEvent("timeUpdate", data: [
                "position": position,
                "duration": duration,
                "bufferedPosition": bufferedPosition,
                "isBuffering": player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            ])
            print("[\(channelName)] Emitted timeUpdate with duration: \(duration)ms")
        }

        // Emit current playback state
        switch player.timeControlStatus {
        case .playing:
            print("[\(channelName)] Emitting play state")
            sendEvent("play")
        case .paused:
            print("[\(channelName)] Emitting pause state")
            sendEvent("pause")
        case .waitingToPlayAtSpecifiedRate:
            print("[\(channelName)] Emitting buffering state")
            sendEvent("buffering")
        @unknown default:
            break
        }
    }

    // MARK: - FlutterStreamHandler
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        print("[\(channelName)] Event channel listener attached")
        self.eventSink = events

        // Send initial state event when listener is attached
        if isSharedPlayer {
            // For shared players, only send current playback state and position
            if let player = player, let currentItem = player.currentItem {
                let currentTimeSeconds = CMTimeGetSeconds(player.currentTime())
                let durationSeconds = CMTimeGetSeconds(currentItem.duration)

                // Check for NaN or invalid times
                if currentTimeSeconds.isNaN || durationSeconds.isNaN {
                    print("[\(channelName)] Skipping timeUpdated event — invalid currentTime or duration")
                } else {
                    let duration = Int(durationSeconds * 1000)
                    let position = Int(currentTimeSeconds * 1000)
                    sendEvent("timeUpdated", data: ["position": position, "duration": duration])
                }

                // Send current playback state
                switch player.timeControlStatus {
                case .playing:
                    print("[\(channelName)] Sending play event to new listener")
                    sendEvent("play")
                case .paused:
                    print("[\(channelName)] Sending pause event to new listener")
                    sendEvent("pause")
                case .waitingToPlayAtSpecifiedRate:
                    print("[\(channelName)] Sending buffering event to new listener")
                    sendEvent("buffering")
                @unknown default:
                    break
                }
            }

        } else {
            // For new players, send isInitialized event
            print("[\(channelName)] Sending isInitialized event to new listener")
            sendEvent("isInitialized")
        }

        // Send initial AirPlay availability state
        if #available(iOS 11.0, *) {
            if let detector = routeDetector {
                let isAvailable = detector.multipleRoutesDetected
                print("[\(channelName)] Sending initial AirPlay availability: \(isAvailable)")
                sendEvent("airPlayAvailabilityChanged", data: ["isAvailable": isAvailable])
            }
        }

        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("[\(channelName)] Event channel listener detached")
        self.eventSink = nil
        return nil
    }

    deinit {
        print("VideoPlayerView deinit for channel: \(channelName), viewId: \(viewId)")

        // Use the isPipCurrentlyActive flag to check if PiP is active
        let isPipActiveNow = isPipCurrentlyActive

        if isPipActiveNow {
            print("⚠️ View being disposed while PiP is active - sending pipStop event")

            // Always send pipStop event - either from this view or an alternative
            if eventSink != nil {
                // This view still has a listener, send from here
                sendEvent("pipStop", data: ["isPictureInPicture": false])
                print("✅ Sent pipStop event from disposing view \(viewId)")
            } else if let controllerIdValue = controllerId,
                      let alternativeView = SharedPlayerManager.shared.findAnotherViewForController(controllerIdValue, excluding: viewId),
                      alternativeView.eventSink != nil {
                // Send from alternative view if it exists and has a listener
                alternativeView.sendEvent("pipStop", data: ["isPictureInPicture": false])
                print("✅ Sent pipStop event from alternative view \(alternativeView.viewId)")
            } else {
                print("⚠️ No active view with listener found - pipStop event cannot be sent")
            }

            // Try to stop PiP gracefully
            if #available(iOS 14.0, *) {
                if let pipCtrl = pipController, pipCtrl.isPictureInPictureActive {
                    pipCtrl.stopPictureInPicture()
                }
            }
        }

        // Clean up remote command ownership (transfer to another view if possible)
        cleanupRemoteCommandOwnership()

        // Handle automatic PiP transfer for shared players
        // If this was the primary view (the one with automatic PiP enabled) OR if the player is playing,
        // we need to transfer automatic PiP to another view using the same controller
        if #available(iOS 14.2, *), let controllerIdValue = controllerId {
            let wasPrimaryView = SharedPlayerManager.shared.isPrimaryView(viewId, for: controllerIdValue)
            let wasAutoEnabled = SharedPlayerManager.shared.isControllerActiveForAutoPiP(controllerIdValue)
            let isPlaying = player?.rate ?? 0 > 0

            // Transfer automatic PiP if:
            // 1. This was the primary view AND auto PiP was enabled, OR
            // 2. The player is currently playing (should maintain auto PiP capability)
            if (wasPrimaryView && wasAutoEnabled) || isPlaying {
                print("🎬 View being disposed (primary: \(wasPrimaryView), autoEnabled: \(wasAutoEnabled), playing: \(isPlaying)) - transferring automatic PiP to another view")

                // Disable automatic PiP on this view before unregistering
                playerViewController.canStartPictureInPictureAutomaticallyFromInline = false

                // Unregister this view first so it won't be found
                SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)

                // Re-enable automatic PiP - this will find and enable a different view
                // for the same controller (if any exists)
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                print("✅ Automatic PiP transferred to another view for controller \(controllerIdValue)")
            } else {
                // Normal unregister for non-primary views
                SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)
            }
        } else {
            // Normal unregister for non-shared players
            SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)
        }

        // Remove periodic time observer
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        // Only remove observers, don't dispose the player if it's shared
        // The shared player will be kept alive for reuse
        if let item = player?.currentItem {
            item.removeObserver(self, forKeyPath: "status")
            item.removeObserver(self, forKeyPath: "playbackBufferEmpty")
            item.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
        }

        // Remove player observer for timeControlStatus
        player?.removeObserver(self, forKeyPath: "timeControlStatus")

        // Remove player observer for externalPlaybackActive
        player?.removeObserver(self, forKeyPath: "externalPlaybackActive")

        // Remove route detector observer
        if #available(iOS 11.0, *) {
            routeDetector?.removeObserver(self, forKeyPath: "multipleRoutesDetected")
            routeDetector?.isRouteDetectionEnabled = false
            routeDetector = nil
        }

        NotificationCenter.default.removeObserver(self)
        methodChannel.setMethodCallHandler(nil)

        // Clear current media info from this view
        // BUT do NOT clear from SharedPlayerManager if PiP is active
        // This ensures media controls survive view disposal during PiP
        currentMediaInfo = nil
        if !isPipActiveNow {
            // Only clear from SharedPlayerManager if PiP is NOT active
            if let controllerIdValue = controllerId {
                // But first check if there are other views using this controller
                let otherViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
                if otherViews.count <= 1 {
                    // This is the last view, safe to clear media info
                    print("🧹 Clearing media info from SharedPlayerManager (last view)")
                } else {
                    print("📱 Keeping media info in SharedPlayerManager (other views exist)")
                }
            }
        } else {
            print("📱 Keeping media info in SharedPlayerManager (PiP is active)")
        }

        // Note: player and playerViewController are NOT disposed here
        // They remain in SharedPlayerManager for reuse
        print("Platform view disposed but player kept alive for controller ID: \(String(describing: controllerId))")
    }

    // MARK: - App Lifecycle Handling

    /// Called when app returns to foreground
    /// Restores Now Playing info which may have been cleared by the system
    @objc func handleAppWillEnterForeground() {
        print("📱 App entering foreground - restoring Now Playing info for view \(viewId)")

        // CRITICAL: Reactivate audio session first
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            print("   → Audio session reactivated")
        } catch {
            print("   ⚠️ Failed to reactivate audio session: \(error.localizedDescription)")
        }

        // Check if this view owns the remote commands
        guard RemoteCommandManager.shared.isOwner(viewId) else {
            print("   → View \(viewId) doesn't own remote commands, skipping restore")
            return
        }

        // Check if we have media info to restore
        var mediaInfo = currentMediaInfo

        // Fallback: Try to retrieve from SharedPlayerManager if not available locally
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                print("   → Retrieved media info from SharedPlayerManager")
                currentMediaInfo = mediaInfo // Update local copy
            }
        }

        guard let mediaInfo = mediaInfo else {
            print("   ⚠️ No media info available to restore")
            return
        }

        // Delay slightly to ensure audio session is fully active
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            // Restore Now Playing info
            print("   → Restoring Now Playing info: \(mediaInfo["title"] ?? "Unknown")")
            self.setupNowPlayingInfo(mediaInfo: mediaInfo)

            // Also update the playback time to ensure controls show correct position
            self.updateNowPlayingPlaybackTime()
        }
    }

    /// Called when audio session is interrupted (e.g., phone call, other app's audio)
    @objc func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        print("🔊 Audio session interruption: \(type == .began ? "began" : "ended")")

        switch type {
        case .began:
            print("   → Audio session interrupted, Now Playing info may be cleared")

        case .ended:
            // Check if we should resume playback
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("   → Should resume after interruption")
                }
            }

            // Reactivate audio session
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                print("   → Audio session reactivated")
            } catch {
                print("   ⚠️ Failed to reactivate audio session: \(error.localizedDescription)")
            }

            // Restore Now Playing info after audio session is reactivated
            if RemoteCommandManager.shared.isOwner(viewId) {
                var mediaInfo = currentMediaInfo
                if mediaInfo == nil, let controllerIdValue = controllerId {
                    mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
                }

                if let mediaInfo = mediaInfo {
                    print("   → Restoring Now Playing info after interruption")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.setupNowPlayingInfo(mediaInfo: mediaInfo)
                        self?.updateNowPlayingPlaybackTime()
                    }
                }
            }

        @unknown default:
            break
        }
    }
}


import AVFoundation
import AVKit
import Flutter

// MARK: - Shared Player Manager

/// Manages shared AVPlayer instances across multiple platform views
/// Keeps players alive even when platform views are disposed
/// Note: Each platform view gets its own AVPlayerViewController, but they share the same AVPlayer
class SharedPlayerManager: NSObject {
    static let shared = SharedPlayerManager()

    /// Threading contract: every mutating entry point must run on the main
    /// thread — method-channel handlers and platform-view init/deinit already
    /// do. The dictionaries below are intentionally unsynchronized; this
    /// assertion (debug builds only) catches violations instead of corrupting
    /// state silently.
    @inline(__always)
    private func assertMainThread(_ function: StaticString = #function) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
    }

    private var players: [Int: AVPlayer] = [:]

    /// Shared AVPlayerViewController instances (persist across view disposal)
    /// Keeps view controllers alive so PiP delegate callbacks can fire even when platform views are disposed
    private var playerViewControllers: [Int: AVPlayerViewController] = [:]

    /// Global AirPlay route detector
    /// Used to monitor AirPlay availability across the entire app
    private var globalRouteDetector: AVRouteDetector?

    /// Track which controller currently has automatic PiP enabled
    /// Only one controller should have automatic PiP active at a time
    private var controllerWithAutomaticPiP: Int?

    /// Track which controllers have MANUAL PiP active
    /// This prevents automatic PiP from interfering with manual PiP
    private var controllersWithManualPiP: Set<Int> = []

    /// Track which view ID is the PRIMARY (most recently played) view for each controller
    /// This ensures we enable PiP on the correct view when multiple views exist (list + detail)
    private var primaryViewIdForController: [Int: Int64] = [:]

    /// Store references to ALL active VideoPlayerView instances
    /// Multiple platform views can exist for the same controller (list + detail screen)
    /// We need weak references to avoid retain cycles
    /// Key is a unique identifier (viewId), value is the view
    private var videoPlayerViews: [String: WeakVideoPlayerViewWrapper] = [:]

    /// Store PiP settings for each controller
    /// This ensures PiP settings persist across all views using the same controller
    private var pipSettings: [Int: PipSettings] = [:]

    /// Store available qualities for each controller
    /// This ensures qualities persist across view recreations
    private var qualitiesCache: [Int: [[String: Any]]] = [:]

    /// Store quality levels for each controller
    private var qualityLevelsCache: [Int: [VideoPlayer.QualityLevel]] = [:]

    /// Store media info for each controller
    /// This ensures media info persists across view recreations and during PiP transitions
    private var mediaInfoCache: [Int: [String: Any]] = [:]

    /// Controller-level event sinks (persistent, independent of platform views)
    /// These persist to send PiP and AirPlay events even when all views are disposed
    private var controllerEventSinks: [Int: FlutterEventSink] = [:]

    struct PipSettings {
        let allowsPictureInPicture: Bool
        let canStartPictureInPictureAutomatically: Bool
        let showNativeControls: Bool
    }

    private override init() {
        super.init()
    }

    /// Configures an AVPlayer for background playback when device is locked
    /// This sets the audiovisualBackgroundPlaybackPolicy to allow playback to continue
    private func configurePlayerForBackgroundPlayback(_ player: AVPlayer) {
        if #available(iOS 15.0, *) {
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            npLog("✅ [SharedPlayerManager] Set audiovisualBackgroundPlaybackPolicy to continuesIfPossible")
        } else {
            npLog("ℹ️ [SharedPlayerManager] audiovisualBackgroundPlaybackPolicy not available (iOS < 15.0)")
        }
    }

    /// Gets or creates a player for the given controller ID
    /// Returns a tuple (AVPlayer, Bool) where the Bool indicates if the player already existed (true) or was newly created (false)
    func getOrCreatePlayer(for controllerId: Int) -> (AVPlayer, Bool) {
        if let existingPlayer = players[controllerId] {
            return (existingPlayer, true)
        }

        let newPlayer = AVPlayer()
        configurePlayerForBackgroundPlayback(newPlayer)
        players[controllerId] = newPlayer
        return (newPlayer, false)
    }

    /// Gets or creates BOTH a player and view controller for the given controller ID
    /// Returns a tuple (AVPlayer, AVPlayerViewController, Bool) where the Bool indicates if they already existed
    /// This ensures the view controller persists across platform view disposal so PiP delegate callbacks continue to work
    func getOrCreatePlayerAndViewController(for controllerId: Int) -> (AVPlayer, AVPlayerViewController, Bool) {
        assertMainThread()
        // Reuse the existing player even when no view controller exists yet
        // (the controller may have been created by a lightweight view, which
        // skips the shared AVPlayerViewController entirely).
        let (player, playerExisted) = getOrCreatePlayer(for: controllerId)

        if let existingViewController = playerViewControllers[controllerId] {
            npLog("♻️ [SharedPlayerManager] Reusing existing player AND view controller for controller ID: \(controllerId)")
            return (player, existingViewController, playerExisted)
        }

        // Create new view controller
        let newViewController = AVPlayerViewController()
        newViewController.player = player
        playerViewControllers[controllerId] = newViewController

        npLog("✅ [SharedPlayerManager] Created \(playerExisted ? "view controller for existing player" : "new player AND view controller") for controller ID: \(controllerId)")
        return (player, newViewController, playerExisted)
    }

    /// Sets PiP settings for a controller
    /// This ensures the settings persist across all views using the same controller
    func setPipSettings(for controllerId: Int, allowsPictureInPicture: Bool, canStartPictureInPictureAutomatically: Bool, showNativeControls: Bool) {
        pipSettings[controllerId] = PipSettings(
            allowsPictureInPicture: allowsPictureInPicture,
            canStartPictureInPictureAutomatically: canStartPictureInPictureAutomatically,
            showNativeControls: showNativeControls
        )
        npLog("   ✅ Stored PiP settings for controller \(controllerId) - allows: \(allowsPictureInPicture), autoStart: \(canStartPictureInPictureAutomatically)")
    }

    /// Gets PiP settings for a controller
    /// Returns nil if no settings have been stored for this controller
    func getPipSettings(for controllerId: Int) -> PipSettings? {
        return pipSettings[controllerId]
    }

    /// Sets available qualities for a controller
    /// This ensures qualities persist across view recreations
    func setQualities(for controllerId: Int, qualities: [[String: Any]], qualityLevels: [VideoPlayer.QualityLevel]) {
        qualitiesCache[controllerId] = qualities
        qualityLevelsCache[controllerId] = qualityLevels
        npLog("   ✅ Stored \(qualities.count) qualities for controller \(controllerId)")
    }

    /// Gets available qualities for a controller
    /// Returns nil if no qualities have been stored for this controller
    func getQualities(for controllerId: Int) -> [[String: Any]]? {
        return qualitiesCache[controllerId]
    }

    /// Gets quality levels for a controller
    /// Returns nil if no quality levels have been stored for this controller
    func getQualityLevels(for controllerId: Int) -> [VideoPlayer.QualityLevel]? {
        return qualityLevelsCache[controllerId]
    }

    /// Sets media info for a controller
    /// This ensures media info persists across view recreations and during PiP transitions
    func setMediaInfo(for controllerId: Int, mediaInfo: [String: Any]) {
        mediaInfoCache[controllerId] = mediaInfo
        if let title = mediaInfo["title"] as? String {
            npLog("   ✅ Stored media info for controller \(controllerId): \(title)")
        } else {
            npLog("   ✅ Stored media info for controller \(controllerId)")
        }
    }

    /// Gets media info for a controller
    /// Returns nil if no media info has been stored for this controller
    func getMediaInfo(for controllerId: Int) -> [String: Any]? {
        return mediaInfoCache[controllerId]
    }

    // MARK: - Controller Event Channel Methods

    /// Registers a controller-level event sink for persistent events
    /// This sink receives PiP and AirPlay events independently of platform views
    func registerControllerEventSink(_ eventSink: @escaping FlutterEventSink, for controllerId: Int) {
        assertMainThread()
        controllerEventSinks[controllerId] = eventSink
        npLog("✅ [SharedPlayerManager] Registered controller event sink for controller \(controllerId)")

        // Send initial controller state
        sendInitialControllerState(for: controllerId, to: eventSink)
    }

    /// Unregisters a controller-level event sink
    func unregisterControllerEventSink(for controllerId: Int) {
        assertMainThread()
        controllerEventSinks.removeValue(forKey: controllerId)
        npLog("🗑️ [SharedPlayerManager] Unregistered controller event sink for controller \(controllerId)")
    }

    /// Sends an event through the controller-level event channel
    func sendControllerEvent(_ eventName: String, data: [String: Any], for controllerId: Int) {
        guard let eventSink = controllerEventSinks[controllerId] else {
            // No event sink registered - this is normal during initialization or after disposal
            return
        }

        var event = data
        event["event"] = eventName

        DispatchQueue.main.async {
            eventSink(event)
        }
    }

    /// Sends initial controller state when event sink is registered
    private func sendInitialControllerState(for controllerId: Int, to eventSink: @escaping FlutterEventSink) {
        // Send initial PiP availability (always true on iOS for devices that support it)
        let pipAvailabilityEvent: [String: Any] = [
            "event": "pipAvailabilityChanged",
            "isAvailable": AVPictureInPictureController.isPictureInPictureSupported()
        ]
        DispatchQueue.main.async {
            eventSink(pipAvailabilityEvent)
        }

        // Send initial AirPlay availability from global route detector
        if let detector = globalRouteDetector {
            let airplayAvailabilityEvent: [String: Any] = [
                "event": "airPlayAvailabilityChanged",
                "isAvailable": detector.isRouteDetectionEnabled && detector.multipleRoutesDetected
            ]
            DispatchQueue.main.async {
                eventSink(airplayAvailabilityEvent)
            }
        }

        // Note: Initial PiP state and AirPlay connection state will be sent
        // when views are created and report their current state
    }

    /// Stops and clears player from all views using this controller
    func stopAllViewsForController(_ controllerId: Int) {
        npLog("🛑 [SharedPlayerManager] stopAllViewsForController called for controllerId: \(controllerId)")

        guard let player = players[controllerId] else {
            npLog("⚠️ [SharedPlayerManager] No player found for controllerId: \(controllerId)")
            return
        }

        npLog("⏸️ [SharedPlayerManager] Pausing player for controllerId: \(controllerId)")
        // Pause and clear the player
        player.pause()
        npLog("🧹 [SharedPlayerManager] Clearing current item for controllerId: \(controllerId)")
        player.replaceCurrentItem(with: nil)

        // Clear player reference from all views using this controller
        var clearedViewCount = 0
        for (viewId, weakView) in videoPlayerViews {
            if let view = weakView.view, view.controllerId == controllerId {
                npLog("🧹 [SharedPlayerManager] Clearing player from view \(viewId) for controllerId: \(controllerId)")
                view.player = nil
                clearedViewCount += 1
            }
        }

        npLog("✅ [SharedPlayerManager] Stopped all views (\(clearedViewCount) views) for controller ID: \(controllerId)")
    }

    /// Removes a player (called when explicitly disposed)
    func removePlayer(for controllerId: Int) {
        assertMainThread()
        npLog("🗑️ [SharedPlayerManager] removePlayer called for controllerId: \(controllerId)")
        npLog("📊 [SharedPlayerManager] Current players count: \(players.count), players: \(players.keys.sorted())")

        // First stop all views using this player
        stopAllViewsForController(controllerId)

        // Remove player from manager
        npLog("🧹 [SharedPlayerManager] Removing player from players dict for controllerId: \(controllerId)")
        players.removeValue(forKey: controllerId)
        npLog("✅ [SharedPlayerManager] Player removed. New players count: \(players.count), players: \(players.keys.sorted())")

        // Remove and dispose view controller
        if let viewController = playerViewControllers.removeValue(forKey: controllerId) {
            viewController.player = nil
            viewController.delegate = nil
            npLog("🗑️ [SharedPlayerManager] Disposed AVPlayerViewController for controller \(controllerId)")
        }

        // Remove all views for this controller
        let viewCountBefore = videoPlayerViews.count
        videoPlayerViews = videoPlayerViews.filter { $0.value.view?.controllerId != controllerId }
        let viewCountAfter = videoPlayerViews.count
        npLog("🧹 [SharedPlayerManager] Removed \(viewCountBefore - viewCountAfter) views. New view count: \(viewCountAfter)")

        // Clear primary view tracking
        primaryViewIdForController.removeValue(forKey: controllerId)

        // Remove PiP settings
        pipSettings.removeValue(forKey: controllerId)

        // Remove qualities cache
        qualitiesCache.removeValue(forKey: controllerId)
        qualityLevelsCache.removeValue(forKey: controllerId)

        // Remove media info cache
        mediaInfoCache.removeValue(forKey: controllerId)

        // If this was the controller with automatic PiP, clear it
        if controllerWithAutomaticPiP == controllerId {
            controllerWithAutomaticPiP = nil
        }

        // Clear manual PiP flag
        controllersWithManualPiP.remove(controllerId)

        npLog("✅ [SharedPlayerManager] Fully removed player for controller ID: \(controllerId)")
    }

    /// Clears all players (e.g., on logout)
    func clearAll() {
        // Dispose all view controllers
        for (_, viewController) in playerViewControllers {
            viewController.player = nil
            viewController.delegate = nil
        }
        playerViewControllers.removeAll()

        players.removeAll()
        videoPlayerViews.removeAll()
        primaryViewIdForController.removeAll()
        pipSettings.removeAll()
        qualitiesCache.removeAll()
        qualityLevelsCache.removeAll()
        mediaInfoCache.removeAll()
        controllerWithAutomaticPiP = nil
        controllersWithManualPiP.removeAll()
        controllerEventSinks.removeAll()
    }

    // MARK: - AirPlay Route Detection

    /// True while the global route detector reports multiple available routes
    var isAirPlayRouteAvailable: Bool {
        globalRouteDetector?.multipleRoutesDetected ?? false
    }

    /// Starts global route detection if not already running. Called when a
    /// platform view is created — replaces the previous per-view
    /// AVRouteDetector instances (route detection is power-expensive; one
    /// app-wide detector serves all views).
    @available(iOS 11.0, *)
    func ensureRouteDetectionStarted() {
        guard globalRouteDetector == nil else { return }
        startAirPlayRouteDetection()
    }

    /// Starts global AirPlay route detection
    /// This monitors AirPlay device availability across the entire app
    @available(iOS 11.0, *)
    func startAirPlayRouteDetection() {
        npLog("🔍 [SharedPlayerManager] Starting global AirPlay route detection")

        // Clean up any existing detector
        if let existingDetector = globalRouteDetector {
            existingDetector.removeObserver(self, forKeyPath: "multipleRoutesDetected")
            globalRouteDetector = nil
        }

        // Create and configure new route detector
        globalRouteDetector = AVRouteDetector()
        globalRouteDetector?.isRouteDetectionEnabled = true

        // Observe changes to multipleRoutesDetected
        globalRouteDetector?.addObserver(
            self,
            forKeyPath: "multipleRoutesDetected",
            options: [.new, .initial],
            context: nil
        )

        npLog("✅ [SharedPlayerManager] Global AirPlay route detection started, multipleRoutesDetected: \(globalRouteDetector?.multipleRoutesDetected ?? false)")

        // Send initial availability state
        if let isAvailable = globalRouteDetector?.multipleRoutesDetected {
            sendAirPlayAvailabilityEvent(isAvailable: isAvailable)
        }
    }

    /// Stops global AirPlay route detection
    @available(iOS 11.0, *)
    func stopAirPlayRouteDetection() {
        npLog("🛑 [SharedPlayerManager] Stopping global AirPlay route detection")

        guard let detector = globalRouteDetector else {
            npLog("⚠️ [SharedPlayerManager] No global route detector to stop")
            return
        }

        detector.removeObserver(self, forKeyPath: "multipleRoutesDetected")
        detector.isRouteDetectionEnabled = false
        globalRouteDetector = nil

        npLog("✅ [SharedPlayerManager] Global AirPlay route detection stopped")
    }

    /// Sends AirPlay availability event to Flutter through all registered views
    private func sendAirPlayAvailabilityEvent(isAvailable: Bool) {
        // Clean up nil/deallocated views first
        videoPlayerViews = videoPlayerViews.filter { $0.value.view != nil }

        npLog("📡 [SharedPlayerManager] Sending AirPlay availability event to \(videoPlayerViews.count) view(s): \(isAvailable)")

        // Send event through all registered views
        for (_, wrapper) in videoPlayerViews {
            if let view = wrapper.view {
                view.sendEvent("airPlayAvailabilityChanged", data: ["isAvailable": isAvailable])
            }
        }

        // Also send through the controller-level channels so availability
        // survives view disposal (previously done by per-view detectors)
        for controllerId in controllerEventSinks.keys {
            sendControllerEvent(
                "airPlayAvailabilityChanged",
                data: ["isAvailable": isAvailable],
                for: controllerId
            )
        }
    }

    /// KVO observer for route detector changes
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "multipleRoutesDetected" {
            if #available(iOS 11.0, *) {
                if let isAvailable = globalRouteDetector?.multipleRoutesDetected {
                    npLog("🔄 [SharedPlayerManager] AirPlay availability changed: \(isAvailable)")
                    sendAirPlayAvailabilityEvent(isAvailable: isAvailable)
                }
            }
        }
    }
    
    /// Register a VideoPlayerView instance
    /// Multiple views can be registered for the same controller (e.g., list + detail screen)
    func registerVideoPlayerView(_ view: VideoPlayerView, viewId: Int64) {
        assertMainThread()
        let key = "\(viewId)"
        videoPlayerViews[key] = WeakVideoPlayerViewWrapper(view: view)
        npLog("   → Registered view with ID \(viewId), total views: \(videoPlayerViews.count)")
    }
    
    /// Unregister a VideoPlayerView when it's disposed
    func unregisterVideoPlayerView(viewId: Int64) {
        assertMainThread()
        let key = "\(viewId)"
        videoPlayerViews.removeValue(forKey: key)
        npLog("   → Unregistered view with ID \(viewId), remaining views: \(videoPlayerViews.count)")
    }

    /// Find another active view for a given controller (excluding a specific viewId)
    /// Returns the view instance if found, nil otherwise
    func findAnotherViewForController(_ controllerId: Int, excluding excludedViewId: Int64) -> VideoPlayerView? {
        // Clean up nil/deallocated views first
        videoPlayerViews = videoPlayerViews.filter { $0.value.view != nil }

        // Find another view with the same controller
        for (viewKey, wrapper) in videoPlayerViews {
            if let view = wrapper.view,
               view.controllerId == controllerId,
               view.viewId != excludedViewId {
                npLog("   🔍 Found alternative view \(view.viewId) for controller \(controllerId)")
                return view
            }
        }

        npLog("   ⚠️ No alternative view found for controller \(controllerId)")
        return nil
    }

    /// Find all active views for a given controller
    /// Returns an array of view instances
    func findAllViewsForController(_ controllerId: Int) -> [VideoPlayerView] {
        // Clean up nil/deallocated views first
        videoPlayerViews = videoPlayerViews.filter { $0.value.view != nil }

        var views: [VideoPlayerView] = []
        for (_, wrapper) in videoPlayerViews {
            if let view = wrapper.view, view.controllerId == controllerId {
                views.append(view)
            }
        }

        npLog("   🔍 Found \(views.count) view(s) for controller \(controllerId)")
        return views
    }

    /// Check if a controller is currently the active one for automatic PiP
    func isControllerActiveForAutoPiP(_ controllerId: Int) -> Bool {
        return controllerWithAutomaticPiP == controllerId
    }

    /// Mark that manual PiP is active for a controller
    func setManualPiPActive(_ controllerId: Int, active: Bool) {
        if active {
            controllersWithManualPiP.insert(controllerId)
            npLog("🎬 Marked controller \(controllerId) as having manual PiP active")
        } else {
            controllersWithManualPiP.remove(controllerId)
            npLog("🎬 Cleared manual PiP flag for controller \(controllerId)")
        }
    }

    /// Check if manual PiP is active for a controller
    func isManualPiPActive(_ controllerId: Int) -> Bool {
        return controllersWithManualPiP.contains(controllerId)
    }

    /// Check if ANY view for this controller currently has PiP active
    /// This checks the isPipCurrentlyActive flag on all views for the controller
    func isPipActiveForController(_ controllerId: Int) -> Bool {
        let allViews = findAllViewsForController(controllerId)
        for view in allViews {
            if view.isPipCurrentlyActive {
                return true
            }
        }
        return false
    }

    /// Set the primary (currently playing) view for a controller
    /// This should be called whenever play() is called on a view
    func setPrimaryView(_ viewId: Int64, for controllerId: Int) {
        primaryViewIdForController[controllerId] = viewId
        npLog("   🎯 Set primary view for controller \(controllerId) → ViewId \(viewId)")
    }

    /// Check if a specific view is the primary view for a controller
    func isPrimaryView(_ viewId: Int64, for controllerId: Int) -> Bool {
        return primaryViewIdForController[controllerId] == viewId
    }

    /// Get the primary view ID for a controller (if any)
    func getPrimaryViewId(for controllerId: Int) -> Int64? {
        return primaryViewIdForController[controllerId]
    }
    
    /// Enable automatic PiP for a specific controller and disable for all others
    /// This ensures only one player can enter automatic PiP at a time
    /// IMPORTANT: Only enables on the MOST RECENT (primary) view for that controller
    @available(iOS 14.2, *)
    func setAutomaticPiPEnabled(for controllerId: Int, enabled: Bool) {
        // Clean up nil/deallocated views first
        videoPlayerViews = videoPlayerViews.filter { $0.value.view != nil }
        
        npLog("📊 Current state: \(videoPlayerViews.count) active views registered")
        for (key, wrapper) in videoPlayerViews {
            if let view = wrapper.view {
                npLog("   - ViewId \(key): Controller \(view.controllerId ?? -1), canStartAuto: \(view.canStartPictureInPictureAutomatically), current: \(view.isAutomaticInlinePiPEnabled)")
            }
        }
        
        if enabled {
            // Check if manual PiP is active for this controller
            if isManualPiPActive(controllerId) {
                npLog("⚠️ Cannot enable automatic PiP for controller \(controllerId) - manual PiP is active")
                return
            }

            // Disable automatic PiP on all other controllers first
            if let previousControllerId = controllerWithAutomaticPiP, previousControllerId != controllerId {
                npLog("🎬 Disabling automatic PiP for controller \(previousControllerId)")
                // Disable on ALL platform views for the previous controller
                var disabledCount = 0
                for (viewKey, wrapper) in videoPlayerViews {
                    if let view = wrapper.view, view.controllerId == previousControllerId {
                        let wasBefore = view.isAutomaticInlinePiPEnabled
                        view.setAutomaticInlinePiP(false)
                        npLog("   → ViewId \(viewKey): \(wasBefore) → \(view.isAutomaticInlinePiPEnabled)")
                        disabledCount += 1
                    }
                }
                npLog("   → Disabled on \(disabledCount) platform view(s) for controller \(previousControllerId)")
            }
            
            // Find the PRIMARY (most recently played) platform view for this controller
            npLog("🎬 Enabling automatic PiP for controller \(controllerId)")
            
            // First, disable ALL views for this controller
            for (_, wrapper) in videoPlayerViews {
                if let view = wrapper.view, view.controllerId == controllerId {
                    view.setAutomaticInlinePiP(false)
                }
            }
            
            // Then enable ONLY the primary view (the one that most recently called play)
            var enabledOnView = false
            if let primaryViewId = primaryViewIdForController[controllerId] {
                let key = "\(primaryViewId)"
                if let wrapper = videoPlayerViews[key], let view = wrapper.view {
                    npLog("   🔍 Checking primary view \(primaryViewId):")
                    npLog("      - view.canStartPictureInPictureAutomatically: \(view.canStartPictureInPictureAutomatically)")
                    npLog("      - allowsInlinePictureInPicture: \(view.allowsInlinePictureInPicture)")
                    npLog("      - player rate: \(view.player?.rate ?? -1)")

                    if view.canStartPictureInPictureAutomatically {
                        let wasBefore = view.isAutomaticInlinePiPEnabled
                        view.setAutomaticInlinePiP(true)
                        let isAfter = view.isAutomaticInlinePiPEnabled
                        npLog("   → ViewId \(view.viewId): \(wasBefore) → \(isAfter) [PRIMARY]")
                        npLog("   ✅ Enabled on PRIMARY platform view for controller \(controllerId)")
                        enabledOnView = true
                    } else {
                        npLog("   ⚠️ Primary view doesn't allow automatic PiP")
                    }
                } else {
                    npLog("   ⚠️ Primary view (ViewId \(primaryViewId)) not found or disposed")
                }
            } else {
                npLog("   ⚠️ No primary view set for controller \(controllerId)")
            }

            // FALLBACK: If no primary view was found or it was disposed, pick ANY view for this controller
            // This handles the case where the primary view was disposed but other views still exist
            if !enabledOnView {
                npLog("   🔄 Looking for any available view for controller \(controllerId)")
                for (_, wrapper) in videoPlayerViews {
                    if let view = wrapper.view, view.controllerId == controllerId {
                        if view.canStartPictureInPictureAutomatically {
                            let wasBefore = view.isAutomaticInlinePiPEnabled
                            view.setAutomaticInlinePiP(true)
                            let isAfter = view.isAutomaticInlinePiPEnabled
                            npLog("   → ViewId \(view.viewId): \(wasBefore) → \(isAfter) [FALLBACK]")
                            npLog("   ✅ Enabled on fallback platform view for controller \(controllerId)")
                            // Set this as the new primary view
                            primaryViewIdForController[controllerId] = view.viewId
                            enabledOnView = true
                            break
                        }
                    }
                }

                if !enabledOnView {
                    npLog("   ⚠️ No available view found for controller \(controllerId) that allows automatic PiP")
                }
            }

            // Only set controllerWithAutomaticPiP if we actually enabled a view
            if enabledOnView {
                controllerWithAutomaticPiP = controllerId
                npLog("   ✅ Set controller \(controllerId) as the active automatic PiP controller")
            } else {
                npLog("   ⚠️ Not setting as active automatic PiP controller - no view was enabled")
            }
        } else {
            // Disable automatic PiP for ALL platform views of the specified controller
            npLog("🎬 Disabling automatic PiP for controller \(controllerId)")
            var disabledCount = 0
            for (viewKey, wrapper) in videoPlayerViews {
                if let view = wrapper.view, view.controllerId == controllerId {
                    let wasBefore = view.isAutomaticInlinePiPEnabled
                    view.setAutomaticInlinePiP(false)
                    npLog("   → ViewId \(viewKey): \(wasBefore) → \(view.isAutomaticInlinePiPEnabled)")
                    disabledCount += 1
                }
            }
            npLog("   → Disabled on \(disabledCount) platform view(s) for controller \(controllerId)")
            
            if controllerWithAutomaticPiP == controllerId {
                controllerWithAutomaticPiP = nil
            }
        }
    }
}

// MARK: - Weak Wrapper

/// Wrapper to hold weak reference to VideoPlayerView
class WeakVideoPlayerViewWrapper {
    weak var view: VideoPlayerView?
    
    init(view: VideoPlayerView) {
        self.view = view
    }
}

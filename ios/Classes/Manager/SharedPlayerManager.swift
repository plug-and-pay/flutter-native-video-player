import AVFoundation
import AVKit

// MARK: - Shared Player Manager

/// Manages shared AVPlayer instances across multiple platform views
/// Keeps players alive even when platform views are disposed
/// Note: Each platform view gets its own AVPlayerViewController, but they share the same AVPlayer
class SharedPlayerManager {
    static let shared = SharedPlayerManager()

    private var players: [Int: AVPlayer] = [:]

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

    struct PipSettings {
        let allowsPictureInPicture: Bool
        let canStartPictureInPictureAutomatically: Bool
        let showNativeControls: Bool
    }

    private init() {}

    /// Gets or creates a player for the given controller ID
    /// Returns a tuple (AVPlayer, Bool) where the Bool indicates if the player already existed (true) or was newly created (false)
    func getOrCreatePlayer(for controllerId: Int) -> (AVPlayer, Bool) {
        if let existingPlayer = players[controllerId] {
            return (existingPlayer, true)
        }

        let newPlayer = AVPlayer()
        players[controllerId] = newPlayer
        return (newPlayer, false)
    }

    /// Sets PiP settings for a controller
    /// This ensures the settings persist across all views using the same controller
    func setPipSettings(for controllerId: Int, allowsPictureInPicture: Bool, canStartPictureInPictureAutomatically: Bool, showNativeControls: Bool) {
        pipSettings[controllerId] = PipSettings(
            allowsPictureInPicture: allowsPictureInPicture,
            canStartPictureInPictureAutomatically: canStartPictureInPictureAutomatically,
            showNativeControls: showNativeControls
        )
        print("   ✅ Stored PiP settings for controller \(controllerId) - allows: \(allowsPictureInPicture), autoStart: \(canStartPictureInPictureAutomatically)")
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
        print("   ✅ Stored \(qualities.count) qualities for controller \(controllerId)")
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
            print("   ✅ Stored media info for controller \(controllerId): \(title)")
        } else {
            print("   ✅ Stored media info for controller \(controllerId)")
        }
    }

    /// Gets media info for a controller
    /// Returns nil if no media info has been stored for this controller
    func getMediaInfo(for controllerId: Int) -> [String: Any]? {
        return mediaInfoCache[controllerId]
    }

    /// Stops and clears player from all views using this controller
    func stopAllViewsForController(_ controllerId: Int) {
        print("🛑 [SharedPlayerManager] stopAllViewsForController called for controllerId: \(controllerId)")

        guard let player = players[controllerId] else {
            print("⚠️ [SharedPlayerManager] No player found for controllerId: \(controllerId)")
            return
        }

        print("⏸️ [SharedPlayerManager] Pausing player for controllerId: \(controllerId)")
        // Pause and clear the player
        player.pause()
        print("🧹 [SharedPlayerManager] Clearing current item for controllerId: \(controllerId)")
        player.replaceCurrentItem(with: nil)

        // Clear player reference from all views using this controller
        var clearedViewCount = 0
        for (viewId, weakView) in videoPlayerViews {
            if let view = weakView.view, view.controllerId == controllerId {
                print("🧹 [SharedPlayerManager] Clearing player from view \(viewId) for controllerId: \(controllerId)")
                view.player = nil
                clearedViewCount += 1
            }
        }

        print("✅ [SharedPlayerManager] Stopped all views (\(clearedViewCount) views) for controller ID: \(controllerId)")
    }

    /// Removes a player (called when explicitly disposed)
    func removePlayer(for controllerId: Int) {
        print("🗑️ [SharedPlayerManager] removePlayer called for controllerId: \(controllerId)")
        print("📊 [SharedPlayerManager] Current players count: \(players.count), players: \(players.keys.sorted())")

        // First stop all views using this player
        stopAllViewsForController(controllerId)

        // Remove player from manager
        print("🧹 [SharedPlayerManager] Removing player from players dict for controllerId: \(controllerId)")
        players.removeValue(forKey: controllerId)
        print("✅ [SharedPlayerManager] Player removed. New players count: \(players.count), players: \(players.keys.sorted())")

        // Remove all views for this controller
        let viewCountBefore = videoPlayerViews.count
        videoPlayerViews = videoPlayerViews.filter { $0.value.view?.controllerId != controllerId }
        let viewCountAfter = videoPlayerViews.count
        print("🧹 [SharedPlayerManager] Removed \(viewCountBefore - viewCountAfter) views. New view count: \(viewCountAfter)")

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

        print("✅ [SharedPlayerManager] Fully removed player for controller ID: \(controllerId)")
    }

    /// Clears all players (e.g., on logout)
    func clearAll() {
        players.removeAll()
        videoPlayerViews.removeAll()
        primaryViewIdForController.removeAll()
        pipSettings.removeAll()
        qualitiesCache.removeAll()
        qualityLevelsCache.removeAll()
        mediaInfoCache.removeAll()
        controllerWithAutomaticPiP = nil
        controllersWithManualPiP.removeAll()
    }
    
    /// Register a VideoPlayerView instance
    /// Multiple views can be registered for the same controller (e.g., list + detail screen)
    func registerVideoPlayerView(_ view: VideoPlayerView, viewId: Int64) {
        let key = "\(viewId)"
        videoPlayerViews[key] = WeakVideoPlayerViewWrapper(view: view)
        print("   → Registered view with ID \(viewId), total views: \(videoPlayerViews.count)")
    }
    
    /// Unregister a VideoPlayerView when it's disposed
    func unregisterVideoPlayerView(viewId: Int64) {
        let key = "\(viewId)"
        videoPlayerViews.removeValue(forKey: key)
        print("   → Unregistered view with ID \(viewId), remaining views: \(videoPlayerViews.count)")
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
                print("   🔍 Found alternative view \(view.viewId) for controller \(controllerId)")
                return view
            }
        }

        print("   ⚠️ No alternative view found for controller \(controllerId)")
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

        print("   🔍 Found \(views.count) view(s) for controller \(controllerId)")
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
            print("🎬 Marked controller \(controllerId) as having manual PiP active")
        } else {
            controllersWithManualPiP.remove(controllerId)
            print("🎬 Cleared manual PiP flag for controller \(controllerId)")
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
        print("   🎯 Set primary view for controller \(controllerId) → ViewId \(viewId)")
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
        
        print("📊 Current state: \(videoPlayerViews.count) active views registered")
        for (key, wrapper) in videoPlayerViews {
            if let view = wrapper.view {
                print("   - ViewId \(key): Controller \(view.controllerId ?? -1), canStartAuto: \(view.canStartPictureInPictureAutomatically), current: \(view.playerViewController.canStartPictureInPictureAutomaticallyFromInline)")
            }
        }
        
        if enabled {
            // Check if manual PiP is active for this controller
            if isManualPiPActive(controllerId) {
                print("⚠️ Cannot enable automatic PiP for controller \(controllerId) - manual PiP is active")
                return
            }

            // Disable automatic PiP on all other controllers first
            if let previousControllerId = controllerWithAutomaticPiP, previousControllerId != controllerId {
                print("🎬 Disabling automatic PiP for controller \(previousControllerId)")
                // Disable on ALL platform views for the previous controller
                var disabledCount = 0
                for (viewKey, wrapper) in videoPlayerViews {
                    if let view = wrapper.view, view.controllerId == previousControllerId {
                        let wasBefore = view.playerViewController.canStartPictureInPictureAutomaticallyFromInline
                        view.playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
                        let isAfter = view.playerViewController.canStartPictureInPictureAutomaticallyFromInline
                        print("   → ViewId \(viewKey): \(wasBefore) → \(isAfter)")
                        disabledCount += 1
                    }
                }
                print("   → Disabled on \(disabledCount) platform view(s) for controller \(previousControllerId)")
            }
            
            // Find the PRIMARY (most recently played) platform view for this controller
            print("🎬 Enabling automatic PiP for controller \(controllerId)")
            
            // First, disable ALL views for this controller
            for (viewKey, wrapper) in videoPlayerViews {
                if let view = wrapper.view, view.controllerId == controllerId {
                    view.playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
                }
            }
            
            // Then enable ONLY the primary view (the one that most recently called play)
            var enabledOnView = false
            if let primaryViewId = primaryViewIdForController[controllerId] {
                let key = "\(primaryViewId)"
                if let wrapper = videoPlayerViews[key], let view = wrapper.view {
                    print("   🔍 Checking primary view \(primaryViewId):")
                    print("      - view.canStartPictureInPictureAutomatically: \(view.canStartPictureInPictureAutomatically)")
                    print("      - playerViewController.allowsPictureInPicturePlayback: \(view.playerViewController.allowsPictureInPicturePlayback)")
                    print("      - player rate: \(view.player?.rate ?? -1)")

                    if view.canStartPictureInPictureAutomatically {
                        let wasBefore = view.playerViewController.canStartPictureInPictureAutomaticallyFromInline
                        view.playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
                        let isAfter = view.playerViewController.canStartPictureInPictureAutomaticallyFromInline
                        print("   → ViewId \(view.viewId): \(wasBefore) → \(isAfter) [PRIMARY]")
                        print("   ✅ Enabled on PRIMARY platform view for controller \(controllerId)")
                        enabledOnView = true
                    } else {
                        print("   ⚠️ Primary view doesn't allow automatic PiP")
                    }
                } else {
                    print("   ⚠️ Primary view (ViewId \(primaryViewId)) not found or disposed")
                }
            } else {
                print("   ⚠️ No primary view set for controller \(controllerId)")
            }

            // FALLBACK: If no primary view was found or it was disposed, pick ANY view for this controller
            // This handles the case where the primary view was disposed but other views still exist
            if !enabledOnView {
                print("   🔄 Looking for any available view for controller \(controllerId)")
                for (viewKey, wrapper) in videoPlayerViews {
                    if let view = wrapper.view, view.controllerId == controllerId {
                        if view.canStartPictureInPictureAutomatically {
                            let wasBefore = view.playerViewController.canStartPictureInPictureAutomaticallyFromInline
                            view.playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
                            let isAfter = view.playerViewController.canStartPictureInPictureAutomaticallyFromInline
                            print("   → ViewId \(view.viewId): \(wasBefore) → \(isAfter) [FALLBACK]")
                            print("   ✅ Enabled on fallback platform view for controller \(controllerId)")
                            // Set this as the new primary view
                            primaryViewIdForController[controllerId] = view.viewId
                            enabledOnView = true
                            break
                        }
                    }
                }

                if !enabledOnView {
                    print("   ⚠️ No available view found for controller \(controllerId) that allows automatic PiP")
                }
            }

            // Only set controllerWithAutomaticPiP if we actually enabled a view
            if enabledOnView {
                controllerWithAutomaticPiP = controllerId
                print("   ✅ Set controller \(controllerId) as the active automatic PiP controller")
            } else {
                print("   ⚠️ Not setting as active automatic PiP controller - no view was enabled")
            }
        } else {
            // Disable automatic PiP for ALL platform views of the specified controller
            print("🎬 Disabling automatic PiP for controller \(controllerId)")
            var disabledCount = 0
            for (viewKey, wrapper) in videoPlayerViews {
                if let view = wrapper.view, view.controllerId == controllerId {
                    let wasBefore = view.playerViewController.canStartPictureInPictureAutomaticallyFromInline
                    view.playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
                    let isAfter = view.playerViewController.canStartPictureInPictureAutomaticallyFromInline
                    print("   → ViewId \(viewKey): \(wasBefore) → \(isAfter)")
                    disabledCount += 1
                }
            }
            print("   → Disabled on \(disabledCount) platform view(s) for controller \(controllerId)")
            
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

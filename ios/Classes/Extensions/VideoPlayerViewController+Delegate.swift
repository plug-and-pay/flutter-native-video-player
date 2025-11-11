import AVKit

extension VideoPlayerView: AVPlayerViewControllerDelegate {
    public func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        print("🎬 PiP will start (AVPlayerViewController delegate - automatic or system triggered)")

        // Check if manual PiP was just triggered
        // We use this flag to distinguish between manual and automatic PiP starts
        let isManualStart = controllerId.flatMap { SharedPlayerManager.shared.isManualPiPActive($0) } ?? false
        if isManualStart {
            print("🎬 This is a MANUAL PiP start (user-triggered)")
        } else {
            print("🎬 This is an AUTOMATIC PiP start (system-triggered)")
        }

        // Mark PiP as active
        isPipCurrentlyActive = true

        // Disable automatic inline PiP while PiP is active
        // This prevents the system from trying to trigger automatic PiP again
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId {
                print("🎬 Disabling automatic inline PiP (PiP is starting)")
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: false)
            }
        }

        // Ensure this view owns the remote commands when entering PiP
        // This is critical because the PiP window needs working media controls
        var mediaInfo = currentMediaInfo

        // Fallback: Try to retrieve from SharedPlayerManager if not available locally
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                print("📱 Retrieved media info from SharedPlayerManager for PiP start")
                currentMediaInfo = mediaInfo // Update local copy
            }
        }

        if let mediaInfo = mediaInfo {
            let title = mediaInfo["title"] ?? "Unknown"
            print("📱 Setting Now Playing info and remote commands for PiP start: \(title)")
            setupNowPlayingInfo(mediaInfo: mediaInfo)
        } else {
            print("⚠️ No media info available for PiP - media controls may not work")
        }

        sendEvent("pipStart", data: ["isPictureInPicture": true])
    }

    public func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        print("🎬 PiP did start (AVPlayerViewController delegate)")
    }

    public func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        print("🎬 PiP will stop (AVPlayerViewController delegate) on view \(viewId)")

        // Determine if this was a manual or automatic PiP stop
        let wasManualPiP = controllerId.flatMap { SharedPlayerManager.shared.isManualPiPActive($0) } ?? false
        if wasManualPiP {
            print("🎬 This is a MANUAL PiP stop")
        } else {
            print("🎬 This is an AUTOMATIC PiP stop")
        }

        // Send pipStop event BEFORE PiP actually stops
        // This gives Flutter time to react before the native PiP window closes
        if eventSink != nil {
            print("✅ View \(viewId) is active - sending pipStop event (before stop)")
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        } else if let controllerIdValue = controllerId {
            // Try any view for this controller
            let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            var eventSent = false
            for view in allViews where view.eventSink != nil {
                print("✅ Sending pipStop event to view \(view.viewId) (before stop)")
                view.sendEvent("pipStop", data: ["isPictureInPicture": false])
                eventSent = true
                break
            }
            if !eventSent {
                print("⚠️ No active view with listener found - pipStop event cannot be sent")
            }
        }
    }

    public func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        print("🎬 PiP did stop (AVPlayerViewController delegate) on view \(viewId)")

        // Determine if this was a manual PiP stop
        let wasManualPiP = controllerId.flatMap { SharedPlayerManager.shared.isManualPiPActive($0) } ?? false

        // Mark PiP as inactive
        isPipCurrentlyActive = false

        // Clear manual PiP flag if this was a manual PiP session
        if wasManualPiP, let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
            print("   → Cleared manual PiP flag for controller \(controllerIdValue)")
        }

        // Re-establish ownership and Now Playing info when PiP stops
        // This ensures media controls continue working after exiting PiP
        var mediaInfo = currentMediaInfo

        // Fallback: Try to retrieve from SharedPlayerManager if not available locally
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                print("📱 Retrieved media info from SharedPlayerManager for PiP stop")
                currentMediaInfo = mediaInfo // Update local copy
            }
        }

        // ALWAYS re-establish Now Playing info after PiP stops, even if we already have it
        // This is critical when the app was backgrounded and then came back to foreground
        if let mediaInfo = mediaInfo {
            let title = mediaInfo["title"] ?? "Unknown"
            print("📱 Re-establishing Now Playing info and remote commands for PiP stop: \(title)")
            setupNowPlayingInfo(mediaInfo: mediaInfo)
        } else {
            print("⚠️ No media info available after PiP stop")
            // Try to find ANY view with this controller that has media info
            if let controllerIdValue = controllerId {
                let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
                for view in allViews {
                    if let viewMediaInfo = view.currentMediaInfo {
                        print("📱 Found media info on view \(view.viewId), using it for PiP stop")
                        currentMediaInfo = viewMediaInfo
                        setupNowPlayingInfo(mediaInfo: viewMediaInfo)
                        break
                    }
                }
            }
        }

        // Re-enable automatic PiP if this was a MANUAL PiP session and automatic PiP was requested
        // For automatic PiP sessions, it will auto re-enable when video plays again
        if #available(iOS 14.2, *) {
            if wasManualPiP, let controllerIdValue = controllerId, canStartPictureInPictureAutomatically {
                print("🎬 Re-enabling automatic PiP after MANUAL PiP stop")
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
            }
        }

        // Emit current state to sync UI after PiP stops
        // Note: pipStop event was already sent in willStopPictureInPicture
        if eventSink != nil {
            print("✅ Emitting current state after PiP stop")
            emitCurrentState()
        } else if let controllerIdValue = controllerId {
            // Try any view for this controller
            let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            for view in allViews where view.eventSink != nil {
                print("✅ Emitting current state to view \(view.viewId) after PiP stop")
                view.emitCurrentState()
                break
            }
        }
    }

    public func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
        print("❌ PiP failed to start (AVPlayerViewController): \(error.localizedDescription)")
    }
    
    // This delegate method is called when automatic PiP is about to start (iOS 14.2+)
    // No @available annotation needed as the method is optional in the protocol
    public func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        print("🎬 System asked if should auto-dismiss for automatic PiP")
        // Return false to keep the view visible when automatic PiP starts
        // Return true to dismiss the view controller when PiP starts automatically
        return false
    }
    
    // Handle when the user dismisses fullscreen by swiping down or tapping Done
    @available(iOS 13.0, *)
    public func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        // Store the playback state before dismissing
        let wasPlaying = self.player?.rate != 0
        
        // Send fullscreen exit event when user dismisses fullscreen
        coordinator.animate(alongsideTransition: nil) { _ in
            // Check if this is the fullscreen view controller we're tracking
            if playerViewController == self.fullscreenPlayerViewController {
                self.fullscreenPlayerViewController = nil
                
                // Resume playback if it was playing before
                if wasPlaying {
                    self.player?.play()
                }
                
                self.sendEvent("fullscreenChange", data: ["isFullscreen": false])
            }
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
@available(iOS 14.0, *)
extension VideoPlayerView: AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎬 Custom PiP controller will start")

        // Mark PiP as active
        isPipCurrentlyActive = true

        // Disable automatic inline PiP while PiP is active
        // This prevents the system from trying to trigger automatic PiP again
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId {
                print("🎬 Disabling automatic inline PiP (custom PiP is starting)")
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: false)
            }
        }

        // Ensure player view stays visible and keeps playing
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0

        // Ensure this view owns the remote commands when entering PiP
        // This is critical because the PiP window needs working media controls
        var mediaInfo = currentMediaInfo

        // Fallback: Try to retrieve from SharedPlayerManager if not available locally
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                print("📱 Retrieved media info from SharedPlayerManager for custom PiP start")
                currentMediaInfo = mediaInfo // Update local copy
            }
        }

        if let mediaInfo = mediaInfo {
            let title = mediaInfo["title"] ?? "Unknown"
            print("📱 Setting Now Playing info and remote commands for custom PiP start: \(title)")
            setupNowPlayingInfo(mediaInfo: mediaInfo)
        } else {
            print("⚠️ No media info available for custom PiP - media controls may not work")
        }

        sendEvent("pipStart", data: ["isPictureInPicture": true])
    }
    
    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎬 Custom PiP controller did start")
        
        // Make sure the player view is still visible after PiP starts
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0
        
        // Ensure video continues playing
        if let player = player, player.rate == 0 && player.currentItem?.status == .readyToPlay {
            player.play()
        }
    }
    
    public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎬 Custom PiP controller will stop on view \(viewId)")

        // Send pipStop event BEFORE PiP actually stops
        // This gives Flutter time to react before the native PiP window closes
        if eventSink != nil {
            print("✅ View \(viewId) is active - sending pipStop event (before stop)")
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        } else if let controllerIdValue = controllerId {
            // Try any view for this controller
            let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            var eventSent = false
            for view in allViews where view.eventSink != nil {
                print("✅ Sending pipStop event to view \(view.viewId) (before stop)")
                view.sendEvent("pipStop", data: ["isPictureInPicture": false])
                eventSent = true
                break
            }
            if !eventSent {
                print("⚠️ No active view with listener found - pipStop event cannot be sent")
            }
        }
    }
    
    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎬 Custom PiP controller did stop on view \(viewId)")

        // Check if video was playing before PiP stopped
        let wasPlaying = player?.rate ?? 0 > 0
        print("   → Video was playing before stop: \(wasPlaying)")

        // Mark PiP as inactive
        isPipCurrentlyActive = false

        // Clear the restoration flag after a delay to allow any pending view disposals to complete
        // This ensures cleanupRemoteCommandOwnership sees the flag during the disposal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isPipRestoringUI = false
            print("   → Cleared PiP restoration flag")
        }

        // Ensure player view is visible after exiting PiP
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0

        // IMPORTANT: Clear manual PiP flag FIRST before re-enabling anything
        // This allows the automatic PiP system to work again
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
            print("   → Cleared manual PiP flag for controller \(controllerIdValue)")
        }

        // CRITICAL: Re-enable AVPlayerViewController's PiP management immediately
        // This was disabled when manual PiP started to prevent conflicts
        if let controllerIdValue = controllerId {
            if let pipSettings = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue) {
                playerViewController.allowsPictureInPicturePlayback = pipSettings.allowsPictureInPicture
                print("   → Re-enabled AVPlayerViewController PiP: \(pipSettings.allowsPictureInPicture)")
            } else {
                playerViewController.allowsPictureInPicturePlayback = true
                print("   → Re-enabled AVPlayerViewController PiP (fallback): true")
            }
        }

        // CRITICAL: Destroy the custom PiP controller so it doesn't interfere with automatic PiP
        // The custom controller "owns" the player layer and prevents AVPlayerViewController's
        // automatic PiP from working on the same layer
        pipController = nil
        print("   → Destroyed custom PiP controller to allow automatic PiP")

        // Resume playback if it was playing before
        // Keep video playing so automatic PiP can trigger when backgrounding
        if wasPlaying {
            print("   → Video will resume automatically")
            // Don't need to manually resume - iOS will handle it
        }

        // Re-establish ownership and Now Playing info when PiP stops
        // This ensures media controls continue working after exiting PiP
        var mediaInfo = currentMediaInfo

        // Fallback: Try to retrieve from SharedPlayerManager if not available locally
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                print("📱 Retrieved media info from SharedPlayerManager for custom PiP stop")
                currentMediaInfo = mediaInfo // Update local copy
            }
        }

        // ALWAYS re-establish Now Playing info after PiP stops, even if we already have it
        // This is critical when the app was backgrounded and then came back to foreground
        if let mediaInfo = mediaInfo {
            let title = mediaInfo["title"] ?? "Unknown"
            print("📱 Re-establishing Now Playing info and remote commands for custom PiP stop: \(title)")

            // Force re-registration of remote commands because PiP might have cleared them
            forceReregisterRemoteCommands()
        } else {
            print("⚠️ No media info available after custom PiP stop")
            // Try to find ANY view with this controller that has media info
            if let controllerIdValue = controllerId {
                let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
                for view in allViews {
                    if let viewMediaInfo = view.currentMediaInfo {
                        print("📱 Found media info on view \(view.viewId), using it for PiP stop")
                        currentMediaInfo = viewMediaInfo
                        setupNowPlayingInfo(mediaInfo: viewMediaInfo)
                        break
                    }
                }
            }
        }

        // Re-enable automatic PiP ALWAYS if automatic PiP was requested
        // Don't check if playing - let the system handle it
        if #available(iOS 14.2, *) {
            if let controllerIdValue = controllerId {
                print("🎬 Checking if should re-enable automatic PiP:")
                print("   - controllerId: \(controllerIdValue)")
                print("   - view.canStartPictureInPictureAutomatically: \(canStartPictureInPictureAutomatically)")
                print("   - viewId: \(viewId)")

                // Check both the view's setting AND the shared settings
                if canStartPictureInPictureAutomatically {
                    print("🎬 Re-enabling automatic PiP after custom PiP stop (from view property)")
                    SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                } else if let pipSettings = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue),
                          pipSettings.canStartPictureInPictureAutomatically {
                    print("🎬 Re-enabling automatic PiP after custom PiP stop (from shared settings)")
                    SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                } else {
                    print("⚠️ NOT re-enabling automatic PiP - neither view nor shared settings allow it")
                }
            }
        }

        // Emit current state to sync UI after PiP stops
        // Note: pipStop event was already sent in willStopPictureInPicture
        if eventSink != nil {
            print("✅ Emitting current state after custom PiP stop")
            emitCurrentState()
        } else if let controllerIdValue = controllerId {
            // Try any view for this controller
            let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            for view in allViews where view.eventSink != nil {
                print("✅ Emitting current state to view \(view.viewId) after custom PiP stop")
                view.emitCurrentState()
                break
            }
        }
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("❌ Custom PiP controller failed to start: \(error.localizedDescription)")
        
        // Ensure view is visible if PiP fails
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("🎬 Restoring UI from PiP on view \(viewId)")

        // CRITICAL: Mark that we're restoring UI from PiP
        // This prevents cleanupRemoteCommandOwnership from clearing Now Playing info
        // during the view disposal/recreation that happens when app foregrounds
        isPipRestoringUI = true

        // CRITICAL: Get media info from SharedPlayerManager FIRST before anything else
        // This ensures we have it even if views are being disposed/recreated during app foregrounding
        var mediaInfoFromCache: [String: Any]?
        if let controllerIdValue = controllerId {
            mediaInfoFromCache = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfoFromCache != nil {
                print("📱 Retrieved media info from SharedPlayerManager cache for PiP restore")
            }
        }

        // Check if we have an event sink (indicates the view is still active)
        if eventSink != nil {
            print("✅ View \(viewId) is still active - restoring UI normally")
            // Restore the player view
            playerViewController.view.isHidden = false
            playerViewController.view.alpha = 1.0

            // CRITICAL: Re-establish Now Playing info when restoring from background
            // Use cached media info (most reliable) or fall back to current view's media info
            let mediaInfo = mediaInfoFromCache ?? currentMediaInfo

            if let mediaInfo = mediaInfo {
                let title = mediaInfo["title"] ?? "Unknown"
                print("📱 Re-establishing Now Playing info for PiP restore (active view): \(title)")
                currentMediaInfo = mediaInfo // Update local copy
                setupNowPlayingInfo(mediaInfo: mediaInfo)
            } else {
                print("⚠️ No media info available for PiP restore (active view)")
            }

            completionHandler(true)
            return
        }

        // If we reach here, the original view has been disposed
        print("⚠️ Original view \(viewId) was disposed - attempting to find alternative view")

        // Try to find another active view for the same controller
        if let controllerIdValue = controllerId,
           let alternativeView = SharedPlayerManager.shared.findAnotherViewForController(controllerIdValue, excluding: viewId) {
            print("✅ Found alternative view \(alternativeView.viewId) for controller \(controllerIdValue)")

            // Restore UI on the alternative view
            alternativeView.playerViewController.view.isHidden = false
            alternativeView.playerViewController.view.alpha = 1.0

            // CRITICAL: Re-establish Now Playing info and remote command ownership
            // Use cached media info (most reliable) or fall back to alternative view's media info
            let mediaInfo = mediaInfoFromCache ?? alternativeView.currentMediaInfo

            if let mediaInfo = mediaInfo {
                let title = mediaInfo["title"] ?? "Unknown"
                print("📱 Re-establishing Now Playing info for PiP restore (alternative view): \(title)")
                alternativeView.currentMediaInfo = mediaInfo // Update local copy
                alternativeView.setupNowPlayingInfo(mediaInfo: mediaInfo)
            } else {
                print("⚠️ No media info available for PiP restore (alternative view)")
            }

            // The alternative view should send pipStop event via its delegate
            // We complete with success since we found an alternative
            completionHandler(true)
        } else {
            print("❌ No alternative view found - PiP will exit without restoration")

            // No alternative view exists, so we can't restore the UI
            // Complete with false to indicate restoration failed
            // iOS will gracefully exit PiP without animation back to the app
            completionHandler(false)
        }
    }
}
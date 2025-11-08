import AVKit

extension VideoPlayerView: AVPlayerViewControllerDelegate {
    public func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        print("🎬 PiP will start (AVPlayerViewController delegate - automatic or system triggered)")

        // Ensure this view owns the remote commands when entering PiP
        // This is critical because the PiP window needs working media controls
        if let mediaInfo = currentMediaInfo {
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

    public func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        print("🎬 PiP did stop (AVPlayerViewController delegate)")

        // Re-establish ownership and Now Playing info when PiP stops
        // This ensures media controls continue working after exiting PiP
        if let mediaInfo = currentMediaInfo {
            let title = mediaInfo["title"] ?? "Unknown"
            print("📱 Re-establishing Now Playing info and remote commands for PiP stop: \(title)")
            setupNowPlayingInfo(mediaInfo: mediaInfo)
        } else {
            print("⚠️ No media info available after PiP stop")
        }

        sendEvent("pipStop", data: ["isPictureInPicture": false])

        // Re-emit all current states after exiting PiP to ensure UI is in sync
        self.emitCurrentState()
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

        // Ensure player view stays visible and keeps playing
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0

        // Ensure this view owns the remote commands when entering PiP
        // This is critical because the PiP window needs working media controls
        if let mediaInfo = currentMediaInfo {
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
        print("🎬 Custom PiP controller will stop")
    }
    
    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        print("🎬 Custom PiP controller did stop")

        // Ensure player view is visible after exiting PiP
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0

        // Re-establish ownership and Now Playing info when PiP stops
        // This ensures media controls continue working after exiting PiP
        if let mediaInfo = currentMediaInfo {
            let title = mediaInfo["title"] ?? "Unknown"
            print("📱 Re-establishing Now Playing info and remote commands for custom PiP stop: \(title)")
            setupNowPlayingInfo(mediaInfo: mediaInfo)
        } else {
            print("⚠️ No media info available after custom PiP stop")
        }

        sendEvent("pipStop", data: ["isPictureInPicture": false])

        // Re-emit all current states after exiting PiP to ensure UI is in sync
        self.emitCurrentState()
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("❌ Custom PiP controller failed to start: \(error.localizedDescription)")
        
        // Ensure view is visible if PiP fails
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0
    }
    
    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        print("🎬 Restoring UI from PiP")
        
        // Restore the player view
        playerViewController.view.isHidden = false
        playerViewController.view.alpha = 1.0
        
        completionHandler(true)
    }
}
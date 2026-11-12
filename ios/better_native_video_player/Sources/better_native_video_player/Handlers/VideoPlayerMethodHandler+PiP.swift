import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer

// Picture-in-Picture: availability, manual enter/exit, automatic inline PiP.
// Split from VideoPlayerMethodHandler.swift for maintainability;
// all members keep full access to VideoPlayerView state.
extension VideoPlayerView {
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
            // Texture views have no on-screen AVPlayerLayer to PiP from. The
            // Dart controller swaps the tile to a platform view BEFORE
            // calling this; reaching here means that swap was bypassed.
            if usesTextureView {
                npLog("❌ PiP requested on texture view \(viewId)")
                result(FlutterError(
                    code: "TEXTURE_MODE",
                    message: "Picture-in-Picture is not available on a texture-rendered view.",
                    details: nil))
                return
            }

            // Check if video is loaded and ready
            guard let player = player, let currentItem = player.currentItem else {
                npLog("❌ No video loaded for PiP")
                result(FlutterError(code: "NO_VIDEO", message: "No video loaded.", details: nil))
                return
            }
            
            guard currentItem.status == .readyToPlay else {
                npLog("❌ Video not ready for PiP")
                result(FlutterError(code: "NOT_READY", message: "Video is not ready to play.", details: nil))
                return
            }
            
            // Check if PiP is supported on device
            guard AVPictureInPictureController.isPictureInPictureSupported() else {
                npLog("❌ PiP not supported on this device")
                result(FlutterError(code: "NOT_SUPPORTED", message: "Picture-in-Picture is not supported on this device.", details: nil))
                return
            }

            npLog("🎬 Starting manual PiP")

            // Mark manual PiP as active for this controller
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: true)
            }

            // CRITICAL: Temporarily disable AVPlayerViewController's PiP while using custom controller
            // This prevents the AVPlayerViewController from starting its own PiP simultaneously
            // NOTE: We do this AFTER the checks, so it doesn't interfere with the next manual PiP attempt
            // (a light view has no AVPlayerViewController competing for the layer)
            if usesViewControllerDisplay {
                playerViewController.allowsPictureInPicturePlayback = false
                npLog("   → Temporarily disabled AVPlayerViewController PiP during manual start")

                // Also disable automatic inline PiP
                if #available(iOS 14.2, *) {
                    playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
                    npLog("   → Temporarily disabled automatic inline PiP during manual start")
                }
            }

            // Start PiP using the controller
            // Wait for the controller to be ready with retries. The
            // controller creation itself is also retried: when a tile was
            // just (re)created — e.g. the texture→platform-view PiP swap —
            // the AVPlayerLayer only exists after the view's first layout.
            var attempt = 0
            let maxAttempts = 5

            func tryStartPip() {
                attempt += 1
                npLog("🎬 Attempt \(attempt)/\(maxAttempts) to start PiP")

                let hadController = pipController != nil
                if ensureInlinePipController() == nil, attempt < maxAttempts {
                    npLog("   → No player layer yet, retrying in 0.2s...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard self != nil else { return }
                        tryStartPip()
                    }
                    return
                }
                if !hadController, pipController != nil, attempt < maxAttempts {
                    // A just-created AVPictureInPictureController needs a
                    // beat before startPictureInPicture takes effect —
                    // starting in the same run-loop turn is silently
                    // ignored (observed on iOS 26 after the texture→light
                    // PiP swap). Give it one retry interval.
                    npLog("   → PiP controller freshly created, starting on next attempt...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard self != nil else { return }
                        tryStartPip()
                    }
                    return
                }

                if let pipController = pipController {
                    npLog("   → isPictureInPicturePossible: \(pipController.isPictureInPicturePossible)")

                    if pipController.isPictureInPicturePossible {
                        npLog("🎬 Starting manual PiP now")
                        awaitPipStart(result)
                        pipController.startPictureInPicture()
                    } else if attempt < maxAttempts {
                        // Retry after a short delay
                        npLog("   → PiP not ready yet, retrying in 0.2s...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            guard self != nil else { return }
                            tryStartPip()
                        }
                    } else {
                        npLog("❌ PiP not possible after \(maxAttempts) attempts")
                        if let controllerIdValue = controllerId {
                            SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
                            // Re-enable AVPlayerViewController PiP since we're not starting
                            if usesViewControllerDisplay {
                                playerViewController.allowsPictureInPicturePlayback = true
                            }
                        }
                        result(FlutterError(code: "PIP_NOT_POSSIBLE", message: "Picture-in-Picture is not possible at this time. Make sure the video is playing and loaded.", details: nil))
                    }
                } else {
                    npLog("❌ PiP controller is nil")
                    if let controllerIdValue = controllerId {
                        SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
                    }
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

    /// Answers a manual PiP start once AVKit reports the outcome. The start
    /// is asynchronous and can still fail after isPictureInPicturePossible
    /// (for example when it was not started from a user action), so
    /// answering right away reported PiP that never opened.
    func awaitPipStart(_ result: @escaping FlutterResult) {
        pendingPipStartReply?.send(false)
        let reply = PipStartReply(result)
        pendingPipStartReply = reply
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            reply.send(self?.pipController?.isPictureInPictureActive ?? false)
            if self?.pendingPipStartReply === reply {
                self?.pendingPipStartReply = nil
            }
        }
    }

    /// Answers the pending manual PiP start, if any.
    func finishPipStart(_ value: Any?) {
        pendingPipStartReply?.send(value)
        pendingPipStartReply = nil
    }

    /// Lets a view kept for its PiP window go once that window closed (see
    /// `SharedPlayerManager.keepViewForPip`). Without another view of its
    /// controller on screen the player pauses: no audio without a player.
    /// With one (the screen was opened again), playback goes on there: AVKit
    /// pauses when the window returns to this view's off-screen layer.
    func releaseIfKeptForPip() {
        guard channelsTornDown else { return }

        if let controllerIdValue = controllerId {
            if SharedPlayerManager.shared.findAnotherViewForController(controllerIdValue, excluding: viewId) == nil {
                npLog("⏸️ PiP closed after view \(viewId) was disposed - pausing controller \(controllerIdValue)")
                player?.pause()
            } else if wasPlayingWhenPipStopped {
                npLog("▶️ PiP of disposed view \(viewId) closed - playing on in another view of controller \(controllerIdValue)")
                player?.play()
            }
        }

        // Next turn: the AVKit delegate call that got here still runs on this view.
        let viewId = self.viewId
        DispatchQueue.main.async {
            SharedPlayerManager.shared.releaseViewKeptForPip(viewId)
        }
    }

    /// Takes over the open PiP window of [host], a disposed view of the same
    /// controller kept for that window, whose display surface this view
    /// adopted in init. A new view used to get a surface of its own: it showed
    /// the video playing next to the window, and closing the window sent it
    /// back to the old, off-screen surface. This view is now the window's
    /// delegate, so it closes into this view; [host] is let go.
    @available(iOS 14.0, *)
    func takeOverPipWindow(from host: VideoPlayerView) {
        npLog("🎬 View \(viewId) takes over the PiP window of disposed view \(host.viewId)")

        // Manual PiP: the AVPictureInPictureController on the adopted layer.
        // AVPlayerViewController PiP: init already made this view its delegate.
        pipController = host.pipController
        pipController?.delegate = self
        isPipCurrentlyActive = true

        // A manual PiP keeps AVPlayerViewController's own PiP off until the
        // window closes (see handleEnterPictureInPicture); init re-applied it.
        if pipController != nil, usesViewControllerDisplay {
            playerViewController.allowsPictureInPicturePlayback = false
        }

        host.pipController = nil
        host.isPipCurrentlyActive = false
        host.handedOverPipWindow = true

        // Next turn, once this view is fully set up: the host's deinit hands
        // the remote commands to this view.
        let hostViewId = host.viewId
        DispatchQueue.main.async {
            SharedPlayerManager.shared.releaseViewKeptForPip(hostViewId)
        }
    }

    /// Finds the AVPlayerLayer in the view hierarchy
    func findPlayerLayer() -> AVPlayerLayer? {
        // Texture views have no on-screen layer (the fix-layer is zero-sized
        // and unusable for PiP)
        if usesTextureView {
            return nil
        }
        // Light views own their layer directly
        if let lightView = lightView {
            return lightView.playerLayer
        }
        // Get the player layer from the AVPlayerViewController's view
        if let playerView = playerViewController.view {
            return findPlayerLayerInView(playerView)
        }
        return nil
    }

    /// Recursively searches for AVPlayerLayer in view hierarchy
    func findPlayerLayerInView(_ view: UIView) -> AVPlayerLayer? {
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
                    npLog("🛑 Stopping PiP from current view")
                    // By the time AVKit asks to restore, it has picked where
                    // to fly: take a surface that is not fully visible out
                    // of the window before stopping (see the restore delegate).
                    pipStopRequestedByCode = true
                    queryFullyVisible { [weak self] visible in
                        if !visible, let self = self {
                            npLog("ℹ️ View \(self.viewId) is not fully visible - detaching it before PiP stops")
                            self.detachInlineSurfaceUntilPipStops()
                        }
                        pipController.stopPictureInPicture()
                    }
                    result(true)
                    return
                }
            }

            // If this view doesn't have an active PiP, check other views for the same controller
            // This handles the case where user navigated away from the detail screen back to list
            if let controllerIdValue = controllerId {
                npLog("🔍 Checking other views for controller \(controllerIdValue) to stop PiP")
                let allViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)

                for view in allViews {
                    if let otherPipController = view.pipController,
                       otherPipController.isPictureInPictureActive {
                        npLog("🛑 Found active PiP on view \(view.viewId), stopping it")
                        view.pipStopRequestedByCode = true
                        otherPipController.stopPictureInPicture()
                        result(true)
                        return
                    }
                }
            }

            // No active PiP found on any view
            npLog("⚠️ No active PiP found for this controller")
            result(false)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "PiP not supported on this iOS version", details: nil))
        }
    }

    func handleEnableAutomaticInlinePip(result: @escaping FlutterResult) {
        if #available(iOS 14.2, *) {
            // Check if video is loaded and playing
            guard let player = player, let currentItem = player.currentItem else {
                npLog("❌ Cannot enable automatic PiP: No video loaded")
                result(FlutterError(code: "NO_VIDEO", message: "No video loaded.", details: nil))
                return
            }

            guard currentItem.status == .readyToPlay else {
                npLog("❌ Cannot enable automatic PiP: Video not ready")
                result(FlutterError(code: "NOT_READY", message: "Video is not ready to play.", details: nil))
                return
            }

            // Check if PiP is supported on device
            guard AVPictureInPictureController.isPictureInPictureSupported() else {
                npLog("❌ Cannot enable automatic PiP: PiP not supported on this device")
                result(FlutterError(code: "NOT_SUPPORTED", message: "Picture-in-Picture is not supported on this device.", details: nil))
                return
            }

            npLog("🎬 Enabling automatic inline PiP")

            // Enable automatic PiP on this view's display surface
            setAutomaticInlinePiP(true)

            // Also update the stored setting if this is a shared player
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                npLog("✅ Automatic inline PiP enabled for controller \(controllerIdValue)")
            } else {
                npLog("✅ Automatic inline PiP enabled for non-shared player")
            }

            result(true)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "Automatic inline PiP requires iOS 14.2+", details: nil))
        }
    }

    func handleDisableAutomaticInlinePip(result: @escaping FlutterResult) {
        if #available(iOS 14.2, *) {
            npLog("🎬 Disabling automatic inline PiP")

            // Disable automatic PiP on this view's display surface
            setAutomaticInlinePiP(false)

            // Also update the stored setting if this is a shared player
            if let controllerIdValue = controllerId {
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: false)
                npLog("✅ Automatic inline PiP disabled for controller \(controllerIdValue)")
            } else {
                npLog("✅ Automatic inline PiP disabled for non-shared player")
            }

            result(true)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "Automatic inline PiP requires iOS 14.2+", details: nil))
        }
    }
}

/// A FlutterResult that is answered at most once: the PiP start reply is
/// raced by the AVKit delegate and a timeout.
final class PipStartReply {
    private var result: FlutterResult?

    init(_ result: @escaping FlutterResult) {
        self.result = result
    }

    func send(_ value: Any?) {
        guard let result = result else { return }
        self.result = nil
        result(value)
    }
}

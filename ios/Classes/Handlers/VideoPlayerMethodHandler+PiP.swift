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
            if !usesLightView {
                playerViewController.allowsPictureInPicturePlayback = false
                npLog("   → Temporarily disabled AVPlayerViewController PiP during manual start")

                // Also disable automatic inline PiP
                if #available(iOS 14.2, *) {
                    playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
                    npLog("   → Temporarily disabled automatic inline PiP during manual start")
                }
            }

            // Get or create the PiP controller for this player layer
            // Reuse existing controller if available, or create new one
            if ensureInlinePipController() == nil {
                npLog("❌ Could not create PiP controller (no player layer?)")
                if let controllerIdValue = controllerId {
                    SharedPlayerManager.shared.setManualPiPActive(controllerIdValue, active: false)
                }
                result(FlutterError(code: "NO_LAYER", message: "Could not find player layer", details: nil))
                return
            }

            // Start PiP using the controller
            // Wait for the controller to be ready with retries
            var attempt = 0
            let maxAttempts = 3

            func tryStartPip() {
                attempt += 1
                npLog("🎬 Attempt \(attempt)/\(maxAttempts) to start PiP")

                if let pipController = pipController {
                    npLog("   → isPictureInPicturePossible: \(pipController.isPictureInPicturePossible)")

                    if pipController.isPictureInPicturePossible {
                        npLog("🎬 Starting manual PiP now")
                        pipController.startPictureInPicture()
                        result(true)
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
                            if !usesLightView {
                                playerViewController.allowsPictureInPicturePlayback = true
                            }
                        }
                        result(FlutterError(code: "PIP_NOT_POSSIBLE", message: "Picture-in-Picture is not possible at this time. Make sure the video is playing and loaded.", details: nil))
                    }
                } else {
                    npLog("❌ PiP controller is nil")
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
    func findPlayerLayer() -> AVPlayerLayer? {
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
                    pipController.stopPictureInPicture()
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

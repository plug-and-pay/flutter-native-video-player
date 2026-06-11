import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer

// Native fullscreen presentation (swipe-dismiss prevention incl.).
// Split from VideoPlayerMethodHandler.swift for maintainability;
// all members keep full access to VideoPlayerView state.
extension VideoPlayerView {
    func handleEnterFullScreen(result: @escaping FlutterResult) {
        if let viewController = UIApplication.shared.keyWindow?.rootViewController {
            // Create a NEW player view controller for fullscreen
            // This prevents the embedded view from being removed from Flutter's view hierarchy
            let fullscreenPlayerViewController = AVPlayerViewController()
            fullscreenPlayerViewController.player = player
            fullscreenPlayerViewController.showsPlaybackControls = true
            fullscreenPlayerViewController.delegate = self

            if preventFullscreenSwipeDismiss {
                // Use .fullScreen modal style to prevent the iOS 13+ sheet dismiss gesture.
                fullscreenPlayerViewController.modalPresentationStyle = .fullScreen
                if #available(iOS 13.0, *) {
                    fullscreenPlayerViewController.isModalInPresentation = true
                }
            }

            // Store reference to dismiss later
            self.fullscreenPlayerViewController = fullscreenPlayerViewController

            // Fullscreen shows the full display: lift the viewport quality cap
            liftViewportCap()

            viewController.present(fullscreenPlayerViewController, animated: true) {
                // Disable swipe/pinch gesture recognizers on the fullscreen player view
                // hierarchy. This prevents the user from accidentally swiping up/down to
                // exit AVPlayerViewController's internal fullscreen, which causes a black
                // screen. Button taps (Done, play/pause, seek bar, etc.) keep working.
                // Adopted from community PR #32 by @anirudhrao-github.
                if self.preventFullscreenSwipeDismiss {
                    self.disableSwipeGestures(in: fullscreenPlayerViewController.view)
                }

                self.sendEvent("fullscreenChange", data: ["isFullscreen": true])
                result(nil)
            }
        } else {
            result(FlutterError(code: "FULLSCREEN_ERROR", message: "Could not present fullscreen player", details: nil))
        }
    }

    /// Recursively disables pan and pinch gesture recognizers in the view hierarchy.
    /// This prevents AVPlayerViewController's internal swipe-to-dismiss and
    /// pinch-to-shrink gestures while keeping all button taps working.
    func disableSwipeGestures(in view: UIView) {
        for gesture in view.gestureRecognizers ?? [] {
            if gesture is UIPanGestureRecognizer || gesture is UIPinchGestureRecognizer {
                gesture.isEnabled = false
            }
        }
        for subview in view.subviews {
            disableSwipeGestures(in: subview)
        }
    }

    func handleExitFullScreen(result: @escaping FlutterResult) {
        // Store the playback state before dismissing
        let wasPlaying = player?.rate != 0
        
        // Dismiss the fullscreen player view controller if it exists
        if let fullscreenVC = fullscreenPlayerViewController {
            // Release the video layer from the fullscreen VC before dismiss so the embedded view can show it again
            fullscreenVC.player = nil
            fullscreenVC.dismiss(animated: true) {
                // Clear the reference
                self.fullscreenPlayerViewController = nil

                // Back inline: restore the viewport quality cap
                self.applyViewportCapIfAppropriate()

                // Resume playback if it was playing before
                if wasPlaying {
                    self.player?.play()
                }

                // Re-bind the player to the embedded view on the next run loop after the transition has fully finished
                DispatchQueue.main.async {
                    self.rebindInlinePlayer()
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
}

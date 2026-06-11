import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer

// Native controls toggle and AirPlay (picker, detection, disconnect).
// Split from VideoPlayerMethodHandler.swift for maintainability;
// all members keep full access to VideoPlayerView state.
extension VideoPlayerView {
    func handleSetShowNativeControls(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let show = arguments["show"] as? Bool else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
        }

        // Set controls visibility for embedded player. Light and texture
        // views cannot render native controls (documented limitation:
        // recreate the view with showNativeControls instead).
        if !usesViewControllerDisplay {
            if show {
                npLog("⚠️ setShowNativeControls(true) ignored - view \(viewId) has no native controls surface")
            }
        } else {
            playerViewController.showsPlaybackControls = show
        }

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

    func handleDisconnectAirPlay(result: @escaping FlutterResult) {
        guard let player = player else {
            result(FlutterError(code: "NO_PLAYER", message: "Player not initialized", details: nil))
            return
        }

        // Check if currently connected to AirPlay
        guard player.isExternalPlaybackActive else {
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected to AirPlay", details: nil))
            return
        }

        // Disable external playback to disconnect from AirPlay
        // This will stop sending video to the AirPlay device
        player.usesExternalPlaybackWhileExternalScreenIsActive = false

        // Re-enable it after a short delay so AirPlay can be used again later
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
            npLog("AirPlay disconnected and re-enabled for future use")
        }

        result(nil)
    }

    func handleStartAirPlayDetection(result: @escaping FlutterResult) {
        if #available(iOS 11.0, *) {
            SharedPlayerManager.shared.startAirPlayRouteDetection()
            result(nil)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "AirPlay detection requires iOS 11.0+", details: nil))
        }
    }

    func handleStopAirPlayDetection(result: @escaping FlutterResult) {
        if #available(iOS 11.0, *) {
            SharedPlayerManager.shared.stopAirPlayRouteDetection()
            result(nil)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "AirPlay detection requires iOS 11.0+", details: nil))
        }
    }
}

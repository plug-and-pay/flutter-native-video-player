import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer

// Quality selection (manual + bitrate auto) and viewport-based capping.
// Split from VideoPlayerMethodHandler.swift for maintainability;
// all members keep full access to VideoPlayerView state.
extension VideoPlayerView {
    /// Pins or releases the HLS video quality.
    ///
    /// Crucially this does NOT reload a variant playlist. Each QualityLevel.url
    /// is a single video-only variant; on adaptive HLS the audio lives in a
    /// separate `#EXT-X-MEDIA:TYPE=AUDIO` rendition referenced only by the
    /// master. Replacing the current item with a variant URL therefore dropped
    /// the audio. Instead we keep the master item loaded and constrain the
    /// *video* track via `preferredMaximumResolution` / `preferredPeakBitRate`
    /// — audio is untouched and the switch is instant (no buffering reload).
    func handleSetQuality(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let qualityInfo = args["quality"] as? [String: Any] else {
            result(FlutterError(code: "INVALID_QUALITY", message: "Invalid quality data", details: nil))
            return
        }

        let isAuto = qualityInfo["isAuto"] as? Bool ?? false
        isAutoQuality = isAuto

        if isAuto {
            // Lift the manual bitrate ceiling so AVPlayer's native ABR picks
            // freely. For the resolution ceiling, restore the viewport cap if
            // it's configured and currently appropriate; otherwise remove it.
            manualQualitySelected = false
            player?.currentItem?.preferredPeakBitRate = 0
            if qualityForViewport, let cap = viewportCapSize,
               fullscreenPlayerViewController == nil,
               !(player?.isExternalPlaybackActive ?? false) {
                player?.currentItem?.preferredMaximumResolution = cap
            } else {
                player?.currentItem?.preferredMaximumResolution = .zero
            }

            sendEvent("qualityChange", data: [
                "url": qualityInfo["url"] as? String ?? "",
                "label": qualityInfo["label"] as? String ?? "Auto",
                "isAuto": true
            ])
            result(nil)
        } else {
            // Pin to the selected variant by capping the video track. Exact
            // pinning isn't guaranteed (ABR may still drop lower under
            // bandwidth pressure) — standard AVPlayer quality-capping behaviour.
            let width = qualityInfo["width"] as? Int ?? 0
            let height = qualityInfo["height"] as? Int ?? 0
            let bitrate = qualityInfo["bitrate"] as? Int ?? 0

            manualQualitySelected = true
            if width > 0 && height > 0 {
                player?.currentItem?.preferredMaximumResolution = CGSize(width: width, height: height)
            }
            if bitrate > 0 {
                player?.currentItem?.preferredPeakBitRate = Double(bitrate)
            }

            sendEvent("qualityChange", data: [
                "url": qualityInfo["url"] as? String ?? "",
                "label": qualityInfo["label"] as? String ?? "",
                "isAuto": false
            ])
            result(nil)
        }
    }

    /// Stores the platform view's physical pixel size and caps HLS variant
    /// selection to it (NativeVideoPlayerConfig.qualityForViewportSize).
    /// Without a cap, ABR selects quality for a full-screen viewport, so a
    /// feed of small tiles decodes several full-resolution streams at once.
    func handleSetViewportSize(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let width = args["width"] as? Int,
              let height = args["height"] as? Int,
              width > 0, height > 0 else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "width/height required", details: nil))
            return
        }
        viewportSize = CGSize(width: width, height: height)
        applyViewportCapIfAppropriate()
        result(nil)
    }

    /// The cap actually handed to AVPlayer: the view size plus headroom
    /// (NativeVideoPlayerConfig.viewportCapHeadroom, default 1.5 ≈ one HLS
    /// ladder step). preferredMaximumResolution has "fit-under" semantics
    /// (variants LARGER than the cap are excluded), unlike Android's
    /// setViewportSize which picks the smallest variant that COVERS the
    /// viewport. Without headroom a 1248px-wide tile would exclude the
    /// 1280-wide 720p variant and drop to 480p — visibly softer. With the
    /// default headroom the first variant at-or-above the view size stays
    /// selectable, making the cap visually lossless while still never
    /// decoding e.g. 1080p into a feed tile; apps preferring maximum
    /// savings can set 1.0.
    var viewportCapSize: CGSize? {
        guard let size = viewportSize else { return nil }
        return CGSize(
            width: size.width * viewportCapHeadroom,
            height: size.height * viewportCapHeadroom
        )
    }

    /// Applies the stored viewport cap to the current item unless fullscreen
    /// or AirPlay external playback (which render beyond the inline view's
    /// size) is active. preferredMaximumResolution is a preference: AVPlayer
    /// still plays the lowest variant if none fits, so this can never stall
    /// playback. An explicit manual quality selection (which sets its own
    /// resolution ceiling) takes precedence — the automatic cap must not
    /// silently overwrite it on a viewport resize / fullscreen exit / AirPlay
    /// end; switching back to Auto re-enables this path.
    func applyViewportCapIfAppropriate() {
        guard qualityForViewport, let size = viewportCapSize else { return }
        guard !manualQualitySelected else { return }
        guard fullscreenPlayerViewController == nil else { return }
        guard !(player?.isExternalPlaybackActive ?? false) else { return }
        npLog("🎚️ Applying viewport quality cap: \(Int(size.width))x\(Int(size.height))")
        player?.currentItem?.preferredMaximumResolution = size
    }

    /// Lifts the viewport cap (fullscreen entered or AirPlay became active).
    func liftViewportCap() {
        guard qualityForViewport else { return }
        npLog("🎚️ Lifting viewport quality cap")
        player?.currentItem?.preferredMaximumResolution = .zero
    }
}

import Flutter
import AVFoundation
import CoreMedia

// Embedded-caption styling (issue #43): scales the text size of subtitle
// tracks rendered natively by AVPlayer, via AVPlayerItem.textStyleRules.
// The item is only ever swapped in handleLoad (quality/audio/subtitle
// switches mutate the current item), so applying live + on load covers
// every item.
extension VideoPlayerView {
    func handleSetEmbeddedTextScale(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let scale = args["scale"] as? Double,
              scale > 0 else {
            result(FlutterError(code: "INVALID_SCALE", message: "Invalid scale value", details: nil))
            return
        }

        npLog("Setting embedded caption text scale to: \(scale)")
        embeddedTextScale = CGFloat(scale)
        applyEmbeddedTextScale()
        result(nil)
    }

    /// Applies [embeddedTextScale] to the current AVPlayerItem. At 1.0 the
    /// rules are cleared so the user's system caption styling stays intact.
    func applyEmbeddedTextScale() {
        guard let playerItem = player?.currentItem else { return }

        if embeddedTextScale == 1.0 {
            playerItem.textStyleRules = nil
            return
        }

        let attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: embeddedTextScale * 100.0
        ]

        guard let rule = AVTextStyleRule(textMarkupAttributes: attributes) else {
            npLog("Failed to build AVTextStyleRule for embedded caption scale \(embeddedTextScale)")
            return
        }

        playerItem.textStyleRules = [rule]
    }
}

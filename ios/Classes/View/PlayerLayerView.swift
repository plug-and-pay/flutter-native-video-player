import AVFoundation
import UIKit

/// Bare inline video surface used when native controls are hidden and the
/// `lightweightInlineViews` config is enabled: hosts an AVPlayerLayer
/// directly instead of a full AVPlayerViewController (controls UI, gesture
/// recognizers, internal observation), which is noticeably cheaper per feed
/// tile to create, lay out, and tear down.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

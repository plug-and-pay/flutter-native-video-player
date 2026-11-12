import Flutter
import UIKit
import AVFoundation
import CoreImage

// Still frame of what the player shows, for the Dart side to paint in place
// of the platform view: while another route slides over it (a platform view
// cannot be layered under Flutter content mid-transition) and as the image
// that flies into Dart fullscreen.
/// An item's snapshot output and the last frame copied from it. The output
/// hands each frame out once: while nothing new arrived since (a paused
/// video), the last copy is still the frame on screen.
final class SnapshotFrameSource {
    let output: AVPlayerItemVideoOutput
    var lastFrame: CVPixelBuffer?

    init(output: AVPlayerItemVideoOutput) {
        self.output = output
    }
}

extension VideoPlayerView {
    /// One snapshot source per item, attached on the first capture and kept
    /// for the item's lifetime (weak keys), so later captures are immediate.
    private static let snapshotSources = NSMapTable<AVPlayerItem, SnapshotFrameSource>.weakToStrongObjects()
    private static let snapshotContext = CIContext()

    /// Longest a capture waits for the first frame of a freshly attached
    /// output (a paused item delivers it within a few display frames).
    private static let snapshotTimeout: CFTimeInterval = 0.5

    func handleCaptureFrame(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let item = player?.currentItem, item.status == .readyToPlay else {
            result(nil)
            return
        }
        let args = call.arguments as? [String: Any]
        let maxWidth = (args?["maxWidth"] as? NSNumber)?.doubleValue ?? 0
        let source = Self.snapshotSource(for: item)
        let transform = Self.loadedVideoTransform(of: item)
        let isPlaying = (player?.rate ?? 0) > 0
        let now = CACurrentMediaTime()
        Self.copyFrame(
            from: source,
            // A playing video gets a new frame within a few display frames;
            // the last copy may be long gone by then.
            acceptLastFrameAt: isPlaying ? now + 0.1 : now,
            deadline: now + Self.snapshotTimeout
        ) { buffer in
            guard let buffer = buffer else {
                npLog("📸 No frame available for view \(self.viewId)")
                result(nil)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let data = Self.jpegData(from: buffer, transform: transform, maxWidth: maxWidth)
                DispatchQueue.main.async {
                    result(data.map { FlutterStandardTypedData(bytes: $0) })
                }
            }
        }
    }

    private static func snapshotSource(for item: AVPlayerItem) -> SnapshotFrameSource {
        if let source = snapshotSources.object(forKey: item) {
            return source
        }
        // Same BT.709 settings as the texture renderer, so HDR sources come
        // out tone-mapped instead of washed out.
        let output = AVPlayerItemVideoOutput(outputSettings: [
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        let source = SnapshotFrameSource(output: output)
        snapshotSources.setObject(source, forKey: item)
        return source
    }

    /// The frame on screen now: a new one as soon as the output has it,
    /// else (from [acceptLastFrameAt] on) the last copy. Polls once per
    /// display frame until the deadline passes.
    private static func copyFrame(
        from source: SnapshotFrameSource,
        acceptLastFrameAt: CFTimeInterval,
        deadline: CFTimeInterval,
        completion: @escaping (CVPixelBuffer?) -> Void
    ) {
        let output = source.output
        let now = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: now)
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            source.lastFrame = buffer
            completion(buffer)
            return
        }
        if let frame = source.lastFrame, now >= acceptLastFrameAt {
            completion(frame)
            return
        }
        if now >= deadline {
            completion(source.lastFrame)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) {
            copyFrame(
                from: source,
                acceptLastFrameAt: acceptLastFrameAt,
                deadline: deadline,
                completion: completion
            )
        }
    }

    /// The video track's preferredTransform when the asset already loaded it
    /// (never blocks; HLS has no track transform and stays identity).
    private static func loadedVideoTransform(of item: AVPlayerItem) -> CGAffineTransform {
        let asset = item.asset
        guard asset.statusOfValue(forKey: "tracks", error: nil) == .loaded,
              let track = asset.tracks(withMediaType: .video).first,
              track.statusOfValue(forKey: "preferredTransform", error: nil) == .loaded else {
            return .identity
        }
        return track.preferredTransform
    }

    /// The buffer as an upright JPEG (the output vends frames in the track's
    /// stored orientation), scaled down to at most [maxWidth] pixels wide.
    private static func jpegData(
        from buffer: CVPixelBuffer,
        transform: CGAffineTransform,
        maxWidth: Double
    ) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        if transform != .identity {
            // CIImage's origin is bottom-left, so the track's clockwise
            // rotation is applied in the opposite direction.
            let angle = atan2(transform.b, transform.a)
            image = image.transformed(by: CGAffineTransform(rotationAngle: -angle))
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            ))
        }
        let width = image.extent.width
        if maxWidth > 0 && width > CGFloat(maxWidth) {
            let scale = CGFloat(maxWidth) / width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = snapshotContext.createCGImage(image, from: image.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
    }
}

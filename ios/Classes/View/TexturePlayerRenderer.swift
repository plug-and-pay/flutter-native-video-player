import AVFoundation
import Flutter
import UIKit

/// Texture rendering backend (NativeVideoPlayerConfig.iosTextureMode):
/// copies the player's frames into Flutter engine textures via
/// AVPlayerItemVideoOutput + CADisplayLink, so feed tiles render as
/// ordinary Flutter content with no platform-view composition cost.
///
/// Ported from video_player_avfoundation's FVPTextureBasedVideoPlayer /
/// FVPFrameUpdater (BSD), with one addition the blueprint doesn't need:
/// the video output FOLLOWS player.currentItem (this plugin replaces items
/// on load/quality-switch/stop, and a shared controller's other views can
/// replace it too), attaching when an item reaches .readyToPlay.
///
/// Known-pitfall ports from the blueprint:
/// - BT.709 color properties go on outputSettings (NOT pixel-buffer
///   attributes, where AVFoundation silently ignores them) so HDR/P3
///   sources tone-map correctly (flutter#91241).
/// - An invisible AVPlayerLayer must be in the layer tree or AES-encrypted
///   HLS renders blank on iOS 16+ and some streams swap width/height
///   (flutter#111457, #109116).
/// - `latestPixelBuffer` is re-returned when nothing new is available —
///   the engine has undefined behavior on NULL.
final class TexturePlayerRenderer: NSObject, FlutterTexture {
    private weak var registry: FlutterTextureRegistry?
    private weak var player: AVPlayer?

    /// Set right after the engine registers this texture.
    private(set) var textureId: Int64 = -1

    /// Reports the video's presentation size (texture mode letterboxes on
    /// the Dart side; there is no native layer doing aspect fit).
    var onVideoSizeChanged: ((CGSize) -> Void)?

    private var videoOutput: AVPlayerItemVideoOutput?
    private var outputAttachedItem: AVPlayerItem?
    private var displayLink: CADisplayLink?

    // The invisible fix-layer (see header comment).
    private var fixLayer: AVPlayerLayer?

    private var latestPixelBuffer: CVPixelBuffer?
    private var targetTime: CFTimeInterval = 0
    private var selfRefresh = true
    private var startTime: CFTimeInterval = 0
    private var framesCount = 0
    private var latestDuration: CFTimeInterval = 0
    private var waitingForFrame = false
    private var isPlaying = false
    private var isShutDown = false

    private var currentItemObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?

    init(player: AVPlayer, registry: FlutterTextureRegistry) {
        self.player = player
        self.registry = registry
        super.init()

        let link = CADisplayLink(target: WeakDisplayLinkProxy(self), selector: #selector(WeakDisplayLinkProxy.tick))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link

        // The fix-layer must be in a visible layer tree; zero-sized so it
        // never draws. Same placement as video_player_avfoundation.
        let layer = AVPlayerLayer(player: player)
        layer.frame = .zero
        if let hostLayer = UIApplication.shared.keyWindow?.rootViewController?.view.layer {
            hostLayer.addSublayer(layer)
        }
        fixLayer = layer

        // Follow the player's current item across loads/quality switches.
        currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.followItem(player.currentItem)
            }
        }
    }

    func register(with registry: FlutterTextureRegistry) {
        textureId = registry.register(self)
        // The engine now expects the texture to be populated: render the
        // first frame even while paused.
        expectFrame()
    }

    // MARK: - Item following

    private func followItem(_ item: AVPlayerItem?) {
        guard !isShutDown else { return }
        if item === outputAttachedItem { return }

        detachOutput()
        itemStatusObservation = nil
        presentationSizeObservation = nil

        guard let item = item else { return }

        presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            if size.width > 0 && size.height > 0 {
                DispatchQueue.main.async {
                    self?.onVideoSizeChanged?(size)
                }
            }
        }

        if item.status == .readyToPlay {
            attachOutput(to: item)
        } else {
            itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .readyToPlay {
                    DispatchQueue.main.async {
                        self?.attachOutput(to: item)
                    }
                }
            }
        }
    }

    private func attachOutput(to item: AVPlayerItem) {
        guard !isShutDown, outputAttachedItem !== item else { return }
        detachOutput()

        // BT.709 on outputSettings is the HDR tone-map fix (flutter#91241).
        let outputSettings: [String: Any] = [
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let output = AVPlayerItemVideoOutput(outputSettings: outputSettings)
        item.add(output)
        videoOutput = output
        outputAttachedItem = item
        npLog("✅ Texture output attached to item (textureId \(textureId))")
        expectFrame()
    }

    private func detachOutput() {
        if let output = videoOutput, let item = outputAttachedItem {
            item.remove(output)
        }
        videoOutput = nil
        outputAttachedItem = nil
    }

    // MARK: - Frame pump

    /// Renders the next available frame even while paused (first frame,
    /// after seeks, after reattach).
    func setRunning(_ playing: Bool) {
        isPlaying = playing
        displayLink?.isPaused = !(playing || waitingForFrame)
    }

    func expectFrame() {
        waitingForFrame = true
        displayLink?.isPaused = false
    }

    fileprivate func displayLinkFired() {
        guard !isShutDown, textureId >= 0 else { return }
        registry?.textureFrameAvailable(textureId)
    }

    // MARK: - FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        // Pacing port from FVPTextureBasedVideoPlayer.copyPixelBuffer: the
        // engine calls at irregular timestamps; sampling at regular target
        // times avoids missed frames, resetting when drift exceeds half a
        // frame.
        let resetThreshold = 0.5
        let currentTime = CACurrentMediaTime()
        let duration = displayLink?.duration ?? (1.0 / 60.0)
        if abs(targetTime - currentTime) > duration * resetThreshold {
            targetTime = currentTime
        }
        targetTime += duration

        if let output = videoOutput {
            let outputItemTime = output.itemTime(forHostTime: targetTime)
            if output.hasNewPixelBuffer(forItemTime: outputItemTime),
               let buffer = output.copyPixelBuffer(forItemTime: outputItemTime, itemTimeForDisplay: nil) {
                latestPixelBuffer = buffer
            }
        }

        if waitingForFrame && latestPixelBuffer != nil {
            waitingForFrame = false
            if !isPlaying {
                displayLink?.isPaused = true
            }
        }

        // selfRefresh port: re-arm the engine from here unless frames come
        // unexpectedly fast (degradation detector).
        if let link = displayLink, !link.isPaused, selfRefresh {
            let windowSize = 10
            let durationThreshold = 0.5
            let resetFraction = 0.01

            if abs(duration - latestDuration) >= latestDuration * resetFraction {
                startTime = currentTime
                framesCount = 0
                latestDuration = duration
            }
            if framesCount == windowSize {
                let averageDuration = (currentTime - startTime) / Double(windowSize)
                if averageDuration < duration * durationThreshold {
                    npLog("⚠️ Texture self-refresh disabled (frames arriving too fast)")
                    selfRefresh = false
                }
                startTime = currentTime
                framesCount = 0
            }
            framesCount += 1

            let textureId = self.textureId
            DispatchQueue.main.async { [weak self] in
                self?.registry?.textureFrameAvailable(textureId)
            }
        }

        // The engine expects an owning reference; nil only before any frame
        // ever arrived (the engine tolerates nil, just renders nothing yet).
        guard let buffer = latestPixelBuffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }

    func onTextureUnregistered(_ texture: FlutterTexture) {
        // Engine-side backstop (e.g. hot restart races): finish cleanup.
        DispatchQueue.main.async { [weak self] in
            self?.shutdown(unregister: false)
        }
    }

    // MARK: - Teardown

    /// Idempotent: stops the display link, detaches the video output,
    /// removes the fix-layer and unregisters the engine texture.
    func shutdown(unregister: Bool = true) {
        guard !isShutDown else { return }
        isShutDown = true

        displayLink?.invalidate()
        displayLink = nil
        currentItemObservation = nil
        itemStatusObservation = nil
        presentationSizeObservation = nil
        detachOutput()
        fixLayer?.removeFromSuperlayer()
        fixLayer = nil
        if unregister, textureId >= 0 {
            registry?.unregisterTexture(textureId)
        }
        latestPixelBuffer = nil
        npLog("🧹 TexturePlayerRenderer shut down (textureId \(textureId))")
    }
}

/// CADisplayLink retains its target — a weak proxy breaks the cycle.
private final class WeakDisplayLinkProxy: NSObject {
    private weak var renderer: TexturePlayerRenderer?

    init(_ renderer: TexturePlayerRenderer) {
        self.renderer = renderer
    }

    @objc func tick() {
        renderer?.displayLinkFired()
    }
}

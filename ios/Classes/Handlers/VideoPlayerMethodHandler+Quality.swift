import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer

// Quality selection (manual + bitrate auto) and viewport-based capping.
// Split from VideoPlayerMethodHandler.swift for maintainability;
// all members keep full access to VideoPlayerView state.
extension VideoPlayerView {
    func handleSetQuality(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let qualityInfo = args["quality"] as? [String: Any] else {
            result(FlutterError(code: "INVALID_QUALITY", message: "Invalid quality data", details: nil))
            return
        }
        
        let isAuto = qualityInfo["isAuto"] as? Bool ?? false
        isAutoQuality = isAuto
        
        if isAuto {
            // Start with the middle quality for auto mode
            let midIndex = max(0, qualityLevels.count / 2 - 1)
            guard midIndex < qualityLevels.count else {
                result(FlutterError(code: "NO_QUALITIES", message: "No qualities available", details: nil))
                return
            }
            
            let initialQuality = qualityLevels[midIndex]
            switchToQuality(initialQuality, result: result)
            
            // Enable quality monitoring
            startQualityMonitoring()
        } else {
            guard let urlString = qualityInfo["url"] as? String,
                  let url = URL(string: urlString) else {
                result(FlutterError(code: "INVALID_URL", message: "Invalid quality URL", details: nil))
                return
            }
            
            sendEvent("loading")
            
            // Store current playback state and position
            let wasPlaying = player?.rate != 0
            let currentTime = player?.currentTime() ?? CMTime.zero
            
            let newItem = AVPlayerItem(url: url)
            player?.replaceCurrentItem(with: newItem)
            player?.seek(to: currentTime)
            
            // Only resume playback if it was playing before
            if wasPlaying {
                player?.play()
            }
            
            sendEvent("qualityChange", data: [
                "url": urlString,
                "label": qualityInfo["label"] as? String ?? "",
                "isAuto": false
            ])
            result(nil)
        }
    }

    func startQualityMonitoring() {
        // Remove existing observer if any
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        
        // Monitor playback every second for auto-quality
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.checkAndAdjustQuality()
        }
    }

    func checkAndAdjustQuality() {
        guard isAutoQuality,
              !qualityLevels.isEmpty,
              CACurrentMediaTime() - lastBitrateCheck >= bitrateCheckInterval else {
            return
        }
        
        lastBitrateCheck = CACurrentMediaTime()
        
        // Get current playback statistics
        let loadedTimeRanges = player?.currentItem?.loadedTimeRanges ?? []
        let currentTime = player?.currentTime() ?? CMTime.zero
        
        // Calculate buffer health
        var bufferHealth: TimeInterval = 0
        for range in loadedTimeRanges {
            let timeRange = range.timeRangeValue
            if timeRange.start <= currentTime {
                bufferHealth += timeRange.duration.seconds
            }
        }
        
        // Get current quality index
        guard let urlAsset = player?.currentItem?.asset as? AVURLAsset,
              let currentUrl = urlAsset.url.absoluteString as String?,
              let currentIndex = qualityLevels.firstIndex(where: { $0.url == currentUrl }) else {
            return
        }
        
        // Adjust quality based on buffer health
        var targetIndex = currentIndex
        
        if bufferHealth < 3.0 && currentIndex > 0 {
            // Buffer is low, decrease quality
            targetIndex = currentIndex - 1
        } else if bufferHealth > 10.0 && currentIndex < qualityLevels.count - 1 {
            // Buffer is healthy, try increasing quality
            targetIndex = currentIndex + 1
        }
        
        if targetIndex != currentIndex {
            switchToQuality(qualityLevels[targetIndex], result: nil)
        }
    }

    func switchToQuality(_ quality: VideoPlayer.QualityLevel, result: FlutterResult?) {
        guard let url = URL(string: quality.url) else {
            result?(FlutterError(code: "INVALID_URL", message: "Invalid quality URL", details: nil))
            return
        }
        
        sendEvent("loading")
        
        let wasPlaying = player?.rate != 0
        let currentTime = player?.currentTime() ?? CMTime.zero
        
        let newItem = AVPlayerItem(url: url)
        player?.replaceCurrentItem(with: newItem)
        player?.seek(to: currentTime)
        
        if wasPlaying {
            player?.play()
        }
        
        sendEvent("qualityChange", data: [
            "url": quality.url,
            "label": quality.label,
            "isAuto": isAutoQuality
        ])
        
        result?(nil)
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
    /// playback. Manual quality selection loads a dedicated variant URL via a
    /// NEW player item and is therefore never constrained by this.
    func applyViewportCapIfAppropriate() {
        guard qualityForViewport, let size = viewportCapSize else { return }
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

import Flutter
import UIKit
import AVKit
import AVFoundation
import MediaPlayer
import QuartzCore

// MARK: - Main Video Player View

@objc public class VideoPlayerView: NSObject, FlutterPlatformView, FlutterStreamHandler {
    // Heavy display path. Lazy so lightweight views (lightweightInlineViews
    // config + hidden controls) never pay for an AVPlayerViewController; if a
    // stray code path still touches it in light mode, one is materialized
    // bound to the same player so behavior degrades gracefully.
    lazy var playerViewController: AVPlayerViewController = {
        npLog("⚠️ Materializing AVPlayerViewController lazily for light view \(viewId)")
        let viewController = AVPlayerViewController()
        viewController.player = player
        viewController.showsPlaybackControls = false
        viewController.updatesNowPlayingInfoCenter = false
        viewController.delegate = self
        return viewController
    }()

    // Lightweight display path: a bare AVPlayerLayer surface (set only when
    // the view was created with lightweightInlineViews + hidden controls).
    var lightView: PlayerLayerView?
    var usesLightView: Bool { lightView != nil }

    // Texture display path (iosTextureMode): frames are copied into a
    // Flutter engine texture; there is no on-screen native view at all.
    // Created via the plugin's 'createTextureView' (not the platform-view
    // factory). PiP and native-control features route to documented
    // fallbacks (the Dart side swaps such views to platform views first).
    // The flag is set in init; the renderer is attached by the plugin right
    // after (it owns the texture registry), so guards must use the flag.
    var textureRenderer: TexturePlayerRenderer?
    private(set) var isTextureBacked = false
    var usesTextureView: Bool { isTextureBacked }

    /// True when this view displays through an AVPlayerViewController (the
    /// only mode where touching the lazy `playerViewController` is correct).
    var usesViewControllerDisplay: Bool { !usesLightView && !usesTextureView }

    // Placeholder returned from view() for texture-backed instances; the
    // engine never embeds it (texture views are not platform views).
    private lazy var texturePlaceholderView = UIView()

    // Whether PiP is allowed for this view (mirrors
    // playerViewController.allowsPictureInPicturePlayback in heavy mode;
    // gates inline PiP controller creation in light mode).
    var allowsInlinePictureInPicture: Bool = true

    var player: AVPlayer?
    private var methodChannel: FlutterMethodChannel
    private var channelName: String
    var eventSink: FlutterEventSink?

    // The per-view EventChannel. Its engine-side handler registration
    // strongly retains this view (setStreamHandler(self)), which makes
    // deinit unreachable until tearDownChannels() deregisters it.
    private var eventChannel: FlutterEventChannel?
    private var channelsTornDown = false

    // KVO bookkeeping so teardown removes exactly what was registered:
    // removing a never-registered observer throws NSRangeException, and the
    // observed item can differ from player.currentItem by the time the view
    // goes away (re-loads, shared players).
    var observedItem: AVPlayerItem?
    var hasPlayerStateObservers = false
    var availableQualities: [[String: Any]] = []
    var qualityLevels: [VideoPlayer.QualityLevel] = []
    var isAutoQuality = false
    var lastBitrateCheck: TimeInterval = 0
    let bitrateCheckInterval: TimeInterval = 5.0 // Check every 5 seconds
    var controllerId: Int?
    var pipController: AVPictureInPictureController?

    // Track if PiP is currently active (for both automatic and manual PiP)
    var isPipCurrentlyActive: Bool = false

    // Track if we're currently in the middle of a PiP restoration
    // This is true from when restoreUserInterfaceForPictureInPictureStop is called
    // until after didStopPictureInPicture completes
    var isPipRestoringUI: Bool = false

    // Track if we've already registered remote command handlers
    // This prevents re-registering and clearing targets unnecessarily
    var hasRegisteredRemoteCommands: Bool = false

    /// Force re-registration of remote commands
    /// Call this when you know the targets might have been removed externally
    func forceReregisterRemoteCommands() {
        npLog("🔄 Checking if need to re-register remote commands for view \(viewId)")

        // Only force re-registration if we don't already own the commands
        // or if the commands aren't properly set up
        let commandCenter = MPRemoteCommandCenter.shared()
        let hasTargets = commandCenter.playCommand.isEnabled && commandCenter.pauseCommand.isEnabled

        if RemoteCommandManager.shared.isOwner(viewId) && hasTargets {
            npLog("   → View \(viewId) already owns commands and they're active - skipping re-registration")
            // Just restore Now Playing info without touching remote commands
            if let mediaInfo = currentMediaInfo {
                setupNowPlayingInfo(mediaInfo: mediaInfo)
            }
            return
        }

        npLog("   → Re-registering remote commands for view \(viewId)")
        hasRegisteredRemoteCommands = false
        if let mediaInfo = currentMediaInfo {
            setupNowPlayingInfo(mediaInfo: mediaInfo)
        }
    }

    // Store the platform view ID for registration
    var viewId: Int64 = 0
    
    // Store whether automatic PiP was requested in creation params
    var canStartPictureInPictureAutomatically: Bool = true

    // Separate player view controller for fullscreen (prevents removing embedded view)
    var fullscreenPlayerViewController: AVPlayerViewController?

    // When true, this platform view is the Dart fullscreen host and uses its own AVPlayerViewController
    // (same AVPlayer) so the inline view never loses its shared view. Cleared in deinit.
    var isDartFullscreenView: Bool = false

    // Store media info for Now Playing
    var currentMediaInfo: [String: Any]?
    var timeObserver: Any?

    // Tick counter for the periodic time observer: Now Playing elapsed time
    // only needs an occasional resync (the system extrapolates from playback
    // rate), so the per-tick XPC write is throttled to every Nth tick.
    var nowPlayingResyncTick: Int = 0

    // Fingerprint of the media info last applied to Now Playing by this view.
    // Lets setupNowPlayingInfo skip the full rebuild (audio session activation,
    // artwork download, remote-command registration) when nothing changed —
    // it is invoked on every transition to .playing, including after stalls.
    var lastAppliedNowPlayingInfoKey: String?

    // Track if this is a shared player (to avoid sending duplicate initialization events)
    var isSharedPlayer: Bool = false

    // Store desired playback speed
    var desiredPlaybackSpeed: Float = 1.0

    // Store HDR setting
    var enableHDR: Bool = false

    // Store looping setting
    var enableLooping: Bool = false

    // Whether to prevent swipe-to-dismiss in native fullscreen mode (the
    // system swipe gesture can leave the inline player with a black screen)
    var preventFullscreenSwipeDismiss: Bool = true

    // Interval between timeUpdate events while playing (from the Dart
    // NativeVideoPlayerConfig; default matches previous behavior)
    var timeUpdateIntervalMs: Int = 500

    // Viewport-based quality capping (NativeVideoPlayerConfig.qualityForViewportSize):
    // caps HLS variant selection to the platform view's physical pixel size.
    // Lifted in native fullscreen and while AirPlay external playback is active.
    var qualityForViewport: Bool = false
    var viewportSize: CGSize?

    // Headroom multiplier for the viewport cap (see viewportCapSize):
    // default 1.5 keeps the first variant at-or-above the tile selectable.
    var viewportCapHeadroom: Double = 1.5

    // Optional AVPlayer buffer tuning (from the Dart NativeVideoPlayerConfig)
    var preferredForwardBufferDuration: Double?
    var automaticallyWaitsToMinimizeStalling: Bool = true

    // Track if app is in background to keep audio playing on screen lock
    var isInBackground: Bool = false
    var lastKnownRate: Float = 0.0
    
    // DRM handler for protected content
    var drmHandler: VideoPlayerDrmHandler?


    public init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        npLog("Creating VideoPlayerView with id: \(viewId)")
        self.viewId = viewId
        channelName = "native_video_player_\(viewId)"
        methodChannel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: messenger
        )

        // Extract controller ID from args to get shared player and view controller
        let argsDict = args as? [String: Any]
        let isDartFullscreen = argsDict?["isDartFullscreen"] as? Bool ?? false

        // Lightweight display mode: bare AVPlayerLayer instead of a per-tile
        // AVPlayerViewController. Only when the app opted in AND this view
        // hides native controls (the layer can't render controls).
        let argsShowNativeControls = argsDict?["showNativeControls"] as? Bool ?? true
        // Texture display mode: set only by the plugin's createTextureView
        // path (the Dart widget already applied the controls/PiP/fullscreen
        // eligibility rules).
        let useTextureView = argsDict?["isTextureView"] as? Bool ?? false
        let useLightView = !useTextureView &&
            (argsDict?["lightweightInlineViews"] as? Bool ?? false) && !argsShowNativeControls

        // The view controller resolved for the heavy path; assigned to the
        // lazy property after super.init() (lazy vars can't be set earlier).
        var resolvedViewController: AVPlayerViewController?

        if let args = argsDict,
           let controllerIdValue = args["controllerId"] as? Int {
            controllerId = controllerIdValue
            isDartFullscreenView = isDartFullscreen

            if useLightView || useTextureView {
                // Light views render through their own AVPlayerLayer (one per
                // view, most recently attached layer displays — same contract
                // as the dedicated-VC-per-view scheme below); texture views
                // have no native surface at all. Neither creates a shared
                // AVPlayerViewController; native fullscreen builds its own
                // on demand.
                let (sharedPlayer, alreadyExisted) =
                    SharedPlayerManager.shared.getOrCreatePlayer(for: controllerIdValue)
                player = sharedPlayer
                isSharedPlayer = alreadyExisted
                npLog("✅ Using \(useTextureView ? "texture" : "lightweight AVPlayerLayer") view for controller ID: \(controllerIdValue) (shared: \(alreadyExisted), dartFullscreen: \(isDartFullscreen))")
            } else {
                // Get or create shared player AND view controller
                // This ensures the view controller persists across platform view disposal
                // so PiP delegate callbacks continue to work even when navigating away
                let (sharedPlayer, sharedViewController, alreadyExisted) =
                    SharedPlayerManager.shared.getOrCreatePlayerAndViewController(for: controllerIdValue)

                player = sharedPlayer
                isSharedPlayer = alreadyExisted

                if isDartFullscreen {
                    // Dart fullscreen host: use a dedicated AVPlayerViewController (same player) so the inline
                    // view never loses its shared view when this platform view is created or disposed.
                    let dedicatedVC = AVPlayerViewController()
                    dedicatedVC.player = sharedPlayer
                    resolvedViewController = dedicatedVC
                    npLog("✅ Created dedicated AVPlayerViewController for Dart fullscreen (controller ID: \(controllerIdValue))")
                } else {
                    if alreadyExisted {
                        // Second or later platform view for this controller (e.g. detail screen).
                        // Use a dedicated AVPlayerViewController with the shared player so this
                        // view has its own layer; the shared VC stays in SharedPlayerManager for PiP.
                        // This avoids black screen when navigating list↔detail (one UIView per slot).
                        let displayVC = AVPlayerViewController()
                        displayVC.player = sharedPlayer
                        resolvedViewController = displayVC
                        npLog("✅ Created dedicated AVPlayerViewController for shared controller (controller ID: \(controllerIdValue)) - avoids black screen when navigating list↔detail")
                    } else {
                        resolvedViewController = sharedViewController
                        npLog("✅ Created new shared player AND view controller for controller ID: \(controllerIdValue)")
                    }
                }
            }
        } else {
            // Fallback: create new instances if no controller ID provided
            npLog("No controller ID provided, creating new player\(useLightView ? "" : " and view controller")")
            let newPlayer = AVPlayer()
            player = newPlayer

            // Configure for background playback
            if #available(iOS 15.0, *) {
                newPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
                npLog("✅ Set audiovisualBackgroundPlaybackPolicy for non-shared player")
            }

            if !useLightView && !useTextureView {
                // Assign player to view controller
                let viewController = AVPlayerViewController()
                viewController.player = newPlayer
                resolvedViewController = viewController
            }
        }

        super.init()

        isTextureBacked = useTextureView
        if useTextureView {
            // The renderer is registered with the engine by the plugin
            // (which owns the texture registry) right after this init.
            // It follows player.currentItem on its own.
        } else if useLightView {
            let light = PlayerLayerView()
            light.playerLayer.player = player
            lightView = light
        } else {
            if let resolvedViewController = resolvedViewController {
                playerViewController = resolvedViewController
            }

            // Configure playback controls
            playerViewController.showsPlaybackControls = argsShowNativeControls
            playerViewController.delegate = self

            // Disable automatic Now Playing updates - we'll handle it manually
            playerViewController.updatesNowPlayingInfoCenter = false
        }

        // Extract configuration from Flutter args
        if let args = args as? [String: Any] {
            // PiP configuration from args
            let argsAllowsPiP = args["allowsPictureInPicture"] as? Bool ?? true
            let argsCanStartAutomatically = args["canStartPictureInPictureAutomatically"] as? Bool ?? true

            // HDR configuration from args
            enableHDR = args["enableHDR"] as? Bool ?? false

            // Looping configuration from args
            enableLooping = args["enableLooping"] as? Bool ?? false

            // Fullscreen swipe-to-dismiss configuration from args
            preventFullscreenSwipeDismiss = args["preventFullscreenSwipeDismiss"] as? Bool ?? true

            // Time-update interval and buffer tuning from args
            timeUpdateIntervalMs = args["timeUpdateIntervalMs"] as? Int ?? 500

            // Viewport-based quality capping from args
            qualityForViewport = args["qualityForViewport"] as? Bool ?? false
            viewportCapHeadroom = args["viewportCapHeadroom"] as? Double ?? 1.5
            if let bufferConfig = args["iosBufferConfig"] as? [String: Any] {
                preferredForwardBufferDuration = bufferConfig["preferredForwardBufferDuration"] as? Double
                automaticallyWaitsToMinimizeStalling =
                    bufferConfig["automaticallyWaitsToMinimizeStalling"] as? Bool ?? true
            }

            // For shared players, try to get PiP settings from SharedPlayerManager
            // This ensures PiP settings persist across all views using the same controller
            if let controllerIdValue = controllerId {
                if let sharedSettings = SharedPlayerManager.shared.getPipSettings(for: controllerIdValue) {
                    // Use existing shared settings
                    self.canStartPictureInPictureAutomatically = sharedSettings.canStartPictureInPictureAutomatically
                    applyAllowsPictureInPicture(sharedSettings.allowsPictureInPicture)
                    npLog("✅ Using shared PiP settings for controller \(controllerIdValue) - allows: \(sharedSettings.allowsPictureInPicture), autoStart: \(sharedSettings.canStartPictureInPictureAutomatically)")
                } else {
                    // First view for this controller - store the settings
                    self.canStartPictureInPictureAutomatically = argsCanStartAutomatically
                    applyAllowsPictureInPicture(argsAllowsPiP)
                    SharedPlayerManager.shared.setPipSettings(
                        for: controllerIdValue,
                        allowsPictureInPicture: argsAllowsPiP,
                        canStartPictureInPictureAutomatically: argsCanStartAutomatically,
                        showNativeControls: argsShowNativeControls
                    )
                    npLog("✅ Stored new PiP settings for controller \(controllerIdValue) - allows: \(argsAllowsPiP), autoStart: \(argsCanStartAutomatically)")
                }
            } else {
                // Non-shared player - use settings from args
                self.canStartPictureInPictureAutomatically = argsCanStartAutomatically
                applyAllowsPictureInPicture(argsAllowsPiP)
                npLog("✅ PiP settings for non-shared player - allows: \(argsAllowsPiP), autoStart: \(argsCanStartAutomatically)")
            }

            if #available(iOS 14.2, *) {
                // Start with automatic PiP DISABLED
                // It will be enabled when this specific player starts playing (if allowed)
                // This prevents conflicts when multiple players exist
                // (light/texture views start without a PiP controller, which
                // is the same disabled state)
                if usesViewControllerDisplay {
                    playerViewController.canStartPictureInPictureAutomaticallyFromInline = false
                }
                npLog("✅ PiP configured, automatic PiP will be enabled on play if allowed")
            } else {
                npLog("⚠️ Automatic PiP requires iOS 14.2+, current device doesn't support it")
            }

            // Store media info if provided during initialization
            // This ensures we have the correct media info even for shared players
            if let mediaInfo = args["mediaInfo"] as? [String: Any] {
                currentMediaInfo = mediaInfo
                npLog("📱 Stored media info during init: \(mediaInfo["title"] ?? "Unknown")")

                // Also store in SharedPlayerManager to persist across view recreations
                if let controllerIdValue = controllerId {
                    SharedPlayerManager.shared.setMediaInfo(for: controllerIdValue, mediaInfo: mediaInfo)
                }
            }
        }
        
        // Register this view with the SharedPlayerManager
        if let controllerIdValue = controllerId {
            SharedPlayerManager.shared.registerVideoPlayerView(self, viewId: viewId)
            npLog("✅ Registered VideoPlayerView for controller \(controllerIdValue), viewId: \(viewId)")

            // Setup controller-level event channel (if not already set up)
            // This enables persistent event delivery for PiP and AirPlay
            NativeVideoPlayerPlugin.setupControllerEventChannel(for: controllerIdValue)

            // If this controller is currently the one with automatic PiP enabled OR if the player is playing,
            // this new view should become the primary view and get automatic PiP
            // BUT ONLY if manual PiP is not active
            if #available(iOS 14.2, *) {
                let isActiveForAutoPiP = SharedPlayerManager.shared.isControllerActiveForAutoPiP(controllerIdValue)
                let isPlaying = player?.rate ?? 0 > 0

                if isActiveForAutoPiP || isPlaying {
                    npLog("🎬 Controller state - activeForAutoPiP: \(isActiveForAutoPiP), isPlaying: \(isPlaying)")
                    if canStartPictureInPictureAutomatically {
                        // Check if manual PiP is active - if so, skip re-enabling automatic PiP
                        if SharedPlayerManager.shared.isManualPiPActive(controllerIdValue) {
                            npLog("   ⚠️ Skipping automatic PiP re-enable - manual PiP is active")
                        } else {
                            // Set this new view as the primary view
                            SharedPlayerManager.shared.setPrimaryView(viewId, for: controllerIdValue)
                            // Re-apply automatic PiP settings to enable it on this new view
                            SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                            npLog("   → Set new view as primary and enabled automatic PiP (viewId: \(viewId))")
                        }
                    } else {
                        npLog("   ⚠️ Cannot enable automatic PiP - canStartPictureInPictureAutomatically is false")
                    }
                }
            }
        }

        npLog("Setting up method channel: \(channelName)")
        // Set up method call handler
        npLog("Setting method handler for channel: \(channelName)")
        methodChannel.setMethodCallHandler({ [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard let self = self else {
                result(FlutterError(code: "DISPOSED", message: "VideoPlayerView was disposed", details: nil))
                return
            }
            npLog("[\(self.channelName)] Received method call: \(call.method)")
            self.handleMethodCall(call: call, result: result)
        })
        
        // Set up event channel (stored so tearDownChannels can deregister it)
        let eventChannel = FlutterEventChannel(
            name: "native_video_player_\(viewId)",
            binaryMessenger: messenger
        )
        eventChannel.setStreamHandler(self)
        self.eventChannel = eventChannel

        // Set up observers for shared players if there's already a loaded video
        // The initial state event will be sent when onListen is called
        if isSharedPlayer, let currentItem = player?.currentItem {
            addObservers(to: currentItem)
            // Also set up periodic time observer for this new view
            setupPeriodicTimeObserver()
        }

        // Observe app entering foreground to restore Now Playing info
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        npLog("✅ Registered foreground notification observer for view \(viewId)")

        // Observe app entering background (for screen lock detection)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        npLog("✅ Registered background notification observer for view \(viewId)")

        // Observe audio session interruptions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        npLog("✅ Registered audio session interruption observer for view \(viewId)")

        // Use the app-wide route detector in SharedPlayerManager instead of a
        // per-view AVRouteDetector — route detection is power-expensive and
        // one detector serves all views (iOS 11.0+).
        if #available(iOS 11.0, *) {
            SharedPlayerManager.shared.ensureRouteDetectionStarted()
        }
    }

    public func view() -> UIView {
        if usesTextureView { return texturePlaceholderView }
        return lightView ?? playerViewController.view
    }

    // MARK: - Display-mode helpers (AVPlayerViewController / AVPlayerLayer / texture)

    /// The inline display surface for this view, whichever mode it uses.
    /// (Texture views render in the engine; the placeholder is never in a
    /// hierarchy, so visibility toggles on it are harmless no-ops.)
    var inlineDisplayView: UIView {
        if usesTextureView { return texturePlaceholderView }
        return lightView ?? playerViewController.view
    }

    /// Makes the inline surface visible (used around PiP transitions).
    func setInlineViewVisible() {
        inlineDisplayView.isHidden = false
        inlineDisplayView.alpha = 1.0
    }

    /// Re-attaches the player to this view's inline surface (after native
    /// fullscreen handed the video layer back, etc.).
    func rebindInlinePlayer() {
        if usesTextureView {
            // The video output stays attached across fullscreen; just make
            // sure the next frame renders even while paused.
            textureRenderer?.expectFrame()
        } else if let lightView = lightView {
            lightView.playerLayer.player = nil
            lightView.playerLayer.player = player
        } else {
            playerViewController.player = nil
            playerViewController.player = player
        }
    }

    /// Records whether PiP is allowed for this view and applies it to the
    /// heavy view controller when one is in use.
    func applyAllowsPictureInPicture(_ allows: Bool) {
        allowsInlinePictureInPicture = allows
        if usesViewControllerDisplay {
            playerViewController.allowsPictureInPicturePlayback = allows
        }
    }

    /// Whether automatic inline PiP is currently enabled on this view's
    /// display surface (without materializing anything).
    var isAutomaticInlinePiPEnabled: Bool {
        guard #available(iOS 14.2, *) else { return false }
        if usesTextureView { return false }
        if usesLightView {
            return pipController?.canStartPictureInPictureAutomaticallyFromInline ?? false
        }
        return playerViewController.canStartPictureInPictureAutomaticallyFromInline
    }

    /// Enables/disables automatic inline PiP on this view's display surface.
    /// Heavy mode flips the AVPlayerViewController flag; light mode manages
    /// an AVPictureInPictureController bound to the AVPlayerLayer (created on
    /// demand — disabling when none exists is a no-op).
    @available(iOS 14.2, *)
    func setAutomaticInlinePiP(_ enabled: Bool) {
        if usesTextureView {
            // No on-screen AVPlayerLayer exists: automatic PiP cannot work
            // from a texture view. The Dart side never creates texture views
            // for auto-PiP controllers; this is reachable only through
            // SharedPlayerManager's fan-out loops.
            if enabled {
                npLog("⚠️ Automatic PiP not available on texture view \(viewId)")
            }
            return
        }
        if usesLightView {
            if enabled {
                // Mirror the heavy path, where allowsPictureInPicturePlayback
                // gates the view controller's automatic PiP machinery.
                guard allowsInlinePictureInPicture else {
                    npLog("⚠️ Not enabling automatic PiP on light view \(viewId) - PiP not allowed")
                    return
                }
                ensureInlinePipController()?.canStartPictureInPictureAutomaticallyFromInline = true
            } else {
                pipController?.canStartPictureInPictureAutomaticallyFromInline = false
            }
        } else {
            playerViewController.canStartPictureInPictureAutomaticallyFromInline = enabled
        }
    }

    /// Returns the view's AVPictureInPictureController, creating it from the
    /// player layer if needed (light-mode PiP vehicle; also used by manual
    /// PiP). Returns nil when PiP is unsupported or not allowed.
    @available(iOS 14.0, *)
    @discardableResult
    func ensureInlinePipController() -> AVPictureInPictureController? {
        if let existing = pipController { return existing }
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let playerLayer = findPlayerLayer() else { return nil }
        let created: AVPictureInPictureController? = AVPictureInPictureController(playerLayer: playerLayer)
        guard let controller = created else { return nil }
        controller.delegate = self
        pipController = controller
        npLog("✅ Created inline PiP controller for view \(viewId) (light: \(usesLightView))")
        return controller
    }

    // MARK: - Channel teardown

    /// Deregisters this view's engine-side channel handlers.
    ///
    /// The EventChannel stream handler block strongly captures `self`, so
    /// deinit can never run while it is registered — the Dart side invokes
    /// `viewDisposed` when the platform view is disposed, which lands here.
    /// Idempotent.
    func tearDownChannels() {
        guard !channelsTornDown else { return }
        channelsTornDown = true
        npLog("🧹 Tearing down channels for view \(viewId)")
        eventSink = nil
        eventChannel?.setStreamHandler(nil)
        eventChannel = nil
        methodChannel.setMethodCallHandler(nil)
        // Texture resources die with the view's disposal hook too: stop the
        // display link, detach the video output, release the engine texture.
        textureRenderer?.shutdown()
    }

    // MARK: - Audio Session Management

    /// Prepares and activates the audio session for video playback
    /// This MUST be called before starting playback to ensure audio continues when screen locks
    func prepareAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            npLog("✅ AVAudioSession configured for movie playback and activated")
        } catch {
            npLog("❌ Audio session error: \(error.localizedDescription)")
        }
    }

    public func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        npLog("Handling method call: \(call.method) on channel: \(channelName)")
        switch call.method {
        case "load":
            handleLoad(call: call, result: result)
        case "play":
            handlePlay(result: result)
        case "pause":
            handlePause(result: result)
        case "seekTo":
            handleSeekTo(call: call, result: result)
        case "setVolume":
            handleSetVolume(call: call, result: result)
        case "setSpeed":
            handleSetSpeed(call: call, result: result)
        case "setLooping":
            handleSetLooping(call: call, result: result)
        case "setQuality":
            handleSetQuality(call: call, result: result)
        case "getAvailableQualities":
            // First check if we have qualities in this view instance
            if !availableQualities.isEmpty {
                result(availableQualities)
            } else if let controllerIdValue = controllerId,
                      let cachedQualities = SharedPlayerManager.shared.getQualities(for: controllerIdValue) {
                // If view instance is empty but cache has qualities, restore them
                availableQualities = cachedQualities
                if let cachedQualityLevels = SharedPlayerManager.shared.getQualityLevels(for: controllerIdValue) {
                    qualityLevels = cachedQualityLevels
                }
                npLog("🔄 Restored \(cachedQualities.count) qualities from cache for controller \(controllerIdValue)")
                result(cachedQualities)
            } else {
                result(availableQualities)
            }
        case "getAvailableSubtitleTracks":
            handleGetAvailableSubtitleTracks(result: result)
        case "setSubtitleTrack":
            handleSetSubtitleTrack(call: call, result: result)
        case "getAvailableAudioTracks":
            handleGetAvailableAudioTracks(result: result)
        case "setAudioTrack":
            handleSetAudioTrack(call: call, result: result)
        case "enterFullScreen":
            handleEnterFullScreen(result: result)
        case "exitFullScreen":
            handleExitFullScreen(result: result)
        case "isPictureInPictureAvailable":
            handleIsPictureInPictureAvailable(result: result)
        case "enterPictureInPicture":
            handleEnterPictureInPicture(result: result)
        case "exitPictureInPicture":
            handleExitPictureInPicture(result: result)
        case "enableAutomaticInlinePip":
            handleEnableAutomaticInlinePip(result: result)
        case "disableAutomaticInlinePip":
            handleDisableAutomaticInlinePip(result: result)
        case "setShowNativeControls":
            handleSetShowNativeControls(call: call, result: result)
        case "setViewportSize":
            handleSetViewportSize(call: call, result: result)
        case "ensureSurfaceConnected":
            // No-op on iOS; each platform view uses its own AVPlayerViewController when shared.
            result(nil)
        case "isAirPlayAvailable":
            handleIsAirPlayAvailable(result: result)
        case "showAirPlayPicker":
            handleShowAirPlayPicker(result: result)
        case "disconnectAirPlay":
            handleDisconnectAirPlay(result: result)
        case "startAirPlayDetection":
            handleStartAirPlayDetection(result: result)
        case "stopAirPlayDetection":
            handleStopAirPlayDetection(result: result)
        case "dispose":
            handleDispose(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func sendEvent(_ name: String, data: [String: Any]? = nil) {
        var event: [String: Any] = ["event": name]
        if let data = data {
            event.merge(data) { (_, new) in
                new
            }
        }
        DispatchQueue.main.async {
            self.eventSink?(event)
        }
    }

    /// Cleans up remote command ownership, attempting to transfer to another view if possible
    /// This is called from both deinit and handleDispose to avoid duplication
    func cleanupRemoteCommandOwnership() {
        // Only proceed if this view owns the remote commands
        guard RemoteCommandManager.shared.isOwner(viewId) else {
            return
        }

        npLog("🎛️ View \(viewId) owned remote commands - attempting transfer")

        // Try to transfer ownership to another view with the same controller
        var ownershipTransferred = false
        if let controllerIdValue = controllerId,
           let alternativeView = SharedPlayerManager.shared.findAnotherViewForController(controllerIdValue, excluding: viewId) {
            npLog("🎛️ Transferring ownership to view \(alternativeView.viewId)")

            // Transfer ownership by setting up Now Playing info on the alternative view
            var mediaInfo = alternativeView.currentMediaInfo

            // Fallback: Try to get media info from SharedPlayerManager
            if mediaInfo == nil {
                mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
                if mediaInfo != nil {
                    npLog("📱 Retrieved media info from SharedPlayerManager for ownership transfer")
                    alternativeView.currentMediaInfo = mediaInfo
                }
            }

            if let mediaInfo = mediaInfo {
                alternativeView.setupNowPlayingInfo(mediaInfo: mediaInfo)
                ownershipTransferred = true
                npLog("✅ Ownership transferred to view \(alternativeView.viewId)")
            } else {
                npLog("⚠️ Alternative view has no media info - cannot transfer")
            }
        }

        // CRITICAL: If no transfer was possible BUT PiP is active OR restoring, DO NOT clear Now Playing info
        // PiP needs the media controls to work, so we must preserve them
        if !ownershipTransferred {
            // Check if PiP is active:
            // 1. On this view (isPipCurrentlyActive)
            // 2. On ANY view for this controller (isPipActiveForController)
            // 3. Currently restoring UI (isPipRestoringUI)
            let isPipActiveForController = controllerId.flatMap { SharedPlayerManager.shared.isPipActiveForController($0) } ?? false

            if isPipCurrentlyActive || isPipRestoringUI || isPipActiveForController {
                if isPipCurrentlyActive {
                    npLog("⚠️ No transfer possible but PiP is active on this view - keeping Now Playing info")
                } else if isPipRestoringUI {
                    npLog("⚠️ No transfer possible but PiP is restoring UI - keeping Now Playing info")
                } else {
                    npLog("⚠️ No transfer possible but PiP is active on another view for controller \(controllerId ?? -1) - keeping Now Playing info")
                }
                // Just clear the ownership flag, but keep the Now Playing info and remote commands active
                RemoteCommandManager.shared.clearOwner(viewId)
                // Do NOT clear nowPlayingInfo or remove targets while PiP is active or restoring
            } else {
                npLog("🗑️ No transfer possible and PiP is not active - clearing ownership and Now Playing info")
                RemoteCommandManager.shared.clearOwner(viewId)
                RemoteCommandManager.shared.removeAllTargets()
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
        }
    }

    /// Emits all current player states to ensure UI is in sync
    /// This is useful after events like exiting PiP where the UI needs to refresh
    public func emitCurrentState() {
        guard let player = player, let currentItem = player.currentItem else {
            npLog("[\(channelName)] No player or item available to emit state")
            return
        }

        npLog("[\(channelName)] Emitting current state after PiP exit")

        // Emit current time and duration
        let currentTimeSeconds = CMTimeGetSeconds(player.currentTime())
        let durationSeconds = CMTimeGetSeconds(currentItem.duration)

        if !currentTimeSeconds.isNaN && !durationSeconds.isNaN && durationSeconds > 0 {
            let duration = Int(durationSeconds * 1000)
            let position = Int(currentTimeSeconds * 1000)

            // Get buffered position
            var bufferedSeconds = 0.0
            let timeRanges = currentItem.loadedTimeRanges
            if !timeRanges.isEmpty {
                let bufferedRange = timeRanges.last!.timeRangeValue
                let bufferedEnd = CMTimeAdd(bufferedRange.start, bufferedRange.duration)
                bufferedSeconds = CMTimeGetSeconds(bufferedEnd)
            }
            let bufferedPosition = Int(bufferedSeconds * 1000)

            sendEvent("timeUpdate", data: [
                "position": position,
                "duration": duration,
                "bufferedPosition": bufferedPosition,
                "isBuffering": player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            ])
            npLog("[\(channelName)] Emitted timeUpdate with duration: \(duration)ms")
        }

        // Emit current playback state
        switch player.timeControlStatus {
        case .playing:
            npLog("[\(channelName)] Emitting play state")
            sendEvent("play")
        case .paused:
            npLog("[\(channelName)] Emitting pause state")
            sendEvent("pause")
        case .waitingToPlayAtSpecifiedRate:
            npLog("[\(channelName)] Emitting buffering state")
            sendEvent("buffering")
        @unknown default:
            break
        }

        // Emit current PiP state
        let isPipActive = isPipCurrentlyActive ||
                          (controllerId.flatMap { SharedPlayerManager.shared.isPipActiveForController($0) } ?? false)

        if isPipActive {
            npLog("[\(channelName)] Emitting pipStart state")
            sendEvent("pipStart", data: ["isPictureInPicture": true])
        } else {
            npLog("[\(channelName)] Emitting pipStop state")
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        }
    }

    // MARK: - FlutterStreamHandler
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        npLog("[\(channelName)] Event channel listener attached")
        self.eventSink = events

        // Send initial state event when listener is attached
        if isSharedPlayer {
            // For shared players, only send current playback state and position
            if let player = player, let currentItem = player.currentItem {
                let currentTimeSeconds = CMTimeGetSeconds(player.currentTime())
                let durationSeconds = CMTimeGetSeconds(currentItem.duration)

                // Check for NaN or invalid times
                if currentTimeSeconds.isNaN || durationSeconds.isNaN {
                    npLog("[\(channelName)] Skipping timeUpdated event — invalid currentTime or duration")
                } else {
                    let duration = Int(durationSeconds * 1000)
                    let position = Int(currentTimeSeconds * 1000)
                    sendEvent("timeUpdated", data: ["position": position, "duration": duration])
                }

                // Send current playback state
                switch player.timeControlStatus {
                case .playing:
                    npLog("[\(channelName)] Sending play event to new listener")
                    sendEvent("play")
                case .paused:
                    npLog("[\(channelName)] Sending pause event to new listener")
                    sendEvent("pause")
                case .waitingToPlayAtSpecifiedRate:
                    npLog("[\(channelName)] Sending buffering event to new listener")
                    sendEvent("buffering")
                @unknown default:
                    break
                }
            }

        } else {
            // For new players, send isInitialized event
            npLog("[\(channelName)] Sending isInitialized event to new listener")
            sendEvent("isInitialized")
        }

        // Send initial AirPlay availability state (from the app-wide detector)
        if #available(iOS 11.0, *) {
            let isAvailable = SharedPlayerManager.shared.isAirPlayRouteAvailable
            npLog("[\(channelName)] Sending initial AirPlay availability: \(isAvailable)")
            sendEvent("airPlayAvailabilityChanged", data: ["isAvailable": isAvailable])
        }

        // Send initial AirPlay connection state
        // Check at system level (audio route) rather than just this player's state
        // This ensures we detect if ANY player in the app is using AirPlay
        npLog("[\(channelName)] 🔍 Checking initial AirPlay state on event listener attach")
        let deviceName = getAirPlayDeviceName()
        let isSystemAirPlayActive = deviceName != nil

        if let player = player {
            // Check if THIS specific player is using AirPlay
            let isPlayerAirPlayActive = player.isExternalPlaybackActive

            // We're connected if either:
            // 1. This player is actively using AirPlay, OR
            // 2. AirPlay device is detected in audio route (another player might be using it)
            let isConnected = isPlayerAirPlayActive || isSystemAirPlayActive

            if isConnected {
                npLog("[\(channelName)] ✅ AirPlay active on init:")
                npLog("   - Player active: \(isPlayerAirPlayActive)")
                npLog("   - System active: \(isSystemAirPlayActive)")
                npLog("   - Device: \(deviceName ?? "nil")")

                var eventData: [String: Any] = ["isConnected": true, "isConnecting": false]
                if let deviceName = deviceName {
                    eventData["deviceName"] = deviceName
                }
                sendEvent("airPlayConnectionChanged", data: eventData)

                // If device name is not available yet, start retry sequence
                if deviceName == nil {
                    npLog("[\(channelName)] ⏳ Device name not available on init, starting retry sequence...")
                    retryGetAirPlayDeviceName(attempt: 1, maxAttempts: 4)
                }
            } else {
                // Not connected at system or player level
                npLog("[\(channelName)] ❌ AirPlay not connected on init")
                sendEvent("airPlayConnectionChanged", data: ["isConnected": false, "isConnecting": false])
            }
        }

        // Send initial PiP state
        // Check if PiP is currently active on this view or any view for the same controller
        npLog("[\(channelName)] 🔍 Checking initial PiP state on event listener attach")
        let isPipActive = isPipCurrentlyActive ||
                          (controllerId.flatMap { SharedPlayerManager.shared.isPipActiveForController($0) } ?? false)

        if isPipActive {
            npLog("[\(channelName)] ✅ PiP is active on init")
            sendEvent("pipStart", data: ["isPictureInPicture": true])
        } else {
            npLog("[\(channelName)] ℹ️ PiP is not active on init")
            // Send pipStop to ensure Flutter knows PiP is not active
            sendEvent("pipStop", data: ["isPictureInPicture": false])
        }

        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        npLog("[\(channelName)] Event channel listener detached")
        self.eventSink = nil
        return nil
    }

    deinit {
        npLog("VideoPlayerView deinit for channel: \(channelName), viewId: \(viewId)")

        // Drop this view from the plugin's method-call routing registry
        NativeVideoPlayerPlugin.unregisterView(withId: viewId)

        // Use the isPipCurrentlyActive flag to check if PiP is active
        let isPipActiveNow = isPipCurrentlyActive

        // ALWAYS emit PiP state on disposal to ensure Flutter side is synchronized
        // This is important for state management even if PiP is not active
        if isPipActiveNow {
            npLog("⚠️ View being disposed while PiP is active - sending pipStop event")
        } else {
            npLog("ℹ️ View being disposed while PiP is inactive - sending pipStop event for state sync")
        }

        // Always send pipStop event - either from this view or an alternative
        if eventSink != nil {
            // This view still has a listener, send from here
            sendEvent("pipStop", data: ["isPictureInPicture": false])
            npLog("✅ Sent pipStop event from disposing view \(viewId)")
        } else if let controllerIdValue = controllerId,
                  let alternativeView = SharedPlayerManager.shared.findAnotherViewForController(controllerIdValue, excluding: viewId),
                  alternativeView.eventSink != nil {
            // Send from alternative view if it exists and has a listener
            alternativeView.sendEvent("pipStop", data: ["isPictureInPicture": false])
            npLog("✅ Sent pipStop event from alternative view \(alternativeView.viewId)")
        } else {
            npLog("⚠️ No active view with listener found - pipStop event cannot be sent")
        }

        // Try to stop PiP gracefully if it was active
        if isPipActiveNow {
            if #available(iOS 14.0, *) {
                if let pipCtrl = pipController, pipCtrl.isPictureInPictureActive {
                    pipCtrl.stopPictureInPicture()
                }
            }
        }

        // Clean up remote command ownership (transfer to another view if possible)
        cleanupRemoteCommandOwnership()

        // Handle automatic PiP transfer for shared players
        // If this was the primary view (the one with automatic PiP enabled) OR if the player is playing,
        // we need to transfer automatic PiP to another view using the same controller
        if #available(iOS 14.2, *), let controllerIdValue = controllerId {
            let wasPrimaryView = SharedPlayerManager.shared.isPrimaryView(viewId, for: controllerIdValue)
            let wasAutoEnabled = SharedPlayerManager.shared.isControllerActiveForAutoPiP(controllerIdValue)
            let isPlaying = player?.rate ?? 0 > 0

            // Transfer automatic PiP if:
            // 1. This was the primary view AND auto PiP was enabled, OR
            // 2. The player is currently playing (should maintain auto PiP capability)
            if (wasPrimaryView && wasAutoEnabled) || isPlaying {
                npLog("🎬 View being disposed (primary: \(wasPrimaryView), autoEnabled: \(wasAutoEnabled), playing: \(isPlaying)) - transferring automatic PiP to another view")

                // Disable automatic PiP on this view before unregistering
                setAutomaticInlinePiP(false)

                // Unregister this view first so it won't be found
                SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)

                // Re-enable automatic PiP - this will find and enable a different view
                // for the same controller (if any exists)
                SharedPlayerManager.shared.setAutomaticPiPEnabled(for: controllerIdValue, enabled: true)
                npLog("✅ Automatic PiP transferred to another view for controller \(controllerIdValue)")
            } else {
                // Normal unregister for non-primary views
                SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)
            }
        } else {
            // Normal unregister for non-shared players
            SharedPlayerManager.shared.unregisterVideoPlayerView(viewId: viewId)
        }

        // Remove periodic time observer
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        // Only remove observers, don't dispose the player if it's shared
        // The shared player will be kept alive for reuse. Removal is
        // bookkeeping-guarded: this view may never have registered (created
        // but never loaded), and blind removal throws NSRangeException.
        removeItemObservers()
        removePlayerStateObservers()

        NotificationCenter.default.removeObserver(self)
        tearDownChannels()

        // Clean up DRM handler
        drmHandler?.cleanup()
        drmHandler = nil

        // Clear current media info from this view
        // BUT do NOT clear from SharedPlayerManager if PiP is active
        // This ensures media controls survive view disposal during PiP
        currentMediaInfo = nil
        if !isPipActiveNow {
            // Only clear from SharedPlayerManager if PiP is NOT active
            if let controllerIdValue = controllerId {
                // But first check if there are other views using this controller
                let otherViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
                if otherViews.count <= 1 {
                    // This is the last view, safe to clear media info
                    npLog("🧹 Clearing media info from SharedPlayerManager (last view)")
                } else {
                    npLog("📱 Keeping media info in SharedPlayerManager (other views exist)")
                }
            }
        } else {
            npLog("📱 Keeping media info in SharedPlayerManager (PiP is active)")
        }

        // Emit current state to all remaining views for this controller
        // This ensures other views stay in sync when one view is disposed
        if let controllerIdValue = controllerId {
            let remainingViews = SharedPlayerManager.shared.findAllViewsForController(controllerIdValue)
            if !remainingViews.isEmpty {
                npLog("📤 Emitting current state to \(remainingViews.count) remaining view(s) for controller \(controllerIdValue)")
                for view in remainingViews {
                    // Skip the view being disposed (just in case it's still in the list)
                    if view.viewId != viewId {
                        view.emitCurrentState()
                    }
                }
            }
        }

        // Light views always detach their layer so a remaining surface (an
        // inline tile's layer, or a shared VC) resumes rendering deterministically.
        lightView?.playerLayer.player = nil

        // Texture resources (display link, video output, engine texture).
        textureRenderer?.shutdown()

        // For Dart fullscreen platform view, release the dedicated VC's player so it tears down.
        // The shared player and shared VC (inline view) are left untouched.
        if isDartFullscreenView && usesViewControllerDisplay {
            playerViewController.player = nil
            npLog("✅ Dart fullscreen platform view disposed - released dedicated AVPlayerViewController")
        }

        // CRITICAL: For shared controllers, player and playerViewController are NOT disposed here
        // They're managed by SharedPlayerManager and persist across platform view disposal
        // This ensures PiP delegate callbacks continue to work when navigating between screens
        // Resources will be disposed when controller.dispose() is called from Dart
        if controllerId != nil && !isDartFullscreenView {
            npLog("✅ Platform view disposed but player AND view controller kept alive for controller ID: \(String(describing: controllerId))")
        } else if controllerId != nil && isDartFullscreenView {
            npLog("✅ Dart fullscreen platform view disposed - shared player/VC kept alive for controller ID: \(String(describing: controllerId))")
        } else {
            npLog("Platform view disposed for non-shared player")
        }
    }

    // MARK: - App Lifecycle Handling

    /// Called when app enters background (including screen lock)
    /// Keeps audio session active to allow background playback
    @objc func handleAppDidEnterBackground() {
        npLog("📱 App entering background (screen lock) - maintaining audio session for view \(viewId)")

        // Store current playback rate before iOS might pause it
        let wasPlaying = player?.rate ?? 0 > 0

        // CRITICAL: Ensure audio session stays active when screen locks
        // This prevents iOS from pausing the video
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            npLog("   → Audio session kept active during background/lock")
        } catch {
            npLog("   ⚠️ Failed to keep audio session active: \(error.localizedDescription)")
        }

        // CRITICAL: iOS will pause AVPlayer when screen locks
        // We need to resume playback to continue audio in background
        if wasPlaying {
            // Small delay to ensure background transition completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, let player = self.player else { return }

                // Resume playback at the desired speed
                player.play()
                player.rate = self.desiredPlaybackSpeed
                npLog("   → Resumed playback for background audio (rate: \(self.desiredPlaybackSpeed))")
            }
        } else {
            npLog("   → Player was not playing, not resuming")
        }
    }

    /// Called when app returns to foreground
    /// Restores Now Playing info which may have been cleared by the system
    @objc func handleAppWillEnterForeground() {
        npLog("📱 App entering foreground - restoring Now Playing info for view \(viewId)")

        // CRITICAL: Reactivate audio session first
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            npLog("   → Audio session reactivated")
        } catch {
            npLog("   ⚠️ Failed to reactivate audio session: \(error.localizedDescription)")
        }

        // Check if this view owns the remote commands
        guard RemoteCommandManager.shared.isOwner(viewId) else {
            npLog("   → View \(viewId) doesn't own remote commands, skipping restore")
            return
        }

        // Check if we have media info to restore
        var mediaInfo = currentMediaInfo

        // Fallback: Try to retrieve from SharedPlayerManager if not available locally
        if mediaInfo == nil, let controllerIdValue = controllerId {
            mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
            if mediaInfo != nil {
                npLog("   → Retrieved media info from SharedPlayerManager")
                currentMediaInfo = mediaInfo // Update local copy
            }
        }

        guard let mediaInfo = mediaInfo else {
            npLog("   ⚠️ No media info available to restore")
            return
        }

        // Delay slightly to ensure audio session is fully active
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            // Restore Now Playing info
            npLog("   → Restoring Now Playing info: \(mediaInfo["title"] ?? "Unknown")")
            self.setupNowPlayingInfo(mediaInfo: mediaInfo)

            // Also update the playback time to ensure controls show correct position
            self.updateNowPlayingPlaybackTime()
        }
    }

    /// Called when audio session is interrupted (e.g., phone call, other app's audio)
    @objc func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        npLog("🔊 Audio session interruption: \(type == .began ? "began" : "ended")")

        switch type {
        case .began:
            npLog("   → Audio session interrupted, Now Playing info may be cleared")

        case .ended:
            // Check if we should resume playback
            var shouldResume = false
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    shouldResume = true
                    npLog("   → Should resume after interruption")
                }
            }

            // Reactivate audio session
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                npLog("   → Audio session reactivated")
            } catch {
                npLog("   ⚠️ Failed to reactivate audio session: \(error.localizedDescription)")
            }

            // Restore Now Playing info and resume playback if needed
            if RemoteCommandManager.shared.isOwner(viewId) {
                var mediaInfo = currentMediaInfo
                if mediaInfo == nil, let controllerIdValue = controllerId {
                    mediaInfo = SharedPlayerManager.shared.getMediaInfo(for: controllerIdValue)
                }

                if let mediaInfo = mediaInfo {
                    npLog("   → Restoring Now Playing info after interruption")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self = self else { return }
                        self.setupNowPlayingInfo(mediaInfo: mediaInfo)
                        self.updateNowPlayingPlaybackTime()

                        // Auto-resume playback if the system recommends it
                        if shouldResume {
                            npLog("   → Auto-resuming playback after interruption")
                            self.player?.play()
                        }
                    }
                }
            }

        @unknown default:
            break
        }
    }
}


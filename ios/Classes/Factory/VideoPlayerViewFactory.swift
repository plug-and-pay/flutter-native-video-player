import Flutter
import UIKit

@objc public class NativeVideoPlayerPlugin: NSObject, FlutterPlugin {
    /// Retains a controller-level EventChannel together with its handler so the
    /// channel can be deregistered (`setStreamHandler(nil)`) on teardown.
    private struct ControllerChannelEntry {
        let channel: FlutterEventChannel
        let handler: ControllerEventChannelHandler
    }

    // Weak references: the Flutter engine owns platform views, and deinit is
    // the ONLY disposal hook a FlutterPlatformView gets on iOS. Holding views
    // strongly here would keep every view (and its KVO/time observers) alive
    // forever and make deinit unreachable.
    private static var registeredViews: [Int64: WeakVideoPlayerViewWrapper] = [:]
    private static var controllerEventChannels: [Int: ControllerChannelEntry] = [:]
    private static var messenger: FlutterBinaryMessenger?

    // Texture rendering mode: the engine never owns texture-backed views
    // (they are not platform views), so the plugin retains them STRONGLY
    // until 'viewDisposed' / hot-restart cleanup — the same ownership
    // lesson as the EventChannel-handler leak fix. The weak registry above
    // still serves method routing for them.
    private static var textureRegistry: FlutterTextureRegistry?
    private static var textureViews: [Int64: VideoPlayerView] = [:]

    private static func disposeAllTextureBackedViews() {
        for (viewId, view) in textureViews {
            view.tearDownChannels()
            npLog("🧹 Disposed texture-backed view \(viewId) (hot restart/teardown)")
        }
        textureViews.removeAll()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        messenger = registrar.messenger()
        textureRegistry = registrar.textures()
        npLog("Registering NativeVideoPlayerPlugin")
        let factory = VideoPlayerViewFactory(messenger: registrar.messenger())
        registrar.register(factory, withId: "native_video_player")
        npLog("NativeVideoPlayerPlugin registered with id: native_video_player")

        // Register a method handler at the plugin level to forward calls to the appropriate view
        let channel = FlutterMethodChannel(name: "native_video_player", binaryMessenger: registrar.messenger())
        channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            npLog("Plugin received method call: \(call.method)")

            // Handle controller-level methods
            if call.method == "setupControllerEventChannel" {
                // Called from the Dart controller constructor BEFORE Dart listens
                // on native_video_player_controller_<id>, so the listen call always
                // finds a registered handler (avoids MissingPluginException).
                if let args = call.arguments as? [String: Any],
                   let controllerId = args["controllerId"] as? Int {
                    NativeVideoPlayerPlugin.setupControllerEventChannel(for: controllerId)
                    result(nil)
                } else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "Controller ID is required", details: nil))
                }
                return
            }

            if call.method == "teardownControllerEventChannel" {
                if let args = call.arguments as? [String: Any],
                   let controllerId = args["controllerId"] as? Int {
                    NativeVideoPlayerPlugin.teardownControllerEventChannel(for: controllerId)
                    result(nil)
                } else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "Controller ID is required", details: nil))
                }
                return
            }

            if call.method == "discoverCastDevices" {
                // Bonjour browse via the system daemon — Dart-side mDNS would
                // need the restricted multicast entitlement on real devices.
                if #available(iOS 13.0, *) {
                    let args = call.arguments as? [String: Any]
                    let timeoutMs = args?["timeoutMs"] as? Int ?? 5000
                    CastDeviceDiscoverer.shared.discover(timeoutMs: timeoutMs, result: result)
                } else {
                    result(FlutterError(
                        code: "CAST_DISCOVERY_UNSUPPORTED",
                        message: "Cast discovery requires iOS 13 or newer",
                        details: nil))
                }
                return
            }

            if call.method == "viewDisposed" {
                // Sent by the Dart widget when its platform view is disposed.
                // Releases the per-view channel handlers: the EventChannel
                // stream handler strongly retains the view, so this is what
                // makes the view's deinit reachable. For texture-backed
                // views it also drops the plugin's strong reference.
                if let args = call.arguments as? [String: Any],
                   let viewId = args["viewId"] as? Int64 {
                    registeredViews[viewId]?.view?.tearDownChannels()
                    registeredViews.removeValue(forKey: viewId)
                    textureViews.removeValue(forKey: viewId)
                }
                result(nil)
                return
            }

            if call.method == "createTextureView" {
                // Texture rendering mode (iosTextureMode): the Dart widget
                // allocated the viewId from platformViewsRegistry and sends
                // the same creationParams a platform view would get.
                guard let registry = textureRegistry else {
                    result(FlutterError(code: "NO_ENGINE", message: "Texture registry unavailable", details: nil))
                    return
                }
                guard var args = call.arguments as? [String: Any],
                      let viewId = args["viewId"] as? Int64,
                      let messenger = messenger else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "viewId is required", details: nil))
                    return
                }
                args["isTextureView"] = true
                // The view's init registers its channels and routing entry
                // BEFORE this call returns, so the Dart subscribe-retry
                // always finds a live handler.
                let view = VideoPlayerView(
                    frame: .zero,
                    viewIdentifier: viewId,
                    arguments: args,
                    binaryMessenger: messenger
                )
                guard let player = view.player else {
                    result(FlutterError(code: "NO_PLAYER", message: "Player unavailable", details: nil))
                    return
                }
                let renderer = TexturePlayerRenderer(player: player, registry: registry)
                renderer.onVideoSizeChanged = { [weak view] size in
                    view?.sendEvent("videoSize", data: [
                        "width": Double(size.width),
                        "height": Double(size.height),
                        "rotationCorrection": 0,
                    ])
                }
                view.textureRenderer = renderer
                renderer.register(with: registry)
                registerView(view, withId: viewId)
                textureViews[viewId] = view
                result(["textureId": renderer.textureId])
                return
            }

            if call.method == "disposeAllTextureViews" {
                // Hot-restart hygiene: the Dart isolate forgot its texture
                // views but they survive natively — called once per isolate
                // before the first createTextureView.
                disposeAllTextureBackedViews()
                result(nil)
                return
            }

            if call.method == "disposeController" {
                // Releases the shared native player by controller ID. Used by Dart
                // dispose() when no platform view is alive (after releaseResources())
                // so the native player cannot leak.
                if let args = call.arguments as? [String: Any],
                   let controllerId = args["controllerId"] as? Int {
                    SharedPlayerManager.shared.removePlayer(for: controllerId)
                    result(nil)
                } else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "Controller ID is required", details: nil))
                }
                return
            }

            // Forward view-level methods to the appropriate view
            if let args = call.arguments as? [String: Any],
               let viewId = args["viewId"] as? Int64,
               let view = registeredViews[viewId]?.view {
                view.handleMethodCall(call: call, result: result)
            } else {
                result(FlutterError(code: "NO_VIEW", message: "No view found for method call", details: nil))
            }
        }

        // Register asset resolution channel
        let assetChannel = FlutterMethodChannel(name: "native_video_player/assets", binaryMessenger: registrar.messenger())
        assetChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            if call.method == "resolveAssetPath" {
                if let args = call.arguments as? [String: Any],
                   let assetKey = args["assetKey"] as? String {
                    // Flutter assets are bundled in the app's main bundle
                    let key = registrar.lookupKey(forAsset: assetKey)
                    if let path = Bundle.main.path(forResource: key, ofType: nil) {
                        npLog("Resolved asset '\(assetKey)' to '\(path)'")
                        result(path)
                    } else {
                        result(FlutterError(code: "ASSET_NOT_FOUND", message: "Asset not found: \(assetKey)", details: nil))
                    }
                } else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "Asset key is required", details: nil))
                }
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }
    
    public static func registerView(_ view: VideoPlayerView, withId viewId: Int64) {
        npLog("Registering view with id: \(viewId)")
        // Prune entries whose views have been deallocated
        registeredViews = registeredViews.filter { $0.value.view != nil }
        registeredViews[viewId] = WeakVideoPlayerViewWrapper(view: view)
    }

    public static func unregisterView(withId viewId: Int64) {
        npLog("Unregistering view with id: \(viewId)")
        registeredViews.removeValue(forKey: viewId)
    }

    /// Registers the StreamHandler for `native_video_player_controller_<id>`.
    ///
    /// Idempotent: an existing registration is kept (Dart re-listening simply
    /// replaces the sink via the handler's onListen). Called both via the shared
    /// method channel (from the Dart controller constructor, before Dart listens)
    /// and from VideoPlayerView init as a safety net.
    public static func setupControllerEventChannel(for controllerId: Int) {
        guard controllerEventChannels[controllerId] == nil else {
            return
        }

        guard let messenger = messenger else {
            npLog("⚠️ Cannot setup controller event channel - messenger is nil")
            return
        }

        let handler = ControllerEventChannelHandler(controllerId: controllerId)
        let channel = FlutterEventChannel(
            name: "native_video_player_controller_\(controllerId)",
            binaryMessenger: messenger
        )
        channel.setStreamHandler(handler)
        controllerEventChannels[controllerId] = ControllerChannelEntry(channel: channel, handler: handler)
    }

    /// Deregisters the channel registered by `setupControllerEventChannel`.
    /// Idempotent; also defensively drops the sink in case onCancel never ran.
    public static func teardownControllerEventChannel(for controllerId: Int) {
        if let entry = controllerEventChannels.removeValue(forKey: controllerId) {
            entry.channel.setStreamHandler(nil)
        }
        SharedPlayerManager.shared.unregisterControllerEventSink(for: controllerId)
    }
}

class VideoPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        npLog("VideoPlayerViewFactory creating view with id: \(viewId)")
        let view = VideoPlayerView(
            frame: frame,
            viewIdentifier: viewId,
            arguments: args,
            binaryMessenger: messenger
        )
        // The engine owns the view; the plugin only keeps a weak registry for
        // method-call routing (a strong reference here would prevent deinit,
        // which is the platform view's only disposal hook on iOS).
        NativeVideoPlayerPlugin.registerView(view, withId: viewId)
        return view
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

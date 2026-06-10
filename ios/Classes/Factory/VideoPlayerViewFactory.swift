import Flutter
import UIKit

@objc public class NativeVideoPlayerPlugin: NSObject, FlutterPlugin {
    /// Retains a controller-level EventChannel together with its handler so the
    /// channel can be deregistered (`setStreamHandler(nil)`) on teardown.
    private struct ControllerChannelEntry {
        let channel: FlutterEventChannel
        let handler: ControllerEventChannelHandler
    }

    private static var registeredViews: [Int64: VideoPlayerView] = [:]
    private static var controllerEventChannels: [Int: ControllerChannelEntry] = [:]
    private static var messenger: FlutterBinaryMessenger?

    public static func register(with registrar: FlutterPluginRegistrar) {
        messenger = registrar.messenger()
        print("Registering NativeVideoPlayerPlugin")
        let factory = VideoPlayerViewFactory(messenger: registrar.messenger())
        registrar.register(factory, withId: "native_video_player")
        print("NativeVideoPlayerPlugin registered with id: native_video_player")

        // Register a method handler at the plugin level to forward calls to the appropriate view
        let channel = FlutterMethodChannel(name: "native_video_player", binaryMessenger: registrar.messenger())
        channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
            print("Plugin received method call: \(call.method)")

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
               let view = registeredViews[viewId] {
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
                        print("Resolved asset '\(assetKey)' to '\(path)'")
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
        print("Registering view with id: \(viewId)")
        registeredViews[viewId] = view
    }
    
    public static func unregisterView(withId viewId: Int64) {
        print("Unregistering view with id: \(viewId)")
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
            print("⚠️ Cannot setup controller event channel - messenger is nil")
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
    private var views: [Int64: VideoPlayerView] = [:]

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        print("VideoPlayerViewFactory creating view with id: \(viewId)")
        let view = VideoPlayerView(
            frame: frame,
            viewIdentifier: viewId,
            arguments: args,
            binaryMessenger: messenger
        )
        views[viewId] = view
        NativeVideoPlayerPlugin.registerView(view, withId: viewId)
        return view
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

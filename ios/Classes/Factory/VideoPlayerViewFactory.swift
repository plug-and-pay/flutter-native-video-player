import Flutter
import UIKit

@objc public class NativeVideoPlayerPlugin: NSObject, FlutterPlugin {
    private static var registeredViews: [Int64: VideoPlayerView] = [:]
    private static var controllerEventHandlers: [Int: ControllerEventChannelHandler] = [:]
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

    public static func setupControllerEventChannel(for controllerId: Int) {
        // Don't set up if already exists
        guard controllerEventHandlers[controllerId] == nil else {
            print("Controller event channel for controller \(controllerId) already exists")
            return
        }

        guard let messenger = messenger else {
            print("⚠️ Cannot setup controller event channel - messenger is nil")
            return
        }

        print("✅ Setting up controller event channel for controller \(controllerId)")
        let handler = ControllerEventChannelHandler(controllerId: controllerId)
        let channel = FlutterEventChannel(
            name: "native_video_player_controller_\(controllerId)",
            binaryMessenger: messenger
        )
        channel.setStreamHandler(handler)
        controllerEventHandlers[controllerId] = handler
    }

    public static func teardownControllerEventChannel(for controllerId: Int) {
        if let handler = controllerEventHandlers[controllerId] {
            print("🗑️ Tearing down controller event channel for controller \(controllerId)")
            controllerEventHandlers.removeValue(forKey: controllerId)
        }
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

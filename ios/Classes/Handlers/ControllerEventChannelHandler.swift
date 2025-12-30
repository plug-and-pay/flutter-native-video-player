import Flutter

/// Handler for controller-level event channels that persist independently of platform views
///
/// This handler manages the controller-level EventChannel that sends PiP and AirPlay events.
/// Unlike per-view event channels, this channel persists even when all platform views are disposed,
/// allowing events to flow after calling releaseResources(). It's only disposed when controller.dispose() is called.
class ControllerEventChannelHandler: NSObject, FlutterStreamHandler {
    private let controllerId: Int

    init(controllerId: Int) {
        self.controllerId = controllerId
        super.init()
    }

    /// Called when Flutter starts listening to the event channel
    /// Registers the event sink with SharedPlayerManager for persistent event delivery
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        print("📡 [ControllerEventChannelHandler] onListen called for controller \(controllerId)")
        SharedPlayerManager.shared.registerControllerEventSink(events, for: controllerId)
        return nil
    }

    /// Called when Flutter stops listening to the event channel
    /// Unregisters the event sink from SharedPlayerManager
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("🔌 [ControllerEventChannelHandler] onCancel called for controller \(controllerId)")
        SharedPlayerManager.shared.unregisterControllerEventSink(for: controllerId)
        return nil
    }
}

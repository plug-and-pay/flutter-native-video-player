import Flutter
import Network

/// Discovers Google Cast receivers (`_googlecast._tcp`) via the system
/// Bonjour browser (NWBrowser).
///
/// Why native instead of Dart-side mDNS: sending raw multicast UDP from an
/// app socket requires the restricted `com.apple.developer.networking.multicast`
/// entitlement on physical devices (Apple grants it per-account on request),
/// and without it the send fails with EHOSTUNREACH ("No route to host").
/// Bonjour browsing is exempt — mDNSResponder performs the multicast on the
/// app's behalf — and only needs `NSBonjourServices` +
/// `NSLocalNetworkUsageDescription` in the host app's Info.plist.
@available(iOS 13.0, *)
final class CastDeviceDiscoverer {
    static let shared = CastDeviceDiscoverer()

    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    private var devices: [String: [String: Any]] = [:]
    private var reply: FlutterResult?

    /// One-shot scan; replies after `timeoutMs` with every device resolved
    /// so far. Browsing errors before any device is found surface as
    /// CAST_DISCOVERY_FAILED.
    func discover(timeoutMs: Int, result: @escaping FlutterResult) {
        guard reply == nil else {
            result(FlutterError(
                code: "CAST_DISCOVERY_BUSY",
                message: "A Cast device scan is already running",
                details: nil))
            return
        }
        reply = result
        devices = [:]

        npLog("Cast discovery: starting Bonjour browse (\(timeoutMs)ms)")
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil),
            using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                npLog("Cast discovery: browse failed: \(error)")
                self?.finish(error: error)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results: results)
        }
        browser.start(queue: .main)

        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(timeoutMs)
        ) { [weak self] in
            self?.finish(error: nil)
        }
    }

    private func handle(results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            if devices[name] != nil || connections[name] != nil { continue }

            var friendlyName: String?
            var model: String?
            if case .bonjour(let txt) = result.metadata {
                friendlyName = txt["fn"]
                model = txt["md"]
            }

            // Bonjour results carry no address; a brief TCP connection to the
            // endpoint resolves it (remoteEndpoint is host:port once ready).
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            connections[name] = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? =
                        connection.currentPath?.remoteEndpoint {
                        var device: [String: Any] = [
                            "id": name,
                            "name": name,
                            "host": Self.hostString(host),
                            "port": Int(port.rawValue),
                        ]
                        if let friendlyName = friendlyName {
                            device["friendlyName"] = friendlyName
                        }
                        if let model = model { device["model"] = model }
                        npLog("Cast discovery: resolved \(friendlyName ?? name)")
                        self.devices[name] = device
                    }
                    connection.cancel()
                    self.connections[name] = nil
                case .failed, .cancelled:
                    self.connections[name] = nil
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return stripInterface("\(address)")
        case .ipv6(let address):
            return stripInterface("\(address)")
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }

    /// "192.168.1.252%en0" -> "192.168.1.252"
    private static func stripInterface(_ value: String) -> String {
        value.split(separator: "%").first.map(String.init) ?? value
    }

    private func finish(error: Error?) {
        guard let result = reply else { return }
        reply = nil
        browser?.cancel()
        browser = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        let found = Array(devices.values)
        npLog("Cast discovery: finished with \(found.count) device(s)")
        if let error = error, found.isEmpty {
            result(FlutterError(
                code: "CAST_DISCOVERY_FAILED",
                message: error.localizedDescription,
                details: nil))
        } else {
            result(found)
        }
    }
}

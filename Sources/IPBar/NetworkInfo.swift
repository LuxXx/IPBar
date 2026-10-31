import CoreLocation
import CoreWLAN
import Network
import Darwin

/// Local network context captured alongside each ipinfo lookup.
struct NetworkSnapshot: Equatable {
    var ssid: String?
    var interface: String?      // physical interface, e.g. "en0"
    var networkType: String?    // "wifi", "hotspot", "ethernet", "cellular", "other"
    var vpnInterface: String?   // e.g. "utun4" when a VPN tunnel is active

    var vpn: Bool { vpnInterface != nil }

    var logFields: [String: Any] {
        var fields: [String: Any] = ["vpn": vpn]
        fields["ssid"] = ssid
        fields["interface"] = interface
        fields["network_type"] = networkType
        fields["vpn_interface"] = vpnInterface
        return fields
    }

    var displayNetwork: String? {
        switch networkType {
        case "wifi": return ssid.map { "Wi-Fi “\($0)”" } ?? "Wi-Fi"
        case "hotspot": return ssid.map { "Hotspot “\($0)”" } ?? "Personal Hotspot"
        case "ethernet": return "Ethernet"
        case "cellular": return "Cellular"
        case nil: return nil
        default: return interface ?? "Other"
        }
    }
}

enum NetworkInfo {
    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]

    static func snapshot(path: NWPath?, includeSSID: Bool) -> NetworkSnapshot {
        var snapshot = NetworkSnapshot()

        if let physical = path?.availableInterfaces.first(where: { $0.type != .other && $0.type != .loopback }) {
            snapshot.interface = physical.name
            switch physical.type {
            case .wifi: snapshot.networkType = path?.isExpensive == true ? "hotspot" : "wifi"
            case .wiredEthernet: snapshot.networkType = path?.isExpensive == true ? "hotspot" : "ethernet"
            case .cellular: snapshot.networkType = "cellular"
            default: snapshot.networkType = "other"
            }
        }

        if includeSSID, snapshot.networkType == "wifi" || snapshot.networkType == "hotspot" {
            snapshot.ssid = CWWiFiClient.shared().interface()?.ssid()
        }

        snapshot.vpnInterface = activeTunnel(path: path)
        return snapshot
    }

    private static func isTunnel(_ name: String) -> Bool {
        tunnelPrefixes.contains { name.hasPrefix($0) }
    }

    /// A VPN counts as active only when internet traffic actually leaves through a
    /// tunnel. Split tunnels (e.g. Tailscale without an exit node) don't count.
    private static func activeTunnel(path: NWPath?) -> String? {
        guard let name = outboundInterface(), isTunnel(name) else { return nil }
        return name
    }

    /// The interface the OS would use to reach a public address. Connecting a UDP
    /// socket only performs a route lookup; no packets are sent.
    private static func outboundInterface() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(53).bigEndian
        inet_pton(AF_INET, "1.1.1.1", &remote.sin_addr)
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }

        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }
        var cursor = addresses
        while let entry = cursor?.pointee {
            if let addr = entry.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                let match = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr == local.sin_addr.s_addr
                }
                if match { return String(cString: entry.ifa_name) }
            }
            cursor = entry.ifa_next
        }
        return nil
    }
}

/// macOS only reveals the Wi-Fi name to apps with Location Services permission.
final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()

    private let manager = CLLocationManager()
    @Published private(set) var status: CLAuthorizationStatus

    private override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool { status == .authorizedAlways || status == .authorized }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
    }
}

import Foundation

enum PilotTunnelConstants {
    static let interfaceKey = "TunnelIfaceIP"
    static let peerKey = "TunnelPeerIP"

    // These match the LocalDevVPN setup already proven with Pikmin Pilot.
    static let defaultInterfaceCIDR = "10.7.1.1/24"
    static let defaultPeerCIDR = "10.7.0.1/32"
}

struct PilotIPv4CIDR {
    let ip: String
    let prefix: Int

    init(_ raw: String, defaultPrefix: Int) {
        let pieces = raw.split(separator: "/", omittingEmptySubsequences: false)
        self.ip = pieces.first.map(String.init) ?? raw
        if pieces.count > 1, let value = Int(pieces[1]), (0...32).contains(value) {
            self.prefix = value
        } else {
            self.prefix = defaultPrefix
        }
    }

    var subnetMask: String {
        let bits = prefix == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefix)
        return [24, 16, 8, 0].map { shift in
            String((bits >> UInt32(shift)) & 0xff)
        }.joined(separator: ".")
    }
}

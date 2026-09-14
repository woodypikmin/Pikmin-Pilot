import Foundation

enum PilotTunnelConstants {
    // Stage 11.5.4 cellular loopback experiment.
    // Keep the RSD peer at 10.7.0.1 so the proven idevice/RPPairing path is unchanged,
    // but make the PacketTunnel a true point-to-point /32 route. This prevents the
    // loopback transport from inheriting Wi-Fi/LAN subnet routing semantics.
    static let deviceIPKey = "TunnelDeviceIP"
    static let fakeIPKey = "TunnelFakeIP"
    static let subnetMaskKey = "TunnelSubnetMask"

    // Interface side of the synthetic point-to-point link.
    static let defaultDeviceIP = "10.7.1.1"
    // Synthetic peer used by RPPairing/RSD. This remains unchanged.
    static let defaultFakeIP = "10.7.0.1"
    // Host routes on both ends: only 10.7.0.1 is captured by the PacketTunnel.
    static let defaultSubnetMask = "255.255.255.255"
}

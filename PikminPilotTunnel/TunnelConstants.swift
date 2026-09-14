import Foundation

enum PilotTunnelConstants {
    // Match the known-working LocalDevVPN / StosVPN packet-reflector contract.
    static let deviceIPKey = "TunnelDeviceIP"
    static let fakeIPKey = "TunnelFakeIP"
    static let subnetMaskKey = "TunnelSubnetMask"

    // The phone owns 10.7.0.0 on the utun interface. Connections to the
    // synthetic developer endpoint 10.7.0.1 are reflected back to the phone.
    static let defaultDeviceIP = "10.7.0.0"
    static let defaultFakeIP = "10.7.0.1"
    static let defaultSubnetMask = "255.255.255.0"
}

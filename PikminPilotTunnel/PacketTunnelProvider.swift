import Foundation
import NetworkExtension
import Darwin

// Stage 11.5.4: cellular-safe point-to-point packet reflector.
//
// This intentionally keeps the proven Stage 11.5.3 RPPairing destination
// (10.7.0.1:49152), while changing only the local NEPacketTunnel shape:
//   utun interface = 10.7.1.1/32
//   synthetic peer = 10.7.0.1/32
//   included route = 10.7.0.1/32 only
//   default route = excluded
//
// Every IPv4 packet that reaches this provider is on the peer-only route, so
// reflecting it means swapping source/destination addresses and writing it back.
// The IPv4/TCP pseudo-header checksum sum is unchanged by an address swap.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var interfaceIP = PilotTunnelConstants.defaultDeviceIP
    private var peerIP = PilotTunnelConstants.defaultFakeIP
    private var hostMask = PilotTunnelConstants.defaultSubnetMask

    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

        if let value = options?[PilotTunnelConstants.deviceIPKey] as? String
            ?? providerConfig?[PilotTunnelConstants.deviceIPKey] as? String {
            interfaceIP = value
        }
        if let value = options?[PilotTunnelConstants.fakeIPKey] as? String
            ?? providerConfig?[PilotTunnelConstants.fakeIPKey] as? String {
            peerIP = value
        }
        if let value = options?[PilotTunnelConstants.subnetMaskKey] as? String
            ?? providerConfig?[PilotTunnelConstants.subnetMaskKey] as? String {
            hostMask = value
        }

        // A point-to-point tunnel should not use the peer's LAN/cellular path.
        // Only the synthetic peer is routed into this extension.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peerIP)
        let ipv4 = NEIPv4Settings(addresses: [interfaceIP], subnetMasks: [hostMask])
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: peerIP, subnetMask: "255.255.255.255")
        ]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }
            guard error == nil else {
                completionHandler(error)
                return
            }
            self.reflectPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    private func reflectPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }

            var modified = packets
            for index in modified.indices {
                guard index < protocols.count,
                      protocols[index].int32Value == AF_INET,
                      modified[index].count >= 20 else {
                    continue
                }

                modified[index].withUnsafeMutableBytes { raw in
                    guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                    // Swap IPv4 source [12...15] and destination [16...19].
                    // Because the provider only owns a /32 route to peerIP,
                    // these are precisely the packets that must be reflected.
                    for offset in 0..<4 {
                        let tmp = bytes[12 + offset]
                        bytes[12 + offset] = bytes[16 + offset]
                        bytes[16 + offset] = tmp
                    }
                }
            }

            self.packetFlow.writePackets(modified, withProtocols: protocols)
            self.reflectPackets()
        }
    }
}

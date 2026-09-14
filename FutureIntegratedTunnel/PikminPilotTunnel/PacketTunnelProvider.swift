import Foundation
import NetworkExtension
import Darwin

// Based on LocalDevVPN / StosVPN packet-loop behavior by the SideStore Team.
// See THIRD_PARTY_LOCALDEVVPN_LICENSE.txt in the project root.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var interfaceCIDR = PilotTunnelConstants.defaultInterfaceCIDR
    private var peerCIDR = PilotTunnelConstants.defaultPeerCIDR

    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

        if let value = options?[PilotTunnelConstants.interfaceKey] as? String
            ?? providerConfig?[PilotTunnelConstants.interfaceKey] as? String {
            interfaceCIDR = value
        }
        if let value = options?[PilotTunnelConstants.peerKey] as? String
            ?? providerConfig?[PilotTunnelConstants.peerKey] as? String {
            peerCIDR = value
        }

        let iface = PilotIPv4CIDR(interfaceCIDR, defaultPrefix: 24)
        let peer = PilotIPv4CIDR(peerCIDR, defaultPrefix: 32)

        let ipv4 = NEIPv4Settings(
            addresses: [iface.ip],
            subnetMasks: [iface.subnetMask]
        )
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: peer.ip, subnetMask: peer.subnetMask)
        ]
        // Keep ordinary traffic outside this loopback tunnel.
        ipv4.excludedRoutes = [.default()]

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peer.ip)
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }
            if let error {
                completionHandler(error)
                return
            }
            self.readAndReflectPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    private func readAndReflectPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }

            var reflected = packets
            for index in reflected.indices {
                guard index < protocols.count,
                      protocols[index].int32Value == AF_INET,
                      reflected[index].count >= 20 else {
                    continue
                }

                reflected[index].withUnsafeMutableBytes { raw in
                    guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    // IPv4 source bytes 12...15, destination bytes 16...19.
                    // Swapping these preserves the checksum sum while reflecting traffic
                    // back into the local device path.
                    for offset in 0..<4 {
                        let tmp = bytes[12 + offset]
                        bytes[12 + offset] = bytes[16 + offset]
                        bytes[16 + offset] = tmp
                    }
                }
            }

            self.packetFlow.writePackets(reflected, withProtocols: protocols)
            self.readAndReflectPackets()
        }
    }
}

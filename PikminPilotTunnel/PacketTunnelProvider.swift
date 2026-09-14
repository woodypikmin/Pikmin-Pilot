import Foundation
import NetworkExtension
import Darwin

// Local packet reflector based on the LocalDevVPN / StosVPN behavior already
// proven to make iOS connect back to its own developer services.
// See THIRD_PARTY_LOCALDEVVPN_LICENSE.txt.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var deviceIP = PilotTunnelConstants.defaultDeviceIP
    private var fakeIP = PilotTunnelConstants.defaultFakeIP
    private var subnetMask = PilotTunnelConstants.defaultSubnetMask

    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

        if let value = options?[PilotTunnelConstants.deviceIPKey] as? String
            ?? providerConfig?[PilotTunnelConstants.deviceIPKey] as? String {
            deviceIP = value
        }
        if let value = options?[PilotTunnelConstants.fakeIPKey] as? String
            ?? providerConfig?[PilotTunnelConstants.fakeIPKey] as? String {
            fakeIP = value
        }
        if let value = options?[PilotTunnelConstants.subnetMaskKey] as? String
            ?? providerConfig?[PilotTunnelConstants.subnetMaskKey] as? String {
            subnetMask = value
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: deviceIP)
        let ipv4 = NEIPv4Settings(addresses: [deviceIP], subnetMasks: [subnetMask])

        // Match LocalDevVPN / StosVPN: route the whole synthetic subnet into
        // the extension while ordinary traffic remains outside this tunnel.
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: deviceIP, subnetMask: subnetMask)
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
            let device = self.ipv4Bytes(self.deviceIP)
            let fake = self.ipv4Bytes(self.fakeIP)

            if let device, let fake {
                for index in modified.indices {
                    guard index < protocols.count,
                          protocols[index].int32Value == AF_INET,
                          modified[index].count >= 20 else {
                        continue
                    }

                    modified[index].withUnsafeMutableBytes { raw in
                        guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                        let srcMatchesDevice =
                            bytes[12] == device[0] && bytes[13] == device[1] &&
                            bytes[14] == device[2] && bytes[15] == device[3]
                        let dstMatchesFake =
                            bytes[16] == fake[0] && bytes[17] == fake[1] &&
                            bytes[18] == fake[2] && bytes[19] == fake[3]

                        // This is the LocalDevVPN transformation:
                        // outbound 10.7.0.0 -> 10.7.0.1 becomes
                        //          10.7.0.1 -> 10.7.0.0
                        // and is therefore delivered back into the same phone.
                        // Since the two endpoint addresses are exchanged, the
                        // IPv4/TCP pseudo-header checksum sum is preserved.
                        if srcMatchesDevice {
                            bytes[12] = fake[0]
                            bytes[13] = fake[1]
                            bytes[14] = fake[2]
                            bytes[15] = fake[3]
                        }
                        if dstMatchesFake {
                            bytes[16] = device[0]
                            bytes[17] = device[1]
                            bytes[18] = device[2]
                            bytes[19] = device[3]
                        }
                    }
                }
            }

            self.packetFlow.writePackets(modified, withProtocols: protocols)
            self.reflectPackets()
        }
    }

    private func ipv4Bytes(_ ip: String) -> [UInt8]? {
        let pieces = ip.split(separator: ".")
        guard pieces.count == 4 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(4)
        for piece in pieces {
            guard let byte = UInt8(piece) else { return nil }
            result.append(byte)
        }
        return result
    }
}

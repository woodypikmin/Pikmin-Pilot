import Foundation

enum NoVPNSelfTransportProbe {
    struct Report: Sendable {
        let lines: [String]
        var summary: String { lines.joined(separator: " • ") }
    }

    static func run() async -> Report {
        await Task.detached(priority: .userInitiated) {
            let capacity = 16_384
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
            buffer.initialize(repeating: 0, count: capacity)
            defer { buffer.deallocate() }

            _ = PPNoVPNSelfTransportProbe(buffer, capacity)
            let text = String(cString: buffer)
            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)

            return Report(lines: lines.isEmpty ? ["NO-VPN SELF PROBE • no diagnostic text"] : lines)
        }.value
    }
}

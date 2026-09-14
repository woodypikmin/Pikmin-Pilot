
import Foundation

protocol PilotTransport: Sendable {
    func connect() async throws
    func launchPikmin() async throws
}

enum PilotTransportError: LocalizedError {
    case pairingRecordMissing
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .pairingRecordMissing:
            return "需要先匯入 RPPairing Record"
        case .engine(let message):
            return message
        }
    }
}

actor EmbeddedDeviceTransport: PilotTransport {
    private let engine: IDeviceEngine

    init(pairingRecordPath: String) {
        self.engine = IDeviceEngine(
            pairingPath: pairingRecordPath,
            host: "10.7.0.1",
            port: 49152
        )
    }

    func connect() async throws {
        let result = await engine.probeRSD()
        guard result.ok else {
            throw PilotTransportError.engine(result.message)
        }
    }

    func launchPikmin() async throws {
        let result = await engine.launchPikmin()
        guard result.ok else {
            throw PilotTransportError.engine(result.message)
        }
    }
}

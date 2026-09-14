import Foundation
import UserNotifications

enum PhoneLocalPairingBootstrap {
    struct Result: Sendable {
        let ok: Bool
        let message: String
    }

    static var isSystemSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    /// On iOS 27 the PIN is generated only after the user taps "Pair with
    /// Pikmin Pilot" in Settings. A local notification lets the PIN remain
    /// visible while Settings is foreground without adding a Widget/Live
    /// Activity extension or another provisioning profile.
    static func requestPinNotificationPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    static func run(outputURL: URL, timeoutSeconds: UInt64 = 180) -> Result {
        let capacity = 8192
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        defer { buffer.deallocate() }

        let code: Int32 = outputURL.path.withCString { outputPath in
            PPStartPhoneLocalPairingHost(
                outputPath,
                timeoutSeconds,
                buffer,
                capacity
            )
        }
        let text = String(cString: buffer)
        return Result(
            ok: code == 0,
            message: text.isEmpty ? "phone-local pairing result code \(code)" : text
        )
    }

    static func currentStatus() -> String {
        let capacity = 4096
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        defer { buffer.deallocate() }
        _ = PPGetPhoneLocalPairingHostStatus(buffer, capacity)
        return String(cString: buffer)
    }
}

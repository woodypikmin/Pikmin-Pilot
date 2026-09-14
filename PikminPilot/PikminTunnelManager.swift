import Foundation
import NetworkExtension

@MainActor
final class PikminTunnelManager: ObservableObject {
    static let shared = PikminTunnelManager()

    enum TunnelState: String {
        case unknown = "UNKNOWN"
        case notInstalled = "SETUP REQUIRED"
        case disconnected = "DISCONNECTED"
        case connecting = "CONNECTING"
        case connected = "CONNECTED"
        case disconnecting = "DISCONNECTING"
        case error = "ERROR"
    }

    enum TunnelError: LocalizedError {
        case extensionMissing
        case configurationNotFound
        case connectTimeout(String)

        var errorDescription: String? {
            switch self {
            case .extensionMissing:
                return "Embedded PacketTunnelProvider not found inside Pikmin Pilot.app"
            case .configurationNotFound:
                return "Could not create/load Pikmin Pilot VPN configuration"
            case .connectTimeout(let detail):
                return "Integrated tunnel did not become connected in time (\(detail))"
            }
        }
    }

    @Published private(set) var state: TunnelState = .unknown
    @Published private(set) var detail = "尚未檢查"
    @Published private(set) var providerBundleID = "—"
    @Published private(set) var lastErrorDiagnostics = ""

    let deviceIP = "10.7.0.0"
    let fakeIP = "10.7.0.1"
    let subnetMask = "255.255.255.0"

    private let deviceIPKey = "TunnelDeviceIP"
    private let fakeIPKey = "TunnelFakeIP"
    private let subnetMaskKey = "TunnelSubnetMask"
    private let reflectorRevisionKey = "ReflectorRevision"
    private let reflectorRevision = "pikminpilot-localdevvpn-reflector-stage11.2.2"
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncPublishedState()
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func refresh() async {
        do {
            guard let embeddedID = embeddedTunnelBundleID() else {
                providerBundleID = "missing"
                state = .error
                detail = "內嵌 Tunnel extension 找不到"
                return
            }
            providerBundleID = embeddedID

            let managers = try await loadManagers()
            manager = managers.first(where: { candidate in
                guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else { return false }
                return proto.providerBundleIdentifier == embeddedID
            })

            if manager == nil {
                state = .notInstalled
                detail = "第一次使用請按 ENABLE / START；iOS 會要求新增 VPN 設定"
                return
            }
            syncPublishedState()
        } catch {
            state = .error
            lastErrorDiagnostics = diagnostics(for: error)
            detail = "讀取 VPN 設定失敗：\(lastErrorDiagnostics)"
        }
    }

    /// Creates the embedded PacketTunnel configuration if needed, starts it,
    /// and waits until the OS reports NEVPNStatus.connected.
    func ensureStarted(timeoutSeconds: Double = 12.0) async throws {
        guard let embeddedID = embeddedTunnelBundleID() else {
            throw TunnelError.extensionMissing
        }
        providerBundleID = embeddedID

        var managers = try await loadManagers()
        var localManager = managers.first(where: { candidate in
            guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else { return false }
            return proto.providerBundleIdentifier == embeddedID
        })

        if localManager == nil {
            let created = NETunnelProviderManager()
            created.localizedDescription = "Pikmin Pilot Local Tunnel"
            let proto = makeProtocol(providerBundleID: embeddedID)
            created.protocolConfiguration = proto
            created.isEnabled = true
            try await save(created)
            try await load(created)
            localManager = created
            managers = [created]
        }

        guard let localManager else {
            throw TunnelError.configurationNotFound
        }

        let previousRevision = ((localManager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?[reflectorRevisionKey] as? String)
        let isRunningOldProvider: Bool
        switch localManager.connection.status {
        case .connected, .connecting, .reasserting:
            isRunningOldProvider = true
        default:
            isRunningOldProvider = false
        }
        let mustRefreshRunningProvider = previousRevision != reflectorRevision && isRunningOldProvider

        manager = localManager

        // Re-write provider ID + addresses every time. This matters after
        // Sideloadly changes the signed bundle identifiers.
        localManager.protocolConfiguration = makeProtocol(providerBundleID: embeddedID)
        localManager.localizedDescription = "Pikmin Pilot Local Tunnel"
        localManager.isEnabled = true
        try await save(localManager)
        try await load(localManager)

        // Installing/replacing the host app does not guarantee that an already-running
        // PacketTunnelProvider process is relaunched. If the reflector revision changed,
        // explicitly tear down the old provider instance before using it.
        if mustRefreshRunningProvider {
            detail = "Tunnel extension 已更新；正在重啟舊的 PacketTunnelProvider session…"
            localManager.connection.stopVPNTunnel()
            await waitUntilStopped(localManager, timeoutSeconds: 5.0)
        }

        switch localManager.connection.status {
        case .connected:
            syncPublishedState()
            return
        case .connecting, .reasserting:
            break
        default:
            state = .connecting
            detail = "啟動內建 LocalDevVPN reflector：10.7.0.0 ⇄ 10.7.0.1"
            let options: [String: NSObject] = [
                deviceIPKey: deviceIP as NSString,
                fakeIPKey: fakeIP as NSString,
                subnetMaskKey: subnetMask as NSString,
            ]
            try localManager.connection.startVPNTunnel(options: options)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            syncPublishedState()
            if localManager.connection.status == .connected {
                detail = "內建 LocalDevVPN reflector 已連線 • device=10.7.0.0 • fake=10.7.0.1"
                return
            }
            if localManager.connection.status == .invalid {
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        syncPublishedState()
        throw TunnelError.connectTimeout(detail)
    }


    /// Force-kills the current NetworkExtension session and starts a fresh provider.
    /// Useful after installing a new IPA while the old provider was still connected.
    func restartFresh(timeoutSeconds: Double = 15.0) async throws {
        guard let embeddedID = embeddedTunnelBundleID() else {
            throw TunnelError.extensionMissing
        }
        providerBundleID = embeddedID

        let managers = try await loadManagers()
        if let existing = managers.first(where: { candidate in
            guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else { return false }
            return proto.providerBundleIdentifier == embeddedID
        }) {
            manager = existing
            if existing.connection.status != .disconnected && existing.connection.status != .invalid {
                state = .disconnecting
                detail = "正在強制重啟 Pikmin Pilot tunnel…"
                existing.connection.stopVPNTunnel()
                await waitUntilStopped(existing, timeoutSeconds: 5.0)
            }
        }

        try await ensureStarted(timeoutSeconds: timeoutSeconds)
    }

    func diagnostics(for error: Error) -> String {
        let ns = error as NSError
        var pieces = [
            "domain=\(ns.domain)",
            "code=\(ns.code)",
            "description=\(ns.localizedDescription)",
        ]
        if !ns.userInfo.isEmpty {
            let compact = ns.userInfo
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: "; ")
            pieces.append("userInfo={\(compact)}")
        }
        return pieces.joined(separator: " • ")
    }

    func isLikelyMissingNetworkExtensionEntitlement(_ error: Error) -> Bool {
        let ns = error as NSError
        let text = "\(ns.domain) \(ns.code) \(ns.localizedDescription)".lowercased()
        return (ns.domain == "NEConfigurationErrorDomain" && ns.code == 10)
            || (ns.domain == "NEVPNErrorDomain" && ns.code == 5)
            || text.contains("permission denied")
            || text.contains("not authorized")
    }

    func stop() {
        guard let manager else {
            state = .disconnected
            detail = "沒有 Pikmin Pilot tunnel 設定"
            return
        }
        manager.connection.stopVPNTunnel()
        state = .disconnecting
        detail = "正在停止內建 tunnel…"
    }

    private func makeProtocol(providerBundleID: String) -> NETunnelProviderProtocol {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = "Pikmin Pilot phone-local loopback"
        proto.providerConfiguration = [
            deviceIPKey: deviceIP,
            fakeIPKey: fakeIP,
            subnetMaskKey: subnetMask,
            reflectorRevisionKey: reflectorRevision,
        ]
        return proto
    }

    private func syncPublishedState() {
        guard let manager else { return }
        switch manager.connection.status {
        case .invalid:
            state = .error
            detail = "VPN configuration invalid"
        case .disconnected:
            state = .disconnected
            detail = "內建 tunnel 未連線"
        case .connecting:
            state = .connecting
            detail = "內建 tunnel 連線中…"
        case .connected:
            state = .connected
            detail = "內建 LocalDevVPN reflector 已連線 • target=10.7.0.1:49152"
        case .reasserting:
            state = .connecting
            detail = "內建 tunnel reasserting…"
        case .disconnecting:
            state = .disconnecting
            detail = "內建 tunnel 正在中斷…"
        @unknown default:
            state = .unknown
            detail = "未知 VPN 狀態"
        }
    }

    /// Do not assume the original com.example bundle ID survives sideload signing.
    /// Discover the actual signed .appex identifier at runtime.
    private func embeddedTunnelBundleID() -> String? {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: plugins,
                includingPropertiesForKeys: nil
              ) else {
            return nil
        }

        for url in entries where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let identifier = bundle.bundleIdentifier else { continue }
            if url.lastPathComponent.localizedCaseInsensitiveContains("Tunnel")
                || identifier.localizedCaseInsensitiveContains("Tunnel") {
                return identifier
            }
        }
        return nil
    }

    private func waitUntilStopped(_ manager: NETunnelProviderManager, timeoutSeconds: Double) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let status = manager.connection.status
            if status == .disconnected || status == .invalid {
                syncPublishedState()
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        syncPublishedState()
    }

    private func loadManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func load(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

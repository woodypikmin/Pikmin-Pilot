import Foundation
import Security
import UniformTypeIdentifiers

@MainActor
final class PairingRecordStore: ObservableObject {
    @Published private(set) var pairingURL: URL?
    @Published private(set) var status: String = "尚未匯入 Pairing Record"

    private let fileName = "rp_pairing_file.plist"
    private let embeddedResourceName = "PikminPilotEmbeddedRPPairing"
    private let keychainService = "com.woodypikmin.pikminpilot.rppairing"
    private let keychainAccount = "rp_pairing_file.plist"

    init() {
        bootstrapLocalCopy()
        refresh()
        if pairingURL != nil {
            _ = backupCurrentRecordToKeychain()
        }
    }

    var destinationURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName)
    }

    var embeddedURL: URL? {
        Bundle.main.url(forResource: embeddedResourceName, withExtension: "plist")
    }

    func refresh() {
        let url = destinationURL
        if FileManager.default.fileExists(atPath: url.path) {
            pairingURL = url
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                status = "Pairing Record 已就緒（\(size.intValue) bytes）"
            } else {
                status = "Pairing Record 已就緒"
            }
        } else {
            pairingURL = nil
            status = "尚未匯入 Pairing Record"
        }
    }

    /// Stage 11.6.1 one-tap bootstrap recovery order:
    /// 1. Existing app-container copy (normal updates preserve this)
    /// 2. Best-effort Keychain recovery copy
    /// 3. Optional per-device pairing record embedded by private CI
    /// 4. File importer fallback, initiated automatically by START PILOT
    @discardableResult
    func ensureAvailableFromRecoverySources() -> Bool {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            refresh()
            _ = backupCurrentRecordToKeychain()
            return true
        }

        if restoreFromKeychain() {
            return true
        }

        if restoreFromEmbeddedResource() {
            return true
        }

        refresh()
        return false
    }

    func importRecord(from sourceURL: URL) throws {
        let granted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if granted { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let data = try Data(contentsOf: sourceURL)
        guard !data.isEmpty else {
            throw NSError(
                domain: "PikminPilot.Pairing",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Pairing Record 是空檔案"]
            )
        }

        try writeLocalCopy(data)
        let backedUp = saveToKeychain(data)
        refresh()
        if backedUp {
            status += " • secure recovery ✓"
        }
    }

    /// Best effort only. The working copy remains the on-disk plist because
    /// idevice may update it after a successful RPPairing session.
    @discardableResult
    func backupCurrentRecordToKeychain() -> Bool {
        guard let data = try? Data(contentsOf: destinationURL), !data.isEmpty else {
            return false
        }
        return saveToKeychain(data)
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        deleteKeychainBackup()
        refresh()
    }

    /// Stage 11.6.1 diagnostic helper. Temporarily removes only the Documents
    /// working copy while intentionally leaving Keychain recovery untouched.
    /// If the probe crashes or is killed, the next launch can still recover the
    /// known-good record from Keychain.
    func suspendWorkingCopyForPairingProbe() throws -> Data? {
        let url = destinationURL
        let baseline: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            baseline = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
        } else {
            baseline = nil
        }
        refresh()
        return baseline
    }

    /// Restores the in-memory baseline after an unsuccessful pairing probe.
    /// Keychain recovery is preserved throughout the probe as a second safety net.
    func restoreWorkingCopyAfterPairingProbe(_ baseline: Data?) throws {
        guard let baseline, !baseline.isEmpty else {
            refresh()
            return
        }
        try writeLocalCopy(baseline)
        refresh()
        _ = backupCurrentRecordToKeychain()
    }

    private func bootstrapLocalCopy() {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else { return }
        if restoreFromKeychain() { return }
        _ = restoreFromEmbeddedResource()
    }

    @discardableResult
    private func restoreFromEmbeddedResource() -> Bool {
        guard !FileManager.default.fileExists(atPath: destinationURL.path),
              let embeddedURL,
              let data = try? Data(contentsOf: embeddedURL),
              !data.isEmpty else {
            return false
        }

        do {
            try writeLocalCopy(data)
            _ = saveToKeychain(data)
            refresh()
            status = "Pairing Record 已從此裝置專用 IPA 自動載入 ✅"
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func restoreFromKeychain() -> Bool {
        guard !FileManager.default.fileExists(atPath: destinationURL.path),
              let data = loadFromKeychain(),
              !data.isEmpty else {
            return false
        }

        do {
            try writeLocalCopy(data)
            refresh()
            status = "Pairing Record 已從 secure recovery 自動還原 ✅"
            return true
        } catch {
            return false
        }
    }

    private func writeLocalCopy(_ data: Data) throws {
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: destinationURL, options: [.atomic])
    }

    private func keychainBaseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
    }

    @discardableResult
    private func saveToKeychain(_ data: Data) -> Bool {
        var query = keychainBaseQuery()
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        query[kSecValueData] = data
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func loadFromKeychain() -> Data? {
        var query = keychainBaseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private func deleteKeychainBackup() {
        SecItemDelete(keychainBaseQuery() as CFDictionary)
    }
}

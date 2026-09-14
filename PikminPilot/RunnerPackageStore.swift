import Foundation

@MainActor
final class RunnerPackageStore: ObservableObject {
    enum Source: String {
        case embedded = "embedded"
        case importedOverride = "imported-override"
    }

    @Published private(set) var runnerURL: URL?
    @Published private(set) var source: Source?
    @Published private(set) var status = "找不到 Runner IPA"
    @Published private(set) var provisioningStatus = "Runner 簽章資訊尚未載入"
    @Published private(set) var embeddedExpirationDate: Date?

    private let importedFileName = "PikminPilotRunner-signed-override.ipa"
    private let embeddedResourceName = "PikminPilotEmbeddedRunner"
    private let embeddedResourceExtension = "ipa"
    private let metadataResourceName = "PikminPilotEmbeddedRunnerMetadata"

    init() {
        refresh()
    }

    var importedURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(importedFileName)
    }

    var embeddedURL: URL? {
        Bundle.main.url(forResource: embeddedResourceName, withExtension: embeddedResourceExtension)
    }

    var sourceLabel: String {
        switch source {
        case .embedded: return "embedded"
        case .importedOverride: return "imported override"
        case .none: return "none"
        }
    }

    var isEmbeddedRunnerExpired: Bool {
        guard let embeddedExpirationDate else { return false }
        return embeddedExpirationDate <= Date()
    }

    func refresh() {
        loadEmbeddedMetadata()

        // Development override wins so a refreshed/newly signed Runner can be
        // tested without rebuilding the host. Normal use stays on embedded.
        if FileManager.default.fileExists(atPath: importedURL.path) {
            runnerURL = importedURL
            source = .importedOverride
            status = sizeStatus(prefix: "Runner override 已就緒", url: importedURL)
            return
        }

        if let embedded = embeddedURL,
           FileManager.default.fileExists(atPath: embedded.path) {
            runnerURL = embedded
            source = .embedded
            status = sizeStatus(prefix: "內建 Signed Runner 已就緒", url: embedded)
            return
        }

        runnerURL = nil
        source = nil
        status = "內建 Runner 缺失（build/package error）"
    }

    func importIPA(from sourceURL: URL) throws {
        let granted = sourceURL.startAccessingSecurityScopedResource()
        defer { if granted { sourceURL.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: sourceURL)
        guard data.count > 4, data[0] == 0x50, data[1] == 0x4B else {
            throw NSError(
                domain: "PikminPilot.RunnerPackage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "這個檔案不是有效的 IPA/ZIP"]
            )
        }
        try data.write(to: importedURL, options: [.atomic])
        refresh()
    }

    func removeImportedOverride() throws {
        if FileManager.default.fileExists(atPath: importedURL.path) {
            try FileManager.default.removeItem(at: importedURL)
        }
        refresh()
    }

    private func loadEmbeddedMetadata() {
        guard let url = Bundle.main.url(forResource: metadataResourceName, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            provisioningStatus = "Runner 簽章資訊不可用"
            embeddedExpirationDate = nil
            return
        }

        let expiration = plist["ExpirationDate"] as? Date
        embeddedExpirationDate = expiration
        let team = plist["TeamIdentifier"] as? String ?? "?"

        guard let expiration else {
            provisioningStatus = "team=\(team) • expiration=unknown"
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let remaining = expiration.timeIntervalSinceNow
        if remaining <= 0 {
            provisioningStatus = "EXPIRED • \(formatter.string(from: expiration)) • team=\(team)"
        } else {
            let hours = Int(remaining / 3600)
            if hours >= 48 {
                provisioningStatus = "約 \(hours / 24) 天後到期 • \(formatter.string(from: expiration)) • team=\(team)"
            } else {
                provisioningStatus = "約 \(hours) 小時後到期 • \(formatter.string(from: expiration)) • team=\(team)"
            }
        }
    }

    private func sizeStatus(prefix: String, url: URL) -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return String(format: "%@（%.2f MB）", prefix, Double(size) / 1_048_576.0)
    }
}

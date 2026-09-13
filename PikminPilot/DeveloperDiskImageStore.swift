import Foundation

actor DeveloperDiskImageStore {
    struct Assets: Sendable {
        let imageURL: URL
        let buildManifestURL: URL
        let trustCacheURL: URL
        let buildID: String
        let sourceLabel: String
    }

    enum StoreError: LocalizedError {
        case invalidHTTP(URL, Int)
        case invalidManifest
        case unexpectedBuild(String?)

        var errorDescription: String? {
            switch self {
            case let .invalidHTTP(url, code):
                return "DDI download HTTP \(code) • \(url.lastPathComponent)"
            case .invalidManifest:
                return "DDI BuildManifest.plist is invalid"
            case let .unexpectedBuild(build):
                return "DDI build mismatch • got=\(build ?? "nil") expected=\(Self.expectedBuildID)"
            }
        }

        static let expectedBuildID = DeveloperDiskImageStore.expectedBuildID
    }

    // Pinned to the same current personalized DDI build expected by pymobiledevice3
    // at Stage 11.3.1 creation time. A tagged source avoids an in-place main-branch
    // image change while the three payloads are being downloaded.
    static let expectedBuildID = "27A5228h"
    private static let sourceRef = "v0.3.0"
    private static let base = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/\(sourceRef)/PersonalizedImages/Xcode_iOS_DDI_Personalized"

    private let fm = FileManager.default

    func ensureAssets() async throws -> Assets {
        let dir = try cacheDirectory()
        let image = dir.appendingPathComponent("Image.dmg")
        let manifest = dir.appendingPathComponent("BuildManifest.plist")
        let trust = dir.appendingPathComponent("Image.dmg.trustcache")

        if filesLookComplete(image: image, manifest: manifest, trust: trust),
           let build = try? buildID(at: manifest),
           build == Self.expectedBuildID {
            return Assets(
                imageURL: image,
                buildManifestURL: manifest,
                trustCacheURL: trust,
                buildID: build,
                sourceLabel: "cache"
            )
        }

        try? fm.removeItem(at: image)
        try? fm.removeItem(at: manifest)
        try? fm.removeItem(at: trust)

        let manifestRemote = try remoteURL("BuildManifest.plist")
        let manifestData = try await downloadData(manifestRemote)
        try manifestData.write(to: manifest, options: .atomic)
        let build = try buildID(at: manifest)
        guard build == Self.expectedBuildID else {
            throw StoreError.unexpectedBuild(build)
        }

        let trustRemote = try remoteURL("Image.dmg.trustcache")
        let trustData = try await downloadData(trustRemote)
        try trustData.write(to: trust, options: .atomic)

        let imageRemote = try remoteURL("Image.dmg")
        let (temporaryURL, response) = try await URLSession.shared.download(from: imageRemote)
        try validate(response: response, url: imageRemote)
        try? fm.removeItem(at: image)
        try fm.moveItem(at: temporaryURL, to: image)

        guard filesLookComplete(image: image, manifest: manifest, trust: trust) else {
            throw StoreError.invalidManifest
        }

        return Assets(
            imageURL: image,
            buildManifestURL: manifest,
            trustCacheURL: trust,
            buildID: build,
            sourceLabel: "download:\(Self.sourceRef)"
        )
    }

    private func cacheDirectory() throws -> URL {
        let root = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = root.appendingPathComponent("PikminPilot/DDI", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func filesLookComplete(image: URL, manifest: URL, trust: URL) -> Bool {
        func size(_ url: URL) -> Int64 {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        // Use only corruption/truncation guards, not a hard-coded exact DDI size.
        return size(image) > 1_000_000 && size(manifest) > 1_000 && size(trust) > 1_000
    }

    private func buildID(at manifest: URL) throws -> String {
        let data = try Data(contentsOf: manifest)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: Any],
              let build = dict["ProductBuildVersion"] as? String else {
            throw StoreError.invalidManifest
        }
        return build
    }

    private func remoteURL(_ name: String) throws -> URL {
        guard let url = URL(string: "\(Self.base)/\(name)") else {
            throw URLError(.badURL)
        }
        return url
    }

    private func downloadData(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, url: url)
        return data
    }

    private func validate(response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw StoreError.invalidHTTP(url, http.statusCode)
        }
    }
}

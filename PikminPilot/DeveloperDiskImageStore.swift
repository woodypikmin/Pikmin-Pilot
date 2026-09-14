import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor DeveloperDiskImageStore {
    struct Assets: Sendable {
        let imageURL: URL
        let buildManifestURL: URL
        let trustCacheURL: URL
        let buildID: String
        let sourceLabel: String
    }

    struct DownloadProgress: Sendable {
        let fileName: String
        let receivedBytes: Int64
        let totalBytes: Int64?
        let resumedFromBytes: Int64

        var percent: Int? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(100, max(0, Int((Double(receivedBytes) / Double(totalBytes)) * 100.0)))
        }

        var statusText: String {
            let received = Self.byteLabel(receivedBytes)
            if let totalBytes, totalBytes > 0 {
                let total = Self.byteLabel(totalBytes)
                let pct = percent ?? 0
                let resume = resumedFromBytes > 0 ? " • resumed" : ""
                return "STAGE 11.3.2 DDI ASSET • \(fileName) • \(pct)% • \(received) / \(total)\(resume)"
            }
            let resume = resumedFromBytes > 0 ? " • resumed" : ""
            return "STAGE 11.3.2 DDI ASSET • \(fileName) • \(received)\(resume)"
        }

        private static func byteLabel(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    enum StoreError: LocalizedError {
        case invalidHTTP(URL, Int)
        case invalidManifest
        case unexpectedBuild(String?)
        case downloadFailed(String, String)

        var errorDescription: String? {
            switch self {
            case let .invalidHTTP(url, code):
                return "DDI download HTTP \(code) • \(url.lastPathComponent)"
            case .invalidManifest:
                return "DDI BuildManifest.plist is invalid"
            case let .unexpectedBuild(build):
                return "DDI build mismatch • got=\(build ?? "nil") expected=\(Self.expectedBuildID)"
            case let .downloadFailed(name, reason):
                return "DDI download failed • \(name) • \(reason)"
            }
        }

        static let expectedBuildID = DeveloperDiskImageStore.expectedBuildID
    }

    static let expectedBuildID = "27A5228h"
    private static let sourceRef = "v0.3.0"
    private static let base = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/\(sourceRef)/PersonalizedImages/Xcode_iOS_DDI_Personalized"

    private let fm = FileManager.default

    func ensureAssets(
        progress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async throws -> Assets {
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

        // Manifest first: it is the authority for the pinned DDI build. Preserve .part
        // files so a large Image.dmg can continue after a timeout/network interruption.
        if !isPlausibleFile(manifest, minimumBytes: 1_000) || (try? buildID(at: manifest)) != Self.expectedBuildID {
            try? fm.removeItem(at: manifest)
            try? fm.removeItem(at: partURL(for: manifest))
            try await downloadFile(
                remote: try remoteURL("BuildManifest.plist"),
                destination: manifest,
                progress: progress
            )
        }

        let build = try buildID(at: manifest)
        guard build == Self.expectedBuildID else {
            throw StoreError.unexpectedBuild(build)
        }

        if !isPlausibleFile(trust, minimumBytes: 1_000) {
            try await downloadFile(
                remote: try remoteURL("Image.dmg.trustcache"),
                destination: trust,
                progress: progress
            )
        }

        if !isPlausibleFile(image, minimumBytes: 1_000_000) {
            try await downloadFile(
                remote: try remoteURL("Image.dmg"),
                destination: image,
                progress: progress
            )
        }

        guard filesLookComplete(image: image, manifest: manifest, trust: trust) else {
            throw StoreError.invalidManifest
        }

        return Assets(
            imageURL: image,
            buildManifestURL: manifest,
            trustCacheURL: trust,
            buildID: build,
            sourceLabel: "download/cache:\(Self.sourceRef)"
        )
    }

    private func downloadFile(
        remote: URL,
        destination: URL,
        progress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async throws {
        let part = partURL(for: destination)
        let existing = fileSize(part)

        await progress(DownloadProgress(
            fileName: destination.lastPathComponent,
            receivedBytes: existing,
            totalBytes: nil,
            resumedFromBytes: existing
        ))

        let config = URLSessionConfiguration.ephemeral
        // The Personalized Image is large. The default request/resource timeout is
        // inappropriate here; keep the transfer alive while data is flowing.
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 21_600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 1

        let delegate = StreamingDownloadDelegate(
            fileManager: fm,
            destinationURL: destination,
            partialURL: part,
            initialOffset: existing,
            progress: progress
        )
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
        }

        var request = URLRequest(url: remote)
        request.timeoutInterval = 600
        request.setValue("PikminPilot/11.3.2", forHTTPHeaderField: "User-Agent")
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        do {
            try await delegate.run(session: session, request: request)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.downloadFailed(destination.lastPathComponent, error.localizedDescription)
        }
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

    private func partURL(for finalURL: URL) -> URL {
        finalURL.appendingPathExtension("part")
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func isPlausibleFile(_ url: URL, minimumBytes: Int64) -> Bool {
        fileSize(url) > minimumBytes
    }

    private func filesLookComplete(image: URL, manifest: URL, trust: URL) -> Bool {
        isPlausibleFile(image, minimumBytes: 1_000_000)
            && isPlausibleFile(manifest, minimumBytes: 1_000)
            && isPlausibleFile(trust, minimumBytes: 1_000)
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
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let fileManager: FileManager
    private let destinationURL: URL
    private let partialURL: URL
    private let initialOffset: Int64
    private let progress: @MainActor @Sendable (DeveloperDiskImageStore.DownloadProgress) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var fileHandle: FileHandle?
    private var receivedBytes: Int64
    private var totalBytes: Int64?
    private var lastReportedBytes: Int64 = -1
    private var responseAccepted = false
    private var finished = false

    init(
        fileManager: FileManager,
        destinationURL: URL,
        partialURL: URL,
        initialOffset: Int64,
        progress: @escaping @MainActor @Sendable (DeveloperDiskImageStore.DownloadProgress) -> Void
    ) {
        self.fileManager = fileManager
        self.destinationURL = destinationURL
        self.partialURL = partialURL
        self.initialOffset = initialOffset
        self.progress = progress
        self.receivedBytes = initialOffset
    }

    func run(session: URLSession, request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let http = response as? HTTPURLResponse else {
                throw DeveloperDiskImageStore.StoreError.downloadFailed(destinationURL.lastPathComponent, "non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw DeveloperDiskImageStore.StoreError.invalidHTTP(dataTask.originalRequest?.url ?? destinationURL, http.statusCode)
            }

            let isResume = initialOffset > 0 && http.statusCode == 206
            if initialOffset > 0 && !isResume {
                // Server ignored Range. Restart this file safely rather than appending
                // a second full image to the partial file.
                try? fileManager.removeItem(at: partialURL)
                _ = fileManager.createFile(atPath: partialURL.path, contents: nil)
                receivedBytes = 0
            } else if !fileManager.fileExists(atPath: partialURL.path) {
                _ = fileManager.createFile(atPath: partialURL.path, contents: nil)
            }

            fileHandle = try FileHandle(forWritingTo: partialURL)
            if isResume {
                try fileHandle?.seekToEnd()
            } else {
                try fileHandle?.truncate(atOffset: 0)
            }

            if response.expectedContentLength > 0 {
                totalBytes = response.expectedContentLength + (isResume ? initialOffset : 0)
            } else {
                totalBytes = nil
            }
            responseAccepted = true
            emitProgress()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard responseAccepted else { return }
        do {
            try fileHandle?.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            emitProgress()
        } catch {
            dataTask.cancel()
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? fileHandle?.close()
        fileHandle = nil

        if let error {
            complete(.failure(error))
            return
        }
        guard responseAccepted else {
            complete(.failure(DeveloperDiskImageStore.StoreError.downloadFailed(
                destinationURL.lastPathComponent,
                "response was not accepted"
            )))
            return
        }

        do {
            try? fileManager.removeItem(at: destinationURL)
            try fileManager.moveItem(at: partialURL, to: destinationURL)
            emitProgress(forceComplete: true)
            complete(.success(()))
        } catch {
            complete(.failure(error))
        }
    }

    private func emitProgress(forceComplete: Bool = false) {
        // Avoid flooding MainActor with tens of thousands of tiny network chunks.
        // Four MiB still gives smooth enough progress for the large DDI image.
        if !forceComplete, lastReportedBytes >= 0, receivedBytes - lastReportedBytes < 4 * 1024 * 1024 {
            return
        }
        lastReportedBytes = receivedBytes
        let total = forceComplete ? (totalBytes ?? receivedBytes) : totalBytes
        let snapshot = DeveloperDiskImageStore.DownloadProgress(
            fileName: destinationURL.lastPathComponent,
            receivedBytes: receivedBytes,
            totalBytes: total,
            resumedFromBytes: initialOffset
        )
        Task { @MainActor [progress] in
            progress(snapshot)
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success:
            continuation?.resume(returning: ())
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }
}

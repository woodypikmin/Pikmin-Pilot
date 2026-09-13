
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PairingRecordStore: ObservableObject {
    @Published private(set) var pairingURL: URL?
    @Published private(set) var status: String = "尚未匯入 Pairing Record"

    private let fileName = "rp_pairing_file.plist"

    init() {
        refresh()
    }

    var destinationURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(fileName)
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

        try data.write(to: destinationURL, options: [.atomic])
        refresh()
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        refresh()
    }
}

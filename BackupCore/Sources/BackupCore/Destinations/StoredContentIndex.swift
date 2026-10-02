import Foundation

/// Content already stored in the copies of one source: where a file can be cloned from instead of being written again.
struct StoredContentIndex {
    private struct Stored {
        let url: URL
        let file: SnapshotFile
    }

    private var bySize: [Int64: [Stored]] = [:]
    private var byHash: [String: [Stored]] = [:]

    static let empty = StoredContentIndex()

    /// `snapshots` are the written copies, newest first: their files are preferred as originals.
    init(snapshots: [(directory: URL, manifest: SnapshotManifest)] = []) {
        for snapshot in snapshots {
            for file in snapshot.manifest.files ?? [] {
                add(snapshot.directory.appendingPathComponent(file.path), file)
            }
        }
    }

    func hasContent(ofSize size: Int64) -> Bool {
        bySize[size] != nil
    }

    /// A file with this content that nobody has changed since it was written to the copy. Its size is checked against
    /// the file it stands in for as well: a manifest written by an earlier version can describe a file that was emptied.
    func original(sha256: String, size: Int64) -> URL? {
        byHash[sha256]?.first { $0.file.size == size && isUntouched($0) }?.url
    }

    mutating func add(_ url: URL, _ file: SnapshotFile) {
        let stored = Stored(url: url, file: file)
        bySize[file.size, default: []].append(stored)
        byHash[file.sha256, default: []].append(stored)
    }

    private func isUntouched(_ stored: Stored) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: stored.url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == stored.file.size,
              let modified = attributes[.modificationDate] as? Date else { return false }
        return modified.timeIntervalSince1970.rounded(.down) == stored.file.modified.timeIntervalSince1970.rounded(.down)
    }
}

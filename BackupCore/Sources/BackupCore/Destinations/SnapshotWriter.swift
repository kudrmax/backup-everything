import Foundation

/// What a copy folder holds, read from the finished copy itself rather than from what was meant to be written.
struct SnapshotContents {
    /// The regular files with the size, hash and date of what lies in the copy.
    var files: [SnapshotFile] = []
    /// Files and links in the copy.
    var itemCount = 0

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }
}

/// Writes a payload into a copy folder: the copy is made in full, its contents are read back for the manifest, and then it
/// is checked against the listing, so nothing that left the copy before the manifest was made passes unnoticed; when
/// wanted, files unchanged since the previous copy are then made to share its data.
struct SnapshotWriter {
    private let savings: SpaceSaving
    private let afterEachItem: (String) -> Void
    private let beforeReadingBack: () -> Void
    private let copier = PayloadCopier()
    private let walker = PayloadWalker()
    private let hash = ContentHash()

    /// `afterEachItem` learns the path of each file and link right after it is written, `beforeReadingBack` right before the
    /// copy is read back for its manifest (tests use them to meddle with the copy).
    init(cloning: any FileCloning, afterEachItem: @escaping (String) -> Void = { _ in }, beforeReadingBack: @escaping () -> Void = {}) {
        savings = SpaceSaving(cloning: cloning)
        self.afterEachItem = afterEachItem
        self.beforeReadingBack = beforeReadingBack
    }

    /// `previous`: the newest finished copy of the source here, whose unchanged files the new one shares.
    func write(_ listing: PayloadListing, into snapshotDirectory: URL, sharingWith previous: StoredCopy?) throws -> SnapshotContents {
        try copier.copy(listing, into: snapshotDirectory.path, afterEachItem: afterEachItem)
        beforeReadingBack()
        let contents = try contents(of: snapshotDirectory)
        try WrittenCopy(listing: listing).check(in: snapshotDirectory.path)
        if let previous { try savings.share(contents.files, in: snapshotDirectory, with: previous) }
        return contents
    }

    private func contents(of snapshotDirectory: URL) throws -> SnapshotContents {
        let copy = Payload(root: snapshotDirectory, excludedAtTop: SnapshotManifest.serviceFileNames, collectedAt: Date())
        var contents = SnapshotContents()
        for entry in try walker.entries(of: copy) where entry.kind != .directory {
            contents.itemCount += 1
            guard entry.kind == .file else { continue }
            do {
                let modified = try FileManager.default.attributesOfItem(atPath: entry.url.path)[.modificationDate] as? Date
                contents.files.append(SnapshotFile(
                    path: entry.relativePath,
                    size: entry.size,
                    sha256: try hash.sha256(of: entry.url),
                    modified: modified ?? Date(timeIntervalSince1970: 0)
                ))
            } catch {
                throw DestinationError.unreadableInCopy(entry.url.path, reason: error.localizedDescription)
            }
        }
        return contents
    }
}

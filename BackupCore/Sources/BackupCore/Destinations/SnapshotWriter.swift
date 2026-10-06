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

/// Writes a payload into a copy folder: the copy is made in full and checked against the listing; then its contents are
/// read back for the manifest, and, when wanted, files unchanged since the previous copy are made to share its data.
struct SnapshotWriter {
    private let savings: SpaceSaving
    private let afterEachItem: (String) -> Void
    private let copier = PayloadCopier()
    private let walker = PayloadWalker()
    private let hash = ContentHash()

    /// `afterEachItem` learns the path of each file and link right after it is written (tests use it to meddle with the copy).
    init(cloning: any FileCloning, afterEachItem: @escaping (String) -> Void = { _ in }) {
        savings = SpaceSaving(cloning: cloning)
        self.afterEachItem = afterEachItem
    }

    /// `previous`: the newest finished copy of the source here, whose unchanged files the new one shares.
    func write(_ listing: PayloadListing, into snapshotDirectory: URL, sharingWith previous: StoredCopy?) throws -> SnapshotContents {
        try copier.copy(listing, into: snapshotDirectory.path, afterEachItem: afterEachItem)
        try WrittenCopy(listing: listing).check(in: snapshotDirectory.path)
        let contents = try contents(of: snapshotDirectory)
        if let previous { savings.share(contents.files, in: snapshotDirectory, with: previous) }
        return contents
    }

    private func contents(of snapshotDirectory: URL) throws -> SnapshotContents {
        let copy = Payload(root: snapshotDirectory, excludedAtTop: SnapshotManifest.serviceFileNames, collectedAt: Date())
        var contents = SnapshotContents()
        for entry in try walker.entries(of: copy) where entry.kind != .directory {
            contents.itemCount += 1
            guard entry.kind == .file else { continue }
            let modified = try FileManager.default.attributesOfItem(atPath: entry.url.path)[.modificationDate] as? Date
            contents.files.append(SnapshotFile(
                path: entry.relativePath,
                size: entry.size,
                sha256: try hash.sha256(of: entry.url),
                modified: modified ?? Date(timeIntervalSince1970: 0)
            ))
        }
        return contents
    }
}

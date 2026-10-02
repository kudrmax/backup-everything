import Foundation

/// What was written into a copy folder.
struct SnapshotContents {
    /// The written regular files; each size and hash describes what actually lies in the copy.
    var files: [SnapshotFile] = []
    /// Files and links that are in the copy.
    var itemCount = 0
    /// Items of the listing that vanished from the source before they were copied.
    var vanished: [PayloadEntry] = []
    /// Files whose content an earlier copy already had but which were copied in full, with the reason.
    var cloneFailures: [String: String] = [:]

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }
}

/// Writes payload files into a copy folder. Content already present in `index` is cloned, the rest is copied.
/// Every written file is checked to be as long as its original.
struct SnapshotWriter {
    private let cloning: any FileCloning
    private let hash = ContentHash()
    private let files = ExactNameFiles()
    private let metadata = FileMetadata()
    private let sizes = LogicalSize()
    private let copier = PayloadCopier()
    private let removal = FolderRemoval()
    private let fileManager = FileManager.default

    init(cloning: any FileCloning) {
        self.cloning = cloning
    }

    func write(_ listing: PayloadListing, into snapshotDirectory: URL, reusing index: StoredContentIndex) throws -> SnapshotContents {
        var index = index
        var contents = SnapshotContents()
        let vanished = try copier.copy(listing, into: snapshotDirectory.path) { entry, target in
            let file = try cloneIfStored(entry, to: target, index: index, failures: &contents.cloneFailures) ?? copy(entry, to: target)
            index.add(URL(fileURLWithPath: target), file)
            contents.files.append(file)
        }
        let left = Set(vanished.map(\.relativePath))
        contents.vanished = vanished
        contents.itemCount = listing.entries.filter { $0.kind != .directory && !left.contains($0.relativePath) }.count
        return contents
    }

    /// The clone carries the data of the stored file and takes the metadata of the source file. A clone that cannot be
    /// finished or does not come out as long as the source is deleted, and the file is copied instead.
    private func cloneIfStored(_ entry: PayloadEntry, to target: String, index: StoredContentIndex, failures: inout [String: String]) throws -> SnapshotFile? {
        guard index.hasContent(ofSize: entry.size) else { return nil }
        let digest = try hash.sha256(of: entry.url)
        let size = try sizes.of(entry.url.path)
        guard let original = index.original(sha256: digest, size: size) else { return nil }
        do {
            try cloning.clone(original, to: target)
            try metadata.apply(from: entry.url.path, to: target)
            let cloned = try sizes.of(target)
            guard cloned == size else { throw DestinationError.copyMismatch(path: entry.url.path, expected: size, actual: cloned) }
        } catch {
            failures[entry.relativePath] = error.localizedDescription
            if fileManager.fileExists(atPath: target) { try removal.remove(target) }
            return nil
        }
        return try record(entry, at: target, sha256: digest)
    }

    private func copy(_ entry: PayloadEntry, to target: String) throws -> SnapshotFile {
        let sizeBefore = try sizes.of(entry.url.path)
        try files.copy(entry.url.path, to: target)
        try metadata.copyFlags(from: entry.url.path, to: target)
        try sizes.checkCopy(target, of: entry.url.path, sizeBefore: sizeBefore)
        return try record(entry, at: target, sha256: hash.sha256(of: URL(fileURLWithPath: target)))
    }

    private func record(_ entry: PayloadEntry, at target: String, sha256: String) throws -> SnapshotFile {
        let attributes = try fileManager.attributesOfItem(atPath: target)
        return SnapshotFile(
            path: entry.relativePath,
            size: try sizes.of(target),
            sha256: sha256,
            modified: attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        )
    }
}

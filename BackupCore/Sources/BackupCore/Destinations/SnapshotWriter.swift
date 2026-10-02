import Foundation

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

    /// Returns the written files; each size and hash describes what actually lies in the copy.
    func write(_ entries: [PayloadEntry], into snapshotDirectory: URL, reusing index: StoredContentIndex) throws -> [SnapshotFile] {
        var index = index
        var written: [SnapshotFile] = []
        try copier.copy(entries, into: snapshotDirectory.path) { entry, target in
            let file = try cloneIfStored(entry, to: target, index: index) ?? copy(entry, to: target)
            index.add(URL(fileURLWithPath: target), file)
            written.append(file)
        }
        return written
    }

    /// The clone carries the data of the stored file and takes the metadata of the source file. A clone that cannot be
    /// finished or does not come out as long as the source is deleted, and the file is copied instead.
    private func cloneIfStored(_ entry: PayloadEntry, to target: String, index: StoredContentIndex) throws -> SnapshotFile? {
        guard index.hasContent(ofSize: entry.size) else { return nil }
        let digest = try hash.sha256(of: entry.url)
        let size = try sizes.of(entry.url.path)
        guard let original = index.original(sha256: digest, size: size) else { return nil }
        let isWhole: Bool
        do {
            try cloning.clone(original, to: target)
            try metadata.apply(from: entry.url.path, to: target)
            isWhole = try sizes.of(target) == size
        } catch {
            isWhole = false
        }
        guard isWhole else {
            if fileManager.fileExists(atPath: target) { try removal.remove(target) }
            return nil
        }
        return try record(entry, at: target, sha256: digest)
    }

    private func copy(_ entry: PayloadEntry, to target: String) throws -> SnapshotFile {
        let sizeBefore = try sizes.of(entry.url.path)
        try files.copy(entry.url.path, to: target)
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

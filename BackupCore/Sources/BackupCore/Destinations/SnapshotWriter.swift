import Foundation

/// Writes payload files into a copy folder. Content already present in `index` is cloned, the rest is copied.
struct SnapshotWriter {
    private let cloning: any FileCloning
    private let hash = ContentHash()
    private let files = ExactNameFiles()
    private let fileManager = FileManager.default

    init(cloning: any FileCloning) {
        self.cloning = cloning
    }

    /// Returns the written files; each hash is computed from what actually lies in the copy.
    func write(_ entries: [PayloadEntry], into snapshotDirectory: URL, reusing index: StoredContentIndex) throws -> [SnapshotFile] {
        var index = index
        var written: [SnapshotFile] = []
        let base = snapshotDirectory.path
        for entry in entries {
            let target = base + "/" + entry.relativePath
            let parent = (entry.relativePath as NSString).deletingLastPathComponent
            switch entry.kind {
            case .directory:
                try files.createDirectories(entry.relativePath, in: base)
            case .symlink:
                try files.createDirectories(parent, in: base)
                try files.copy(entry.url.path, to: target)
            case .file:
                try files.createDirectories(parent, in: base)
                let file = try cloneIfStored(entry, to: target, index: index) ?? copy(entry, to: target)
                index.add(URL(fileURLWithPath: target), file)
                written.append(file)
            }
        }
        return written
    }

    private func cloneIfStored(_ entry: PayloadEntry, to target: String, index: StoredContentIndex) throws -> SnapshotFile? {
        guard index.hasContent(ofSize: entry.size) else { return nil }
        let digest = try hash.sha256(of: entry.url)
        guard let original = index.original(sha256: digest) else { return nil }
        do {
            try cloning.clone(original, to: target)
            try fileManager.setAttributes(metadata(of: entry.url), ofItemAtPath: target)
        } catch {
            try? fileManager.removeItem(atPath: target)
            return nil
        }
        return try record(entry, at: target, sha256: digest)
    }

    private func copy(_ entry: PayloadEntry, to target: String) throws -> SnapshotFile {
        try files.copy(entry.url.path, to: target)
        return try record(entry, at: target, sha256: hash.sha256(of: URL(fileURLWithPath: target)))
    }

    private func record(_ entry: PayloadEntry, at target: String, sha256: String) throws -> SnapshotFile {
        let attributes = try fileManager.attributesOfItem(atPath: target)
        return SnapshotFile(
            path: entry.relativePath,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            sha256: sha256,
            modified: attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        )
    }

    private func metadata(of url: URL) throws -> [FileAttributeKey: Any] {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes.filter { [.modificationDate, .creationDate, .posixPermissions].contains($0.key) }
    }
}

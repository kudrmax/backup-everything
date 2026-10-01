import Foundation

/// Writes payload files into a copy folder. Content already present in `index` is cloned, the rest is copied.
struct SnapshotWriter {
    private let cloning: any FileCloning
    private let hash = ContentHash()
    private let fileManager = FileManager.default

    init(cloning: any FileCloning) {
        self.cloning = cloning
    }

    /// Returns the written files; each hash is computed from what actually lies in the copy.
    func write(_ entries: [PayloadEntry], into snapshotDirectory: URL, reusing index: StoredContentIndex) throws -> [SnapshotFile] {
        var index = index
        var files: [SnapshotFile] = []
        for entry in entries {
            let target = snapshotDirectory.appendingPathComponent(entry.relativePath)
            switch entry.kind {
            case .directory:
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            case .symlink:
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: entry.url, to: target)
            case .file:
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let file = try cloneIfStored(entry, to: target, index: index) ?? copy(entry, to: target)
                index.add(target, file)
                files.append(file)
            }
        }
        return files
    }

    private func cloneIfStored(_ entry: PayloadEntry, to target: URL, index: StoredContentIndex) throws -> SnapshotFile? {
        guard index.hasContent(ofSize: entry.size) else { return nil }
        let digest = try hash.sha256(of: entry.url)
        guard let original = index.original(sha256: digest) else { return nil }
        do {
            try cloning.clone(original, to: target)
            try fileManager.setAttributes(metadata(of: entry.url), ofItemAtPath: target.path)
        } catch {
            try? fileManager.removeItem(at: target)
            return nil
        }
        return try record(entry, at: target, sha256: digest)
    }

    private func copy(_ entry: PayloadEntry, to target: URL) throws -> SnapshotFile {
        try fileManager.copyItem(at: entry.url, to: target)
        return try record(entry, at: target, sha256: hash.sha256(of: target))
    }

    private func record(_ entry: PayloadEntry, at target: URL, sha256: String) throws -> SnapshotFile {
        let attributes = try fileManager.attributesOfItem(atPath: target.path)
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

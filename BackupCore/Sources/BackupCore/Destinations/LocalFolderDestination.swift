import Foundation

public struct LocalFolderDestination: DestinationStore {
    private let root: URL
    private let naming: SnapshotNaming
    private let walker = PayloadWalker()

    public init(root: URL, naming: SnapshotNaming) {
        self.root = root
        self.naming = naming
    }

    public func isAvailable() async -> Bool {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isWritableFile(atPath: root.path)
    }

    public func listSnapshots(sourceSlug: String) async throws -> [Snapshot] {
        snapshotDirectories(sourceSlug).filter { hasManifest($0.url) }.map(\.snapshot)
    }

    public func removeIncomplete(sourceSlug: String) async throws {
        for directory in snapshotDirectories(sourceSlug) where !hasManifest(directory.url) {
            try FileManager.default.removeItem(at: directory.url)
        }
    }

    public func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String) async throws {
        guard await isAvailable() else { throw DestinationError.unavailable }
        let fileManager = FileManager.default
        let sourceDirectory = directory(sourceSlug)
        let snapshotDirectory = sourceDirectory.appendingPathComponent(snapshotName, isDirectory: true)
        do {
            if !fileManager.fileExists(atPath: sourceDirectory.path) {
                try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
            }
            try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false)
            for entry in try walker.entries(of: payload) {
                let target = snapshotDirectory.appendingPathComponent(entry.relativePath)
                if entry.kind == .directory {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: entry.url, to: target)
                }
            }
            let manifestURL = snapshotDirectory.appendingPathComponent(SnapshotManifest.fileName)
            try JSONCoding.encoder().encode(manifest).write(to: manifestURL, options: .atomic)
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw DestinationError.outOfSpace
        }
    }

    public func delete(_ snapshot: Snapshot, sourceSlug: String) async throws {
        guard naming.date(from: snapshot.name) != nil else { return }
        try FileManager.default.removeItem(at: directory(sourceSlug).appendingPathComponent(snapshot.name, isDirectory: true))
    }

    private func directory(_ sourceSlug: String) -> URL {
        root.appendingPathComponent(sourceSlug, isDirectory: true)
    }

    private func hasManifest(_ snapshotDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: snapshotDirectory.appendingPathComponent(SnapshotManifest.fileName).path)
    }

    private func snapshotDirectories(_ sourceSlug: String) -> [(url: URL, snapshot: Snapshot)] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory(sourceSlug),
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return items.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let snapshot = naming.snapshot(named: url.lastPathComponent) else { return nil }
            return (url, snapshot)
        }
    }
}

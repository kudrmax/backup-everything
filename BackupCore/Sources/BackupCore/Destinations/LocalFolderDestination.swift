import Foundation

public struct LocalFolderDestination: DestinationStore {
    private let root: URL
    private let naming: SnapshotNaming
    private let cloning: any FileCloning
    private let trash: ManualExportInbox.Trash
    private let walker = PayloadWalker()

    public init(
        root: URL,
        naming: SnapshotNaming,
        cloning: any FileCloning = APFSCloning(),
        trash: @escaping ManualExportInbox.Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.root = root
        self.naming = naming
        self.cloning = cloning
        self.trash = trash
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
        for directory in snapshotDirectories(sourceSlug) where isUnfinished(directory.url) {
            try trash(directory.url)
        }
    }

    public func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String, reusingStoredFiles: Bool) async throws {
        guard await isAvailable() else { throw DestinationError.unavailable }
        let fileManager = FileManager.default
        let sourceDirectory = directory(sourceSlug)
        let snapshotDirectory = sourceDirectory.appendingPathComponent(snapshotName, isDirectory: true)
        do {
            if !fileManager.fileExists(atPath: sourceDirectory.path) {
                try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
            }
            if fileManager.fileExists(atPath: snapshotDirectory.path) {
                guard isUnfinished(snapshotDirectory) else { throw DestinationError.folderInTheWay(snapshotDirectory.path) }
                try trash(snapshotDirectory)
            }
            let sharesData = reusingStoredFiles && cloning.isSupported(at: root)
            let index = sharesData ? StoredContentIndex(snapshots: storedManifests(sourceSlug)) : .empty
            try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false)
            let markerURL = snapshotDirectory.appendingPathComponent(SnapshotManifest.unfinishedMarker)
            try Data(SnapshotManifest.unfinishedNote.utf8).write(to: markerURL)
            var manifest = manifest
            manifest.files = try SnapshotWriter(cloning: cloning)
                .write(try walker.entries(of: payload), into: snapshotDirectory, reusing: index)
            manifest.sharesData = sharesData
            let manifestURL = snapshotDirectory.appendingPathComponent(SnapshotManifest.fileName)
            try JSONCoding.encoder(pretty: false).encode(manifest).write(to: manifestURL, options: .atomic)
            try fileManager.removeItem(at: markerURL)
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw DestinationError.outOfSpace
        } catch let error as POSIXError where error.code == .ENOSPC {
            throw DestinationError.outOfSpace
        }
    }

    public func delete(_ snapshot: Snapshot, sourceSlug: String) async throws {
        guard naming.date(from: snapshot.name) != nil else { return }
        try FileManager.default.removeItem(at: directory(sourceSlug).appendingPathComponent(snapshot.name, isDirectory: true))
    }

    public func materialize(_ snapshot: Snapshot, sourceSlug: String, scratch: URL) async throws -> URL {
        guard await isAvailable() else { throw DestinationError.unavailable }
        return directory(sourceSlug).appendingPathComponent(snapshot.name, isDirectory: true)
    }

    public func usedBytes() async throws -> Int64 {
        guard await isAvailable() else { throw DestinationError.unavailable }
        return try DestinationUsage().bytes(under: root)
    }

    public func canShareUnchangedFiles() async -> Bool? {
        guard await isAvailable() else { return nil }
        return cloning.isSupported(at: root)
    }

    private func directory(_ sourceSlug: String) -> URL {
        root.appendingPathComponent(sourceSlug, isDirectory: true)
    }

    /// Written copies of the source, newest first.
    private func storedManifests(_ sourceSlug: String) -> [(directory: URL, manifest: SnapshotManifest)] {
        snapshotDirectories(sourceSlug)
            .sorted { $0.snapshot.date > $1.snapshot.date }
            .compactMap { directory in
                let url = directory.url.appendingPathComponent(SnapshotManifest.fileName)
                guard let data = try? Data(contentsOf: url),
                      let manifest = try? JSONCoding.decoder().decode(SnapshotManifest.self, from: data) else { return nil }
                return (directory.url, manifest)
            }
    }

    private func isUnfinished(_ snapshotDirectory: URL) -> Bool {
        !hasManifest(snapshotDirectory)
            && FileManager.default.fileExists(atPath: snapshotDirectory.appendingPathComponent(SnapshotManifest.unfinishedMarker).path)
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

import Foundation

public struct LocalFolderDestination: DestinationStore {
    private let root: URL
    private let naming: SnapshotNaming
    private let cloning: any FileCloning
    private let volumes: VolumeMounts
    private let trash: ManualExportInbox.Trash
    private let walker = PayloadWalker()
    private let removal = FolderRemoval()
    /// A copy being deleted is first renamed so: if deleting stops halfway, the rest is never taken for a copy.
    private static let removalSuffix = ".deleting"

    public init(
        root: URL,
        naming: SnapshotNaming,
        cloning: any FileCloning = APFSCloning(),
        volumes: VolumeMounts = VolumeMounts(),
        trash: @escaping ManualExportInbox.Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.root = root
        self.naming = naming
        self.cloning = cloning
        self.volumes = volumes
        self.trash = trash
    }

    public func isAvailable() async -> Bool {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isWritableFile(atPath: root.path)
            && volumes.isOnMountedVolume(root)
    }

    public func listSnapshots(sourceSlug: String) async throws -> [Snapshot] {
        try snapshotDirectories(sourceSlug).filter { hasManifest($0.url) }.map(\.snapshot)
    }

    public func owners(sourceSlug: String) async throws -> [String: UUID] {
        var owners: [String: UUID] = [:]
        for directory in try snapshotDirectories(sourceSlug) {
            owners[directory.snapshot.name] = SnapshotManifest.owner(of: directory.url)
        }
        return owners
    }

    /// Also finishes deleting copies whose deletion stopped halfway; what still cannot be deleted is reported after the rest is done.
    public func removeIncomplete(sourceSlug: String) async throws {
        for directory in try snapshotDirectories(sourceSlug) where isUnfinished(directory.url) {
            try trash(directory.url)
        }
        var problems: [String] = []
        for leftover in try interruptedRemovals(sourceSlug) {
            do {
                try removal.remove(leftover.path)
            } catch {
                problems.append("“\(leftover.path)”: \(error.localizedDescription)")
            }
        }
        if !problems.isEmpty { throw DestinationError.unfinishedDeletions(problems) }
    }

    @discardableResult
    public func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String, reusingStoredFiles: Bool) async throws -> PayloadStats? {
        guard await isAvailable() else { throw DestinationError.unavailable }
        let fileManager = FileManager.default
        let sourceDirectory = try directory(sourceSlug)
        let snapshotDirectory = sourceDirectory.appendingPathComponent(snapshotName, isDirectory: true)
        let listing = try walker.listing(of: payload)
        try SnapshotManifest.checkTopLevelNames(of: listing.entries)
        do {
            if !fileManager.fileExists(atPath: sourceDirectory.path) {
                try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
            }
            if fileManager.fileExists(atPath: snapshotDirectory.path) {
                guard isUnfinished(snapshotDirectory) else { throw DestinationError.folderInTheWay(snapshotDirectory.path) }
                try trash(snapshotDirectory)
            }
            let sharesData = reusingStoredFiles && cloning.isSupported(at: root)
            let index = sharesData ? StoredContentIndex(snapshots: try storedManifests(sourceSlug)) : .empty
            try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false)
            let markerURL = snapshotDirectory.appendingPathComponent(SnapshotManifest.unfinishedMarker)
            try Data(SnapshotManifest.unfinishedNote.utf8).write(to: markerURL)
            let contents = try SnapshotWriter(cloning: cloning).write(listing, into: snapshotDirectory, reusing: index)
            guard contents.itemCount > 0 else { throw SourceError.vanishedWhileCopied }
            var manifest = manifest
            manifest.fileCount = contents.itemCount
            manifest.totalBytes = contents.totalBytes
            manifest.files = contents.files
            manifest.sharesData = sharesData
            let manifestURL = snapshotDirectory.appendingPathComponent(SnapshotManifest.fileName)
            try JSONCoding.encoder(pretty: false).encode(manifest).write(to: manifestURL, options: .atomic)
            try fileManager.removeItem(at: markerURL)
            return PayloadStats(fileCount: contents.itemCount, totalBytes: contents.totalBytes)
        } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
            throw DestinationError.outOfSpace
        } catch let error as POSIXError where error.code == .ENOSPC {
            throw DestinationError.outOfSpace
        }
    }

    public func delete(_ snapshot: Snapshot, sourceSlug: String) async throws {
        guard naming.date(from: snapshot.name) != nil else { return }
        let folder = try directory(sourceSlug).appendingPathComponent(snapshot.name, isDirectory: true).path
        let doomed = folder + Self.removalSuffix
        if FileManager.default.fileExists(atPath: doomed) { try removal.remove(doomed) }
        try removal.unlock(folder)
        try FileManager.default.moveItem(atPath: folder, toPath: doomed)
        try removal.remove(doomed)
    }

    public func materialize(_ snapshot: Snapshot, sourceSlug: String, scratch: URL) async throws -> URL {
        guard await isAvailable() else { throw DestinationError.unavailable }
        return try directory(sourceSlug).appendingPathComponent(snapshot.name, isDirectory: true)
    }

    public func usedBytes() async throws -> Int64 {
        guard await isAvailable() else { throw DestinationError.unavailable }
        return try DestinationUsage().bytes(under: root)
    }

    public func canShareUnchangedFiles() async -> Bool? {
        guard await isAvailable() else { return nil }
        return cloning.isSupported(at: root)
    }

    private func directory(_ sourceSlug: String) throws -> URL {
        root.appendingPathComponent(try Slug.folderName(sourceSlug), isDirectory: true)
    }

    /// Written copies of the source, newest first.
    private func storedManifests(_ sourceSlug: String) throws -> [(directory: URL, manifest: SnapshotManifest)] {
        try snapshotDirectories(sourceSlug)
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

    private func snapshotDirectories(_ sourceSlug: String) throws -> [(url: URL, snapshot: Snapshot)] {
        try items(sourceSlug).compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let snapshot = naming.snapshot(named: url.lastPathComponent) else { return nil }
            return (url, snapshot)
        }
    }

    private func interruptedRemovals(_ sourceSlug: String) throws -> [URL] {
        try items(sourceSlug).filter { url in
            let name = url.lastPathComponent
            return name.hasSuffix(Self.removalSuffix) && naming.date(from: String(name.dropLast(Self.removalSuffix.count))) != nil
        }
    }

    /// What lies in the folder of the source; nothing when there is no such folder yet. A folder that cannot be read is an error:
    /// copies that could not be listed are not missing copies.
    private func items(_ sourceSlug: String) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory(sourceSlug), includingPropertiesForKeys: [.isDirectoryKey])
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }
}

import Foundation

public struct LocalFolderDestination: DestinationStore {
    private let root: URL
    private let naming: SnapshotNaming
    private let cloning: any FileCloning
    private let volumes: VolumeMounts
    private let expectedDisk: DiskIdentity?
    private let disks: any DiskLocating
    /// Removes an unfinished attempt; by default for good, so its space is free again (the Trash of an external disk is on
    /// that disk). Tests replace it to watch or fail it.
    private let discardAttempt: (@Sendable (URL) throws -> Void)?
    private let walker = PayloadWalker()
    private let removal = FolderRemoval()
    /// A copy being deleted is first renamed so: if deleting stops halfway, the rest is never taken for a copy.
    private static let removalSuffix = ".deleting"
    /// Learns the path of the unfinished mark and of each file and link right after it is written into a copy; tests use it
    /// to meddle with the source or the copy.
    var afterWritingItem: @Sendable (String) -> Void = { _ in }

    public init(
        root: URL,
        naming: SnapshotNaming,
        cloning: any FileCloning = APFSCloning(),
        volumes: VolumeMounts = VolumeMounts(),
        expectedDisk: DiskIdentity? = nil,
        disks: (any DiskLocating)? = nil,
        discardAttempt: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.root = root
        self.naming = naming
        self.cloning = cloning
        self.volumes = volumes
        self.expectedDisk = expectedDisk
        self.disks = disks ?? SystemDisks(mounts: volumes)
        self.discardAttempt = discardAttempt
    }

    public func isAvailable() async -> Bool {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isWritableFile(atPath: root.path)
            && volumes.isOnMountedVolume(root)
            && currentDiskCheck().allowsAccess
    }

    public func diskCheck() async -> DiskCheck {
        currentDiskCheck()
    }

    public func isVerifiable() async -> Bool {
        expectedDisk != nil || disks.location(of: root) == .systemDisk
    }

    public func listSnapshots(sourceSlug: String) async throws -> [Snapshot] {
        try requireOwnDisk()
        return try snapshotDirectories(sourceSlug).filter { hasManifest($0.url) }.map(\.snapshot)
    }

    public func owners(sourceSlug: String) async throws -> [String: UUID] {
        try requireOwnDisk()
        var owners: [String: UUID] = [:]
        for directory in try snapshotDirectories(sourceSlug) {
            owners[directory.snapshot.name] = SnapshotManifest.owner(of: directory.url)
        }
        return owners
    }

    /// Also finishes deleting copies whose deletion stopped halfway; what still cannot be deleted is reported after the rest is done.
    public func removeIncomplete(sourceSlug: String, sourceId: UUID) async throws {
        try requireOwnDisk()
        for directory in try snapshotDirectories(sourceSlug) where isUnfinished(directory.url, of: sourceId) {
            guard let mark = try UnfinishedMark.claim(in: directory.url) else { continue }
            try withExtendedLifetime(mark) { try discard(directory.url) }
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
        try requireOwnDisk()
        guard await isAvailable() else { throw DestinationError.unavailable }
        let fileManager = FileManager.default
        let sourceDirectory = try directory(sourceSlug)
        let snapshotDirectory = sourceDirectory.appendingPathComponent(snapshotName, isDirectory: true)
        let listing = try walker.listing(of: payload)
        try SnapshotManifest.checkTopLevelNames(of: listing.entries)
        var created = false
        do {
            if !fileManager.fileExists(atPath: sourceDirectory.path) {
                try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
            }
            if fileManager.fileExists(atPath: snapshotDirectory.path) {
                guard isUnfinished(snapshotDirectory, of: manifest.sourceId) else { throw DestinationError.folderInTheWay(snapshotDirectory.path) }
                guard let earlier = try UnfinishedMark.claim(in: snapshotDirectory) else { throw DestinationError.copyInProgress(snapshotDirectory.path) }
                try withExtendedLifetime(earlier) { try discard(snapshotDirectory) }
            }
            try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false)
            created = true
            let mark = try UnfinishedMark.create(in: snapshotDirectory, sourceId: manifest.sourceId)
            afterWritingItem(mark.path)
            return try withExtendedLifetime(mark) {
                try finishWriting(listing, manifest: manifest, sourceSlug: sourceSlug, into: snapshotDirectory, reusingStoredFiles: reusingStoredFiles)
            }
        } catch where Self.isOutOfSpace(error) {
            if created { try? discard(snapshotDirectory) }
            throw DestinationError.outOfSpace(needed: walker.stats(of: listing.entries).totalBytes, free: freeBytes())
        }
    }

    private func finishWriting(
        _ listing: PayloadListing,
        manifest: SnapshotManifest,
        sourceSlug: String,
        into snapshotDirectory: URL,
        reusingStoredFiles: Bool
    ) throws -> PayloadStats {
        let fileManager = FileManager.default
        let sharesData = reusingStoredFiles && cloning.isSupported(at: root)
        let previous = sharesData ? try storedCopies(sourceSlug).first { $0.manifest.sourceId == manifest.sourceId } : nil
        let writer = SnapshotWriter(cloning: cloning, afterEachItem: afterWritingItem)
        let contents = try writer.write(listing, into: snapshotDirectory, sharingWith: previous)
        guard contents.itemCount > 0 else { throw SourceError.vanishedWhileCopied }
        var manifest = manifest
        manifest.fileCount = contents.itemCount
        manifest.totalBytes = contents.totalBytes
        manifest.files = contents.files
        manifest.sharesData = sharesData
        let manifestURL = snapshotDirectory.appendingPathComponent(SnapshotManifest.fileName)
        try JSONCoding.encoder(pretty: false).encode(manifest).write(to: manifestURL, options: .atomic)
        try fileManager.removeItem(at: snapshotDirectory.appendingPathComponent(SnapshotManifest.unfinishedMarker))
        return PayloadStats(fileCount: contents.itemCount, totalBytes: contents.totalBytes)
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        switch error {
        case let error as CocoaError: error.code == .fileWriteOutOfSpace
        case let error as POSIXError: error.code == .ENOSPC
        default: false
        }
    }

    /// Measured now: what a URL tells is kept from its first look.
    private func freeBytes() -> Int64? {
        var volume = statfs()
        guard statfs(root.path, &volume) == 0 else { return nil }
        return Int64(volume.f_bavail) * Int64(volume.f_bsize)
    }

    /// Removes an unfinished attempt (or copy) whose mark is held: renamed first, so a removal that stops halfway is never
    /// taken for a copy and is finished by the next cleanup.
    private func discard(_ folder: URL) throws {
        if let discardAttempt { return try discardAttempt(folder) }
        try removeForGood(folder.path)
    }

    private func removeForGood(_ folder: String) throws {
        let doomed = folder + Self.removalSuffix
        if FileManager.default.fileExists(atPath: doomed) { try removal.remove(doomed) }
        try removal.unlock(folder)
        try FileManager.default.moveItem(atPath: folder, toPath: doomed)
        try removal.remove(doomed)
    }

    public func delete(_ snapshot: Snapshot, sourceSlug: String) async throws {
        try requireOwnDisk()
        guard naming.date(from: snapshot.name) != nil else { return }
        try removeForGood(try directory(sourceSlug).appendingPathComponent(snapshot.name, isDirectory: true).path)
    }

    public func materialize(_ snapshot: Snapshot, sourceSlug: String, scratch: URL) async throws -> URL {
        try requireOwnDisk()
        guard await isAvailable() else { throw DestinationError.unavailable }
        return try directory(sourceSlug).appendingPathComponent(snapshot.name, isDirectory: true)
    }

    public func usedBytes() async throws -> Int64 {
        try requireOwnDisk()
        guard await isAvailable() else { throw DestinationError.unavailable }
        return try DestinationUsage().bytes(under: root)
    }

    public func canShareUnchangedFiles() async -> Bool? {
        guard await isAvailable() else { return nil }
        return cloning.isSupported(at: root)
    }

    /// Checked before anything is read, written or deleted, not only by `isAvailable`: a disk can be swapped between the two,
    /// and a folder left in `/Volumes` while the disk is away lies on the system disk.
    private func requireOwnDisk() throws {
        switch currentDiskCheck() {
        case .notNeeded, .confirmed: return
        case .notConnected: throw DestinationError.unavailable
        case .notConfirmed: throw DestinationError.diskNotConfirmed
        case let .otherDisk(disk): throw DestinationError.otherDisk(name: disk.name)
        case let .unidentified(name): throw DestinationError.diskUnidentified(name: name)
        case let .unsupportedFormat(name, format): throw DestinationError.unsupportedFormat(name: name, format: format)
        }
    }

    /// A disk that is not APFS is refused whichever disk it is; another or unreadable disk is told as such first.
    private func currentDiskCheck() -> DiskCheck {
        let check = DiskCheck.of(disks.location(of: root), expected: expectedDisk)
        switch check {
        case .notNeeded, .confirmed, .notConfirmed(connected: .some):
            guard let format = DiskFormat.of(root), !format.isSupported else { return check }
            return .unsupportedFormat(name: format.volumeName, format: format.displayName)
        default:
            return check
        }
    }

    private func directory(_ sourceSlug: String) throws -> URL {
        root.appendingPathComponent(try Slug.folderName(sourceSlug), isDirectory: true)
    }

    /// Finished copies of the source, newest first.
    private func storedCopies(_ sourceSlug: String) throws -> [StoredCopy] {
        try snapshotDirectories(sourceSlug)
            .sorted { $0.snapshot.date > $1.snapshot.date }
            .compactMap { directory in
                let url = directory.url.appendingPathComponent(SnapshotManifest.fileName)
                guard let data = try? Data(contentsOf: url),
                      let manifest = try? JSONCoding.decoder().decode(SnapshotManifest.self, from: data) else { return nil }
                return StoredCopy(directory: directory.url, manifest: manifest)
            }
    }

    /// An attempt of the source this app began and did not finish.
    private func isUnfinished(_ snapshotDirectory: URL, of sourceId: UUID) -> Bool {
        let mark = snapshotDirectory.appendingPathComponent(SnapshotManifest.unfinishedMarker)
        return !hasManifest(snapshotDirectory)
            && FileManager.default.fileExists(atPath: mark.path)
            && SnapshotManifest.unfinishedAttempt(withMark: try? Data(contentsOf: mark), belongsTo: sourceId)
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

import Foundation

/// A folder owned by the backup account. The app only reads it; rsync writes each copy once into a new folder through the
/// receiver, and a copy counts once its completion marker is there. Nothing here deletes or renames.
public struct LocalFolderDestination: DestinationStore {
    private let folder: CopyFolder
    private let access: any DestinationAccess
    private let transfer: RsyncTransfer

    public init(root: URL, naming: SnapshotNaming, access: any DestinationAccess, transfer: RsyncTransfer) {
        folder = CopyFolder(root: root, naming: naming)
        self.access = access
        self.transfer = transfer
    }

    public func readiness() async -> DestinationReadiness {
        access.readiness(of: folder.root)
    }

    public func copies(of slug: String) async throws -> [Snapshot] {
        try folder.copies(of: slug)
    }

    public func unfinishedCopies(of slug: String) async throws -> [Snapshot] {
        try folder.unfinished(of: slug)
    }

    public func write(_ payload: Payload, sourceSlug: String, snapshotName: String) async throws {
        let readiness = await readiness()
        guard readiness == .ready else { throw DestinationError.notReady(readiness) }
        let target = try folder.sourceFolder(sourceSlug).appendingPathComponent(snapshotName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw DestinationError.folderExists(target.path) }
        try await transfer.write(payload, into: target, linkDests: try linkDests(of: sourceSlug))
        try await transfer.markComplete(target)
        guard try folder.copies(of: sourceSlug).contains(where: { $0.name == snapshotName }) else {
            throw DestinationError.copyNotVisible(target.path)
        }
    }

    /// rsync takes at most 20. The newest copy first, then the files interrupted attempts already hold.
    private func linkDests(of slug: String) throws -> [URL] {
        let newest = try folder.newestCopy(of: slug).map { [$0] } ?? []
        let attempts = try folder.unfinished(of: slug).reversed()
        return try (newest + attempts).prefix(Self.maxLinkDests).map { try folder.url(of: $0, slug: slug) }
    }

    private static let maxLinkDests = 20

    public func usedBytes() async throws -> Int64 {
        let readiness = await readiness()
        guard readiness == .ready else { throw DestinationError.notReady(readiness) }
        return try DestinationUsage().bytes(under: folder.root)
    }

    public func url(of snapshot: Snapshot, sourceSlug: String) throws -> URL {
        try folder.url(of: snapshot, slug: sourceSlug)
    }
}

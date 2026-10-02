import Foundation

public enum DestinationError: Error, Equatable, LocalizedError {
    case unavailable
    case outOfSpace
    case rcloneMissing
    case commandFailed(String)
    case folderInTheWay(String)
    case invalidFolderName(String)
    case copyMismatch(path: String, expected: Int64, actual: Int64)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The destination is unavailable."
        case .outOfSpace:
            "The destination is out of space."
        case .rcloneMissing:
            "rclone is not installed. Install it with “brew install rclone”."
        case let .commandFailed(output):
            "rclone failed: \(output)"
        case let .folderInTheWay(path):
            "A folder that is not a finished copy is in the way: \(path). It was left as is; move it away and retry."
        case let .invalidFolderName(name):
            "The folder for copies of this source is named “\(name)”, which is not a single folder name. Nothing was read, written or deleted. Fix “slug” of the source in config.json."
        case let .copyMismatch(path, expected, actual):
            "The copy of “\(path)” came out \(actual) bytes long instead of \(expected). The copy was stopped so as not to keep a broken file."
        }
    }
}

public protocol DestinationStore: Sendable {
    func isAvailable() async -> Bool
    /// Every finished copy in the folder of the slug, whoever wrote it.
    func listSnapshots(sourceSlug: String) async throws -> [Snapshot]
    /// The source that wrote each copy in the folder of the slug, by copy name, as its manifest says. A copy whose manifest cannot be read is absent.
    func owners(sourceSlug: String) async throws -> [String: UUID]
    /// Cleans up copies this app began and did not finish (marked `_unfinished`, no manifest). Anything else is left alone.
    func removeIncomplete(sourceSlug: String) async throws
    /// `reusingStoredFiles`: content already present in earlier copies of the source may be cloned instead of written again.
    func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String, reusingStoredFiles: Bool) async throws
    func delete(_ snapshot: Snapshot, sourceSlug: String) async throws
    /// A folder on this computer with the copy contents (including `_snapshot.json`). A cloud destination downloads it into `scratch`.
    func materialize(_ snapshot: Snapshot, sourceSlug: String, scratch: URL) async throws -> URL
    func usedBytes() async throws -> Int64
    /// Whether copies here can share unchanged files; `nil` when it cannot be checked right now (the disk is not connected).
    func canShareUnchangedFiles() async -> Bool?
}

extension DestinationStore {
    /// Copies of the source: those in its folder whose manifest does not name another source. A folder can hold copies
    /// of a removed source with the same slug (configurations made before slugs were retired); they are never this source's.
    public func copies(of source: Source) async throws -> [Snapshot] {
        let snapshots = try await listSnapshots(sourceSlug: source.slug)
        let owners = try await owners(sourceSlug: source.slug)
        return snapshots.filter { owners[$0.name].map { $0 == source.id } ?? true }
    }
}

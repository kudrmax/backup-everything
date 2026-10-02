import Foundation

public enum DestinationError: Error, Equatable, LocalizedError {
    case unavailable
    case outOfSpace
    case rcloneMissing
    case commandFailed(String)
    case folderInTheWay(String)

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
        }
    }
}

public protocol DestinationStore: Sendable {
    func isAvailable() async -> Bool
    func listSnapshots(sourceSlug: String) async throws -> [Snapshot]
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

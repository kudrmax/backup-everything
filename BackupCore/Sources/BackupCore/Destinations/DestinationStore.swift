import Foundation

public enum DestinationError: Error, Equatable, LocalizedError {
    case unavailable
    case outOfSpace
    case rcloneMissing
    case commandFailed(String)
    case folderInTheWay(String)
    case invalidFolderName(String)
    case copyMismatch(path: String, expected: Int64, actual: Int64)
    /// Copies whose deletion stopped halfway (`<name>.deleting`) and still could not be deleted, with the reasons.
    case unfinishedDeletions([String])
    case diskNotConfirmed
    case otherDisk(name: String)

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
        case let .unfinishedDeletions(problems):
            "Could not finish deleting old copies: \(problems.joined(separator: " "))"
        case .diskNotConfirmed:
            "The disk of this destination is not confirmed yet. Nothing was read, written or deleted. Press “Read from connected disk” in its settings."
        case let .otherDisk(name):
            "Another disk named “\(name)” is connected instead of this destination’s disk. Nothing was read, written or deleted there."
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
    /// When only finishing earlier deletions fails, the error is `DestinationError.unfinishedDeletions`.
    func removeIncomplete(sourceSlug: String) async throws
    /// `reusingStoredFiles`: content already present in earlier copies of the source may be cloned instead of written again.
    /// Returns what the copy holds, when the destination knows it: files may vanish from a live source while it is copied.
    @discardableResult
    func write(_ payload: Payload, manifest: SnapshotManifest, sourceSlug: String, snapshotName: String, reusingStoredFiles: Bool) async throws -> PayloadStats?
    func delete(_ snapshot: Snapshot, sourceSlug: String) async throws
    /// A folder on this computer with the copy contents (including `_snapshot.json`). A cloud destination downloads it into `scratch`.
    func materialize(_ snapshot: Snapshot, sourceSlug: String, scratch: URL) async throws -> URL
    func usedBytes() async throws -> Int64
    /// Whether copies here can share unchanged files; `nil` when it cannot be checked right now (the disk is not connected).
    func canShareUnchangedFiles() async -> Bool?
    /// Whether the folder is on the disk the destination was confirmed on. Unless it is, the store is unavailable and refuses everything.
    func diskCheck() async -> DiskCheck
}

extension DestinationStore {
    public func diskCheck() async -> DiskCheck { .notNeeded }

    /// Copies of the source: those in its folder whose manifest does not name another source. A folder can hold copies
    /// of a removed source with the same slug (configurations made before slugs were retired); they are never this source's.
    public func copies(of source: Source) async throws -> [Snapshot] {
        let snapshots = try await listSnapshots(sourceSlug: source.slug)
        let owners = try await owners(sourceSlug: source.slug)
        return snapshots.filter { owners[$0.name].map { $0 == source.id } ?? true }
    }
}

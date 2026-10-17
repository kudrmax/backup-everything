import Foundation

public enum DestinationError: Error, Equatable, LocalizedError {
    case notReady(DestinationReadiness)
    case rsyncMissing
    case commandFailed(String)
    case invalidFolderName(String)
    case folderExists(String)
    case copyNotVisible(String)

    public var errorDescription: String? {
        switch self {
        case let .notReady(readiness):
            Self.describe(readiness)
        case .rsyncMissing:
            "rsync 3 is not installed. Install it with “brew install rsync”."
        case let .commandFailed(output):
            "rsync failed: \(output)"
        case let .folderExists(path):
            "A folder “\(path)” is already there. Copies are never written into an existing folder; the next backup gets a new name."
        case let .copyNotVisible(path):
            "The copy was written to “\(path)” but you cannot read it: fix the permissions of that folder (run the setup script again)."
        case let .invalidFolderName(name):
            "The folder for copies of this source is named “\(name)”, which is not a single folder name. Nothing was read or written. Fix “slug” of the source in config.json."
        }
    }

    public static func describe(_ readiness: DestinationReadiness) -> String {
        switch readiness {
        case .ready: "The destination is ready."
        case .folderMissing: "The destination folder is not there (disk not connected?)."
        case let .notOwnedByBackupAccount(owner): "The destination folder belongs to “\(owner)”, not to the backup account. Run the setup script."
        case .volumeIgnoresOwners: "The disk ignores file owners, so copies there cannot be protected. Run the setup script: it enables ownership on the disk."
        case .accountMissing: "The backup account “\(SystemDestinationAccess.roleAccount)” does not exist. Run the setup script."
        case let .ancestorNotTraversable(path):
            "“\(path)” does not let the backup account in (it is private, 700); choose a destination folder outside Desktop, Documents, Downloads and other private folders, or open that folder to others (chmod o+x)"
        }
    }
}

public protocol DestinationStore: Sendable {
    func readiness() async -> DestinationReadiness
    /// Finished copies in the folder of the slug, oldest first.
    func copies(of slug: String) async throws -> [Snapshot]
    func unfinishedCopies(of slug: String) async throws -> [Snapshot]
    /// Returns a warning when the copy is complete but rsync reported files that vanished during the transfer.
    func write(_ payload: Payload, sourceSlug: String, snapshotName: String) async throws -> String?
    func usedBytes() async throws -> Int64
    func url(of snapshot: Snapshot, sourceSlug: String) throws -> URL
}

extension DestinationStore {
    public func isAvailable() async -> Bool {
        await readiness() == .ready
    }
}

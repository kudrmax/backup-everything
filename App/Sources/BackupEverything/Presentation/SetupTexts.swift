import BackupCore
import Foundation

enum SetupTexts {
    static let intro = "Copies are protected by a separate account on this Mac: the app can only add copies, never delete or change them. The setup script creates that account and prepares the destination folders. Run it once in Terminal from the project folder:"
    static let command = StorageSetup.command

    static func line(_ problem: StorageSetup.Problem, config: Config) -> String {
        switch problem {
        case .rsyncMissing: "rsync 3 is not installed (brew install rsync)"
        case .accountMissing: "The backup account “\(SystemDestinationAccess.roleAccount)” does not exist"
        case .receiverMissing: "The receiver gate is not installed"
        case .sudoRuleMissing: "The sudo rule for the receiver gate is missing or outdated"
        case let .destinationNotReady(id, readiness):
            "“\(config.destination(id)?.name ?? "?")”: \(describe(readiness))"
        }
    }

    private static func describe(_ readiness: DestinationReadiness) -> String {
        switch readiness {
        case .ready: "ready"
        case .folderMissing: "the folder is not there (disk not connected?)"
        case let .notOwnedByBackupAccount(owner): "the folder belongs to “\(owner)”, not to the backup account"
        case .volumeIgnoresOwners: "the disk ignores file owners"
        case .accountMissing: "the backup account does not exist"
        }
    }
}

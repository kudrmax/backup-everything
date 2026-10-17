import BackupCore
import Foundation

enum SetupTexts {
    static let intro = "Copies are protected by a separate account on this Mac: the app can only add copies, never delete or change them. The setup script creates that account, installs the receiver gate and hands an empty destination folder to the account, asking before each step. Run it in Terminal, once per destination:"
    static let noDestination = "Add a destination folder first; the script protects the folder you give it."

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

    /// One command per destination that is not ready; when only the account, gate or rule are missing, the command for
    /// the first destination does all of that too.
    static func commands(for problems: [StorageSetup.Problem], config: Config, script: String) -> [String] {
        let notReady = problems.compactMap { problem -> Destination? in
            guard case let .destinationNotReady(id, _) = problem else { return nil }
            return config.destination(id)
        }
        let targets = notReady.isEmpty ? Array(config.destinations.prefix(1)) : notReady
        return targets.map { StorageSetup.command(script: script, folder: ($0.path as NSString).expandingTildeInPath) }
    }

    private static func describe(_ readiness: DestinationReadiness) -> String {
        switch readiness {
        case .ready: "ready"
        case .folderMissing: "the folder is not there (disk not connected?)"
        case let .notOwnedByBackupAccount(owner): "the folder belongs to “\(owner)”, not to the backup account"
        case .volumeIgnoresOwners: "the disk ignores file owners"
        case .accountMissing: "the backup account does not exist"
        case let .ancestorNotTraversable(path): "“\(path)” above it is private (700), so the backup account cannot reach it"
        }
    }
}

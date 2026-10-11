import BackupCore
import Foundation

/// The folder of a destination is not there although the disk it would be on is.
struct MissingFolder: Equatable {
    let path: String
}

enum DestinationCondition: Equatable {
    case available
    case offline
    case needsConnection
    case unreachable
    /// The folder is there but is not set up for the backup account.
    case notReady(DestinationReadiness)
    case folderMissing(MissingFolder)

    static func of(
        _ destinationId: UUID,
        report: StatusReport,
        unavailable: Set<UUID>,
        readiness: DestinationReadiness? = nil,
        missingFolder: MissingFolder? = nil
    ) -> DestinationCondition {
        if let readiness, readiness != .ready, readiness != .folderMissing { return .notReady(readiness) }
        if let missingFolder { return .folderMissing(missingFolder) }
        for item in report.items {
            switch item {
            case let .connectDestination(id) where id == destinationId: return .needsConnection
            case let .destinationUnavailable(id) where id == destinationId: return .unreachable
            default: continue
            }
        }
        return unavailable.contains(destinationId) ? .offline : .available
    }

    var problem: String? {
        switch self {
        case .needsConnection: "time to connect"
        case .unreachable: "unavailable"
        case .notReady: "not set up"
        case .folderMissing: "folder not found"
        case .available, .offline: nil
        }
    }

    /// What is wrong with the folder and what to do, in full; `nil` when nothing is.
    func explanation(destinationName: String) -> String? {
        switch self {
        case let .notReady(readiness):
            DestinationError.describe(readiness)
        case let .folderMissing(folder):
            "\(Self.missing(folder)). The app doesn’t create it itself: create it or choose another folder."
        default:
            nil
        }
    }

    /// Why the copies of a destination are not listed.
    var copiesNote: String {
        switch self {
        case .notReady: "The folder isn’t set up — copies aren’t shown."
        case let .folderMissing(folder): "\(Self.missing(folder)) — copies can’t be seen."
        default: "Not connected — copies can’t be seen."
        }
    }

    static func missing(_ folder: MissingFolder) -> String {
        "The folder “\(folder.path)” doesn’t exist"
    }

    var isConnected: Bool { self == .available }

    var mark: String {
        switch self {
        case .available: "checkmark.circle.fill"
        case .offline: "minus.circle.fill"
        case .needsConnection: "clock.fill"
        case .unreachable: "exclamationmark.circle.fill"
        case .notReady: "exclamationmark.triangle.fill"
        case .folderMissing: "exclamationmark.circle.fill"
        }
    }
}

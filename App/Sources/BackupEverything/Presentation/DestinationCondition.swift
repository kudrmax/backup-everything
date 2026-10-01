import BackupCore
import Foundation

enum DestinationCondition: Equatable {
    case available
    case offline
    case needsConnection
    case unreachable

    static func of(_ destinationId: UUID, report: StatusReport, unavailable: Set<UUID>) -> DestinationCondition {
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
        case .available, .offline: nil
        }
    }

    var isConnected: Bool { self == .available }
}

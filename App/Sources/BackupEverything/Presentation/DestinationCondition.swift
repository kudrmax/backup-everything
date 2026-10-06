import BackupCore
import Foundation

enum DestinationCondition: Equatable {
    case available
    case offline
    case needsConnection
    case unreachable
    /// A disk is connected where the destination’s disk should be, but it is another disk.
    case otherDisk(name: String)
    /// The folder is on an external disk that was never confirmed; `connected` names the disk there now.
    case diskNotConfirmed(connected: String?)

    static func of(_ destinationId: UUID, report: StatusReport, unavailable: Set<UUID>, disk: DiskCheck? = nil) -> DestinationCondition {
        switch disk {
        case let .otherDisk(other): return .otherDisk(name: other.name)
        case let .notConfirmed(connected): return .diskNotConfirmed(connected: connected?.name)
        default: break
        }
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
        case let .otherDisk(name): "another disk named “\(name)” is connected"
        case .diskNotConfirmed: "disk not confirmed"
        case .available, .offline: nil
        }
    }

    /// What is wrong with the disk and what to do, in full; `nil` when nothing is.
    func diskExplanation(destinationName: String) -> String? {
        switch self {
        case let .otherDisk(name):
            "Another disk named “\(name)” is connected. Nothing is written to it or deleted from it. If it is the disk of “\(destinationName)”, press “\(Self.confirmTitle(destinationName))”."
        case .diskNotConfirmed(connected: nil):
            "Confirm the disk for “\(destinationName)”: connect it and press “\(DiskTexts.readButton)” in its settings."
        case let .diskNotConfirmed(connected?):
            "Confirm the disk for “\(destinationName)”: if the connected disk “\(connected)” is it, press “\(Self.confirmTitle(destinationName))”."
        default:
            nil
        }
    }

    /// A connected disk can be taken as the destination’s disk right now.
    var offersConfirmation: Bool {
        switch self {
        case .otherDisk, .diskNotConfirmed(connected: .some): true
        default: false
        }
    }

    static func confirmTitle(_ destinationName: String) -> String {
        "This is my \(destinationName)"
    }

    var isConnected: Bool { self == .available }

    var mark: String {
        switch self {
        case .available: "checkmark.circle.fill"
        case .offline: "minus.circle.fill"
        case .needsConnection: "clock.fill"
        case .unreachable: "exclamationmark.circle.fill"
        case .otherDisk: "exclamationmark.triangle.fill"
        case .diskNotConfirmed: "questionmark.circle.fill"
        }
    }
}

/// The disk a folder destination is confirmed on, as its settings show it.
enum DiskTexts {
    static let readButton = "Read from connected disk"
    static let rowTip = "Copies go only to this disk.\nAnother disk with the same name is not used."

    /// Why the copies of a destination are not listed.
    static func copiesNote(_ condition: DestinationCondition) -> String {
        switch condition {
        case .otherDisk: "Another disk is connected — its contents aren’t shown."
        case .diskNotConfirmed: "The disk isn’t confirmed — copies aren’t shown."
        default: "Not connected — copies can’t be seen."
        }
    }

    static func identity(_ disk: DiskIdentity?) -> String {
        guard let disk else { return "Not set" }
        return "“\(disk.name)” · " + (disk.uuid.map { "ID \($0)" } ?? "the disk reports no ID")
    }
}

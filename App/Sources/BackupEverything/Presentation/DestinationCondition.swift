import BackupCore
import Foundation

/// The folder of a destination is not there although its disk is: the system disk, or the confirmed disk named `disk`.
struct MissingFolder: Equatable {
    let path: String
    let disk: String?
}

enum DestinationCondition: Equatable {
    case available
    case offline
    case needsConnection
    case unreachable
    /// A disk is connected where the destination’s disk should be, but it is another disk.
    case otherDisk(name: String)
    /// The folder is on an external disk that was never confirmed; `connected` names the disk there now.
    case diskNotConfirmed(connected: String?)
    /// A disk is connected, but its ID could not be read; it is read again at the next check.
    case diskUnidentified(name: String)
    case folderMissing(MissingFolder)

    static func of(
        _ destinationId: UUID,
        report: StatusReport,
        unavailable: Set<UUID>,
        disk: DiskCheck? = nil,
        missingFolder: MissingFolder? = nil
    ) -> DestinationCondition {
        switch disk {
        case let .otherDisk(other): return .otherDisk(name: other.name)
        case let .notConfirmed(connected): return .diskNotConfirmed(connected: connected?.name)
        case let .unidentified(name): return .diskUnidentified(name: name)
        default: break
        }
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
        case let .otherDisk(name): "another disk named “\(name)” is connected"
        case .diskNotConfirmed: "disk not confirmed"
        case let .diskUnidentified(name): "can’t read the ID of disk “\(name)”"
        case .folderMissing: "folder not found"
        case .available, .offline: nil
        }
    }

    /// What is wrong with the disk or the folder and what to do, in full; `nil` when nothing is.
    func explanation(destinationName: String) -> String? {
        switch self {
        case let .otherDisk(name):
            "Another disk named “\(name)” is connected. Nothing is written to it or deleted from it. If it is the disk of “\(destinationName)”, press “\(Self.confirmTitle(destinationName))”."
        case .diskNotConfirmed(connected: nil):
            "Confirm the disk for “\(destinationName)”: connect it and press “\(DiskTexts.readButton)” in its settings."
        case let .diskNotConfirmed(connected?):
            "Confirm the disk for “\(destinationName)”: if the connected disk “\(connected)” is it, press “\(Self.confirmTitle(destinationName))”."
        case let .diskUnidentified(name):
            "Couldn’t read the ID of the connected disk “\(name)”, so it isn’t known whether it is the disk of “\(destinationName)”. Nothing is written to it or deleted from it. The app checks again on its own; if this goes on, reconnect the disk."
        case let .folderMissing(folder):
            "\(DiskTexts.missing(folder)). The app doesn’t create it itself: create it or choose another folder."
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
        case .diskUnidentified: "exclamationmark.triangle.fill"
        case .folderMissing: "exclamationmark.circle.fill"
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
        case .diskUnidentified: "The disk’s ID can’t be read — copies aren’t shown."
        case let .folderMissing(folder): "\(missing(folder)) — copies can’t be seen."
        default: "Not connected — copies can’t be seen."
        }
    }

    static func missing(_ folder: MissingFolder) -> String {
        "The folder “\(folder.path)” doesn’t exist" + (folder.disk.map { " on the disk “\($0)”" } ?? "")
    }

    /// Why a copy on this disk cannot be opened; `nil` when it can.
    static func copyUnavailable(_ check: DiskCheck?) -> String? {
        switch check {
        case .notConnected: "The disk isn’t connected"
        case .notConfirmed: "The disk isn’t confirmed"
        case .otherDisk: "Another disk is connected"
        case .unidentified: "The disk’s ID can’t be read"
        case .notNeeded, .confirmed, nil: nil
        }
    }

    static func unreadable(_ name: String) -> String {
        "Could not read the ID of the disk “\(name)”. Nothing was remembered: reconnect the disk and try again."
    }

    static func name(_ disk: DiskIdentity?) -> String {
        disk.map { "“\($0.name)”" } ?? "Not set"
    }

    static func id(_ disk: DiskIdentity?) -> String? {
        disk.map { $0.uuid.map { "ID \($0)" } ?? "the disk reports no ID" }
    }
}

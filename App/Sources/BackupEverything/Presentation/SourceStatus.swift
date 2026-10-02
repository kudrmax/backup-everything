import BackupCore
import Foundation

enum SourceStatus: Equatable {
    case disabled
    case failed(String)
    case overdue
    case noDestinations
    case warning(String)
    case filesFound(count: Int, bytes: Int64, downloading: Bool)
    case exportDue
    case deviceDue
    case waiting
    case waitingForDevice
    case neverRun
    case ok

    static func of(_ source: Source, report: StatusReport, lastRun: Date?) -> SourceStatus {
        guard source.enabled else { return .disabled }
        var found: [SourceStatus] = []
        for item in report.items {
            switch item {
            case let .runFailed(id, message) where id == source.id: found.append(.failed(message))
            case let .severelyOverdue(id) where id == source.id: found.append(.overdue)
            case let .noDestinations(id) where id == source.id: found.append(.noDestinations)
            case let .deliveryWarning(id, message) where id == source.id: found.append(.warning(message))
            case let .filesAwaitingPickup(id, count, bytes, downloading) where id == source.id:
                found.append(.filesFound(count: count, bytes: bytes, downloading: downloading))
            case let .manualExportDue(id) where id == source.id: found.append(.exportDue)
            case let .waitingForFile(id) where id == source.id: found.append(.waiting)
            case let .deviceDue(id) where id == source.id: found.append(.deviceDue)
            case let .waitingForDevice(id) where id == source.id: found.append(.waitingForDevice)
            default: break
            }
        }
        return found.min { $0.rank < $1.rank } ?? (lastRun == nil ? .neverRun : .ok)
    }

    var severity: OverallStatus {
        switch self {
        case .failed, .overdue: .error
        case .noDestinations, .warning, .filesFound, .exportDue, .deviceDue: .attention
        case .waiting, .waitingForDevice, .disabled, .neverRun, .ok: .ok
        }
    }

    var text: String {
        switch self {
        case .disabled: "Disabled"
        case let .failed(message): "Error: \(message)"
        case .overdue: "Backup is long overdue"
        case .noDestinations: "No destination chosen"
        case let .warning(message): "Delivered, but: \(message)"
        case let .filesFound(count, bytes, downloading):
            "Files found: \(count), \(Texts.bytes(bytes))" + (downloading ? ". Downloading" : "")
        case .exportDue: "Time to export"
        case .waiting: "Waiting for a file: download it and the backup starts on its own"
        case .deviceDue: "Time to connect the device"
        case .waitingForDevice: "Waiting for the device: connect it and the backup starts on its own"
        case .neverRun: "Never run"
        case .ok: "OK"
        }
    }

    /// Files found that are fully downloaded wait for the “Pick up” button.
    var offersPickUp: Bool {
        guard case let .filesFound(_, _, downloading) = self else { return false }
        return !downloading
    }

    var errorMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }

    var note: String? {
        switch self {
        case .ok, .neverRun: nil
        case .disabled: "disabled"
        case let .failed(message): Texts.errorHeadline(message)
        case .overdue: "no backup for a long time"
        case .noDestinations: "no destination chosen"
        case let .warning(message): Texts.errorHeadline(message)
        case let .filesFound(count, bytes, downloading):
            "\(Texts.files(count)) · \(Texts.bytes(bytes))" + (downloading ? " · downloading" : "")
        case .exportDue: "time to export"
        case .waiting: "waiting for a file"
        case .deviceDue: "time to connect"
        case .waitingForDevice: "waiting for the device"
        }
    }

    private var rank: Int {
        switch self {
        case .failed: 0
        case .overdue: 1
        case .noDestinations: 2
        case .filesFound: 3
        case .warning: 4
        case .exportDue, .deviceDue: 5
        case .waiting, .waitingForDevice: 6
        case .disabled, .neverRun, .ok: 7
        }
    }
}

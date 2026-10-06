import BackupCore
import Foundation

enum SourceStatus: Equatable {
    case disabled
    case failed(String)
    /// Long overdue; with the reason when copies are missing or stale, so the red mark does not hide the cause.
    case overdue(CopyShortfall?)
    case noDestinations
    case warning(String)
    case filesFound(count: Int, bytes: Int64, downloading: Bool)
    case exportDue
    case deviceDue
    case waiting
    case waitingForDevice
    case outdated(CopyShortfall)
    case neverRun
    /// Has delivered before, but the report proves no fresh copy now and names no problem: it is busy running.
    case unconfirmed
    case ok

    /// Green only on proof: the report found a fresh copy on every destination. Without proof and without a known problem
    /// the source stays neutral, never “OK”.
    static func of(_ source: Source, report: StatusReport, lastBackup: Date?, gaps: CopyGaps? = nil) -> SourceStatus {
        guard source.enabled else { return .disabled }
        var found: [SourceStatus] = []
        var shortfall: CopyShortfall?
        for case let .copiesOutdated(id, outdated) in report.items where id == source.id {
            shortfall = gaps?.shortfall(of: id, outdated) ?? CopyShortfall(
                gaps: [], freshElsewhere: outdated.freshElsewhere, noCopyAnywhere: outdated.noCopyAnywhere
            )
        }
        for item in report.items {
            switch item {
            case let .runFailed(id, message) where id == source.id: found.append(.failed(message))
            case let .copiesOutdated(id, _) where id == source.id:
                if let shortfall { found.append(.outdated(shortfall)) }
            case let .severelyOverdue(id) where id == source.id: found.append(.overdue(shortfall))
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
        if let worst = found.min(by: { $0.rank < $1.rank }) { return worst }
        if report.fresh.contains(source.id) { return .ok }
        return lastBackup == nil && !report.expected.contains(source.id) ? .neverRun : .unconfirmed
    }

    var severity: OverallStatus {
        switch self {
        case .failed, .overdue: .error
        case .noDestinations, .warning, .filesFound, .exportDue, .deviceDue, .outdated: .attention
        case .waiting, .waitingForDevice, .disabled, .neverRun, .unconfirmed, .ok: .ok
        }
    }

    var text: String {
        switch self {
        case .disabled: "Disabled"
        case let .failed(message): "Error: \(message)"
        case let .overdue(shortfall): (["Backup is long overdue"] + (shortfall.map { [$0.text] } ?? [])).joined(separator: "\n")
        case .noDestinations: "No destination chosen"
        case let .warning(message): "Delivered, but: \(message)"
        case let .filesFound(count, bytes, downloading):
            "Files found: \(count), \(Texts.bytes(bytes))" + (downloading ? ". Downloading" : "")
        case .exportDue: "Time to export"
        case .waiting: "Waiting for a file: download it and the backup starts on its own"
        case .deviceDue: "Time to connect the device"
        case .waitingForDevice: "Waiting for the device: connect it and the backup starts on its own"
        case let .outdated(shortfall): shortfall.text
        case .neverRun: "Never run"
        case .unconfirmed: "No fresh copy confirmed yet"
        case .ok: "OK: a fresh copy on every destination"
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
        case .ok, .neverRun, .unconfirmed: nil
        case .disabled: "disabled"
        case let .failed(message): Texts.errorHeadline(message)
        case let .overdue(shortfall): shortfall.map { "\($0.note) · no backup for a long time" } ?? "no backup for a long time"
        case .noDestinations: "no destination chosen"
        case let .warning(message): Texts.errorHeadline(message)
        case let .filesFound(count, bytes, downloading):
            "\(Texts.files(count)) · \(Texts.bytes(bytes))" + (downloading ? " · downloading" : "")
        case .exportDue: "time to export"
        case .waiting: "waiting for a file"
        case .deviceDue: "time to connect"
        case .waitingForDevice: "waiting for the device"
        case let .outdated(shortfall): shortfall.note
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
        case .outdated: 6
        case .waiting, .waitingForDevice: 7
        case .disabled, .neverRun, .unconfirmed, .ok: 8
        }
    }
}

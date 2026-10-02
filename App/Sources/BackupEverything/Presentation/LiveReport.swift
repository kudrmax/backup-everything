import BackupCore
import Foundation

enum LiveReport {
    static func of(_ report: StatusReport, running: Set<UUID>) -> StatusReport {
        StatusReport(items: report.items.filter { item in
            guard let sourceId = sourceId(of: item) else { return true }
            return !running.contains(sourceId)
        })
    }

    private static func sourceId(of item: AttentionItem) -> UUID? {
        switch item {
        case let .runFailed(sourceId, _), let .deliveryWarning(sourceId, _), let .severelyOverdue(sourceId), let .manualExportDue(sourceId), let .waitingForFile(sourceId), let .deviceDue(sourceId), let .waitingForDevice(sourceId),
             let .filesAwaitingPickup(sourceId, _, _, _), let .noDestinations(sourceId):
            sourceId
        case .destinationUnavailable, .connectDestination:
            nil
        }
    }
}

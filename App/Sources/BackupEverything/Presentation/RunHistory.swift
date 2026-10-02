import BackupCore
import Foundation

enum RunHistory {
    static func runs(_ runs: [RunRecord], onlyProblems: Bool) -> [RunRecord] {
        onlyProblems ? runs.filter { $0.firstFailure != nil } : runs
    }

    static func severity(_ run: RunRecord) -> OverallStatus {
        if run.firstFailure != nil { return .error }
        return run.deliveries.allSatisfy(\.outcome.isDelivered) ? .ok : .attention
    }

    static func copyLine(_ run: RunRecord) -> String? {
        run.snapshotName.map { "\($0), \(Texts.files(run.fileCount ?? 0)), \(Texts.bytes(run.totalBytes ?? 0))" }
    }

    static func failure(_ run: RunRecord) -> String? {
        run.collectError ?? run.firstFailure
    }
}

import BackupCore
import Foundation

enum RunTiming {
    /// How long the previous run of the same kind took: copying from another disk is compared with copying, collecting with collecting.
    /// A record of a package from manual steps (`pickup`) does not fit: the collecting itself happened earlier and is not in it.
    static func usualDuration(of sourceId: UUID, in runs: [RunRecord], copying: Bool) -> TimeInterval? {
        runs.first { run in
            run.sourceId == sourceId
                && run.collectError == nil
                && run.deliveries.contains(where: \.outcome.isDelivered)
                && (copying ? run.copiedFrom != nil : run.trigger == .scheduled || run.trigger == .manual)
        }
        .map { $0.finishedAt.timeIntervalSince($0.startedAt) }
    }

    static func tip(elapsed: TimeInterval, usual: TimeInterval?) -> String {
        let lines = ["Running for \(Texts.duration(elapsed))"] + [usual.map { "Last time took \(Texts.duration($0))" }].compactMap { $0 }
        return lines.joined(separator: "\n")
    }
}

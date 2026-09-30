import BackupCore
import Foundation

enum RunTiming {
    static func usualDuration(of sourceId: UUID, in runs: [RunRecord]) -> TimeInterval? {
        runs.first { run in
            run.sourceId == sourceId
                && run.trigger != .catchUp
                && run.collectError == nil
                && run.deliveries.contains(where: \.outcome.isDelivered)
        }
        .map { $0.finishedAt.timeIntervalSince($0.startedAt) }
    }

    static func tip(elapsed: TimeInterval, usual: TimeInterval?) -> String {
        let forecast = usual.map { "В прошлый раз заняло \(Texts.duration($0))" }
            ?? "Сколько займёт, станет известно после первого запуска"
        return "Идёт \(Texts.duration(elapsed))\n\(forecast)"
    }
}

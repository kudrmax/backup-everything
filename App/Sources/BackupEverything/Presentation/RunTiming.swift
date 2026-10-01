import BackupCore
import Foundation

enum RunTiming {
    /// Сколько длился прошлый такой же запуск: копирование с другого диска сравнивается с копированием, сбор — со сбором.
    /// Запись пакета от шагов человека (`pickup`) не годится: сам сбор шёл раньше и в неё не вошёл.
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
        let lines = ["Идёт \(Texts.duration(elapsed))"] + [usual.map { "В прошлый раз заняло \(Texts.duration($0))" }].compactMap { $0 }
        return lines.joined(separator: "\n")
    }
}

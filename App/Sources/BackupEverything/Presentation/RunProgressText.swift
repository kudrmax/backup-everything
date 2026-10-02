import BackupCore
import Foundation

/// The mark at the start of a source’s row in the overview.
enum SourceMark: Equatable {
    case working
    /// A grey symbol: queued, disabled or calmly waiting.
    case symbol(String)
    case severity(OverallStatus)

    static func of(stage: SourceStage?, isEnabled: Bool, status: SourceStatus) -> SourceMark {
        if let stage { return stage == .queued ? .symbol("hourglass") : .working }
        if !isEnabled { return .symbol("pause.circle") }
        if status == .waiting || status == .waitingForDevice { return .symbol("clock") }
        return .severity(status.severity)
    }
}

enum RunProgressText {
    /// The note of a running source: its stage, the last line its command printed, the step of a chain.
    static func note(_ stage: SourceStage, of source: Source, destinationName: String?, status: String?, step: (index: Int, count: Int)?) -> String {
        let text = Texts.stage(stage, destinationName: destinationName)
        let running = status.map { "\(text.trimmingCharacters(in: CharacterSet(charactersIn: "…"))) · \($0)" } ?? text
        guard stage == .collecting, let step, step.index < source.steps.count else { return running }
        let label = ChainPosition.label(index: step.index, count: step.count)
        return "\(label) · \(ChainPosition.running(source.steps[step.index], status: status))"
    }

    /// The running source in the menu: step, progress and how long it has been going.
    static func menuLine(step: (index: Int, count: Int)?, status: String?, startedAt: Date?, at date: Date) -> String {
        let elapsed = startedAt.map { Texts.duration(date.timeIntervalSince($0)) }
        let position = step.map { ChainPosition.label(index: $0.index, count: $0.count) }
        return [position, status, elapsed].compactMap { $0 }.joined(separator: " · ")
    }

    /// The tip over a source’s age: the exact last and next backup and the size of the copy.
    static func times(_ source: Source, lastBackup: Date?, nextDue: Date?, size: Int64?, now: Date = Date()) -> String {
        var lines = ["Last backup: \(lastBackup.map(Texts.dateTime) ?? "never")"]
        if source.enabled {
            if let nextDue {
                let prefix = source.steps.first?.needsHuman == true ? "Reminder" : "Next"
                lines.append("\(prefix): \(nextDue <= now ? "due now" : Texts.dateTime(nextDue))")
            } else {
                lines.append("Next: manual only")
            }
        }
        if let size {
            lines.append("Copy size: \(Texts.bytes(size))")
        }
        return lines.joined(separator: "\n")
    }
}

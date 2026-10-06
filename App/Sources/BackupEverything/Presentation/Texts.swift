import BackupCore
import Foundation

enum Texts {
    static func schedule(_ schedule: Schedule) -> String {
        switch schedule {
        case .daily: "Every day"
        case .weekly: "Once a week"
        case .monthly: "Once a month"
        case .manual: "Manual only"
        }
    }

    static func trigger(_ trigger: RunTrigger) -> String {
        switch trigger {
        case .scheduled: "Scheduled"
        case .manual: "Manual"
        case .catchUp: "Catch-up"
        case .pickup: "File pickup"
        }
    }

    static func overall(_ status: OverallStatus) -> String {
        switch status {
        case .ok: "All good"
        case .attention: "Needs attention"
        case .error: "Errors"
        }
    }

    static func bytes(_ count: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while shown(value) >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let rounded = shown(value)
        let number = rounded >= 10 || rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
        return "\(number) \(units[unit])"
    }

    /// Whole numbers from 10 up, one decimal below.
    private static func shown(_ value: Double) -> Double {
        value >= 10 ? value.rounded() : (value * 10).rounded() / 10
    }

    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = Int(now.timeIntervalSince(date))
        let days = seconds / 86_400
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if days < 1 { return "\(seconds / 3600) h" }
        if days < 60 { return "\(days) d" }
        if days < 720 { return "\(days / 30) mo" }
        return "\(days / 365) y"
    }

    /// Rounds up: at 16:44, 18:04 is “in 2 h”, not “in 1 h”.
    static func until(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = Int((seconds / 3600).rounded(.up))
        if hours < 24 { return "in \(hours) h" }
        let days = Int((seconds / 86_400).rounded(.up))
        if days < 60 { return "in \(days) d" }
        return "in \(Int((Double(days) / 30).rounded(.up))) mo"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }

    static func errors(_ count: Int) -> String {
        "\(count) \(plural(count, "error", "errors"))"
    }

    static func files(_ count: Int) -> String {
        "\(count) \(plural(count, "file", "files"))"
    }

    static func copies(_ count: Int) -> String {
        "\(count) \(plural(count, "copy", "copies"))"
    }

    private static let commandFailures = ["Command exited with code", "Command did not finish within"]

    static func errorHeadline(_ message: String) -> String {
        if let reason = commandReason(message) { return reason }
        let cuts = [": ", ". ", "\n"].compactMap { message.range(of: $0)?.lowerBound }
        guard let cut = cuts.min() else { return message }
        return String(message[..<cut])
    }

    /// For a failed command, the point is in the last line of its output, not in the exit code.
    private static func commandReason(_ message: String) -> String? {
        guard commandFailures.contains(where: message.hasPrefix), let cut = message.range(of: ". ") else { return nil }
        return message[cut.upperBound...]
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    static func headline(_ report: StatusReport, isWorking: Bool = false) -> String {
        var failed: Set<UUID> = []
        for item in report.items {
            switch item {
            case let .runFailed(sourceId, _), let .severelyOverdue(sourceId): failed.insert(sourceId)
            default: break
            }
        }
        if !failed.isEmpty { return errors(failed.count) }
        guard report.overall == .ok else { return "Needs your action" }
        return isWorking ? "Backing up" : "All good"
    }

    static func plural(_ count: Int, _ one: String, _ other: String) -> String {
        count == 1 ? one : other
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "en_GB")))
    }

    static func relative(_ date: Date, to now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        if abs(interval) < 60 { return interval <= 0 ? "just now" : "any moment" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static let refreshTip = "Check now what the app checks on its own anyway: copy missing copies to the disks and run whatever is due on schedule. Makes no extra backups."
    static let runAllTip = "Collect every source again and write fresh copies to all connected disks without waiting for the schedule. Sources that need a file from you or a device will start waiting for it."

    static func stage(_ stage: SourceStage, destinationName: String?) -> String {
        switch stage {
        case .queued: "queued"
        case .collecting: "preparing the copy…"
        case .delivering: "copying to “\(destinationName ?? "destination")”…"
        }
    }

    static func maskOverlap(_ conflicts: [Source]) -> String? {
        guard !conflicts.isEmpty else { return nil }
        return "The mask overlaps with the source “\(conflicts.map(\.name).joined(separator: "”, “"))” in the same folder."
    }

    static func outcome(_ outcome: DeliveryOutcome) -> String {
        switch outcome {
        case let .delivered(pruned, warning):
            let base = pruned > 0 ? "Delivered, old copies removed: \(pruned)" : "Delivered"
            return warning.map { "\(base). \($0)" } ?? base
        case .unavailable:
            return "Unavailable, waiting"
        case let .failed(message):
            return "Error: \(message)"
        }
    }

    static func runSummary(_ run: RunRecord) -> String {
        if let collectError = run.collectError { return "Error: \(collectError)" }
        let total = run.deliveries.count
        let delivered = run.deliveries.filter(\.outcome.isDelivered).count
        if let failure = run.firstFailure {
            return "Delivered: \(delivered) of \(total). Error: \(failure)"
        }
        if delivered == 0 { return "Destinations unavailable, backup postponed" }
        if delivered < total { return "Delivered: \(delivered) of \(total), the rest are waiting" }
        let pruned = run.deliveries.reduce(0) { sum, delivery in
            if case let .delivered(pruned, _) = delivery.outcome { return sum + pruned }
            return sum
        }
        return pruned > 0 ? "Done. Old copies removed: \(pruned)" : "Done"
    }
}

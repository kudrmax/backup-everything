import BackupCore
import Foundation

enum Texts {
    static func schedule(_ schedule: Schedule) -> String {
        switch schedule {
        case .daily: "Каждый день"
        case .weekly: "Раз в неделю"
        case .monthly: "Раз в месяц"
        case .manual: "Только вручную"
        }
    }

    static func kind(_ kind: SourceKind) -> String {
        switch kind {
        case .folder: "Папка"
        case .command: "Команда"
        case .manualExport: "Ручной экспорт"
        case .steps: "По шагам"
        }
    }

    static func trigger(_ trigger: RunTrigger) -> String {
        switch trigger {
        case .scheduled: "По расписанию"
        case .manual: "Вручную"
        case .catchUp: "Догон"
        case .pickup: "Подхват файлов"
        }
    }

    static func overall(_ status: OverallStatus) -> String {
        switch status {
        case .ok: "Всё в порядке"
        case .attention: "Требует внимания"
        case .error: "Есть ошибки"
        }
    }

    static func bytes(_ count: Int64) -> String {
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var value = Double(count)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let rounded = (value * 10).rounded() / 10
        let number = rounded >= 10 || rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
        return "\(number) \(units[unit])"
    }

    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = Int(now.timeIntervalSince(date))
        let days = seconds / 86_400
        if seconds < 60 { return "сейчас" }
        if seconds < 3600 { return "\(seconds / 60) мин" }
        if days < 1 { return "\(seconds / 3600) ч" }
        if days < 60 { return "\(days) дн" }
        if days < 720 { return "\(days / 30) мес" }
        return "\(days / 365) г"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds) с" }
        if seconds < 3600 { return "\(seconds / 60) мин" }
        return "\(seconds / 3600) ч \(seconds % 3600 / 60) мин"
    }

    static func errors(_ count: Int) -> String {
        "\(count) \(plural(count, "ошибка", "ошибки", "ошибок"))"
    }

    static func files(_ count: Int) -> String {
        "\(count) \(plural(count, "файл", "файла", "файлов"))"
    }

    static func copies(_ count: Int) -> String {
        "\(count) \(plural(count, "копия", "копии", "копий"))"
    }

    private static let commandFailures = ["Команда завершилась с кодом", "Команда не уложилась в"]

    static func errorHeadline(_ message: String) -> String {
        if let reason = commandReason(message) { return reason }
        let cuts = [": ", ". ", "\n"].compactMap { message.range(of: $0)?.lowerBound }
        guard let cut = cuts.min() else { return message }
        return String(message[..<cut])
    }

    /// У упавшей команды суть — в последней строке её вывода, а не в коде возврата.
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
        guard report.items.isEmpty else { return "Нужно твоё действие" }
        return isWorking ? "Идёт бэкап" : "Всё в порядке"
    }

    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = count % 100
        let units = count % 10
        if (11...14).contains(tens) { return many }
        if units == 1 { return one }
        if (2...4).contains(units) { return few }
        return many
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ru_RU")))
    }

    static func relative(_ date: Date, to now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        if abs(interval) < 60 { return interval <= 0 ? "только что" : "вот-вот" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func stage(_ stage: SourceStage, destinationName: String?) -> String {
        switch stage {
        case .queued: "в очереди"
        case .collecting: "готовит копию…"
        case .delivering: "копирует на «\(destinationName ?? "назначение")»…"
        }
    }

    static func outcome(_ outcome: DeliveryOutcome) -> String {
        switch outcome {
        case let .delivered(pruned, warning):
            let base = pruned > 0 ? "Доставлено, удалено старых копий: \(pruned)" : "Доставлено"
            return warning.map { "\(base). \($0)" } ?? base
        case .unavailable:
            return "Недоступно, ждёт"
        case let .failed(message):
            return "Ошибка: \(message)"
        }
    }

    static func runSummary(_ run: RunRecord) -> String {
        if let collectError = run.collectError { return "Ошибка: \(collectError)" }
        let total = run.deliveries.count
        let delivered = run.deliveries.filter(\.outcome.isDelivered).count
        if let failure = run.firstFailure {
            return "Доставлено: \(delivered) из \(total). Ошибка: \(failure)"
        }
        if delivered == 0 { return "Назначения недоступны, бэкап отложен" }
        if delivered < total { return "Доставлено: \(delivered) из \(total), остальные ждут" }
        let pruned = run.deliveries.reduce(0) { sum, delivery in
            if case let .delivered(pruned, _) = delivery.outcome { return sum + pruned }
            return sum
        }
        return pruned > 0 ? "Готово. Удалено старых копий: \(pruned)" : "Готово"
    }
}

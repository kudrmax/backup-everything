import BackupCore
import Foundation

struct AttentionText: Equatable {
    let title: String
    let detail: String
}

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

    static func attention(_ item: AttentionItem, config: Config) -> AttentionText {
        func source(_ id: UUID) -> String { config.source(id)?.name ?? "Источник" }
        func destination(_ id: UUID) -> String { config.destination(id)?.name ?? "Назначение" }
        switch item {
        case let .runFailed(sourceId, message):
            return AttentionText(title: source(sourceId), detail: "Ошибка: \(message)")
        case let .severelyOverdue(sourceId):
            return AttentionText(title: source(sourceId), detail: "Бэкап сильно просрочен")
        case let .manualExportDue(sourceId):
            return AttentionText(title: source(sourceId), detail: "Пора сделать экспорт")
        case let .filesAwaitingPickup(sourceId, fileCount, totalBytes, downloadInProgress):
            let found = "Найдено файлов: \(fileCount), \(bytes(totalBytes))"
            return AttentionText(title: source(sourceId), detail: downloadInProgress ? "\(found). Идёт загрузка" : found)
        case let .noDestinations(sourceId):
            return AttentionText(title: source(sourceId), detail: "Не выбрано, куда бэкапить")
        case let .destinationUnavailable(destinationId):
            return AttentionText(title: destination(destinationId), detail: "Назначение недоступно, бэкап ждёт")
        case let .connectDestination(destinationId):
            return AttentionText(title: destination(destinationId), detail: "Пора подключить диск")
        }
    }

    static func stage(_ stage: SourceStage, destinationName: String?) -> String {
        switch stage {
        case .queued: "В очереди"
        case .collecting: "Собирает данные…"
        case .delivering: "Записывает в «\(destinationName ?? "назначение")»…"
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

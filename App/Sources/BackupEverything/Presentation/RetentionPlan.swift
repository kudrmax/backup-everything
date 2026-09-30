import BackupCore

enum RetentionPreset: CaseIterable, Identifiable {
    case week
    case month
    case year
    case fiveYears

    var id: Self { self }

    var rules: RetentionRules {
        switch self {
        case .week: RetentionRules(daily: 7, weekly: 0, monthly: 0, yearly: 0)
        case .month: RetentionRules(daily: 7, weekly: 4, monthly: 0, yearly: 0)
        case .year: RetentionRules(daily: 7, weekly: 4, monthly: 12, yearly: 0)
        case .fiveYears: RetentionRules(daily: 7, weekly: 4, monthly: 12, yearly: 5)
        }
    }

    var title: String {
        switch self {
        case .week: "неделю"
        case .month: "месяц"
        case .year: "год"
        case .fiveYears: "5 лет"
        }
    }

    static func matching(_ rules: RetentionRules) -> RetentionPreset? {
        allCases.first { $0.rules == rules }
    }

    static func offered(for schedule: Schedule) -> [RetentionPreset] {
        switch schedule {
        case .daily, .manual: allCases
        case .weekly: [.month, .year, .fiveYears]
        case .monthly: [.year, .fiveYears]
        }
    }
}

struct RetentionStep: Equatable, Identifiable {
    enum Unit: Int, CaseIterable {
        case day
        case week
        case month
        case year
    }

    let unit: Unit
    let count: Int

    var id: Unit { unit }

    var label: String { "\(length) — \(rhythm)" }

    var length: String { "\(count) \(Texts.plural(count, names.0, names.1, names.2))" }

    var span: String {
        let one = unit == .week ? "неделю" : names.0
        return "\(count) \(Texts.plural(count, one, names.1, names.2))"
    }

    var moment: String {
        switch unit {
        case .day: "к любому дню"
        case .week: "к любой неделе"
        case .month: "к любому месяцу"
        case .year: "к любому году"
        }
    }

    private var names: (String, String, String) {
        switch unit {
        case .day: ("день", "дня", "дней")
        case .week: ("неделя", "недели", "недель")
        case .month: ("месяц", "месяца", "месяцев")
        case .year: ("год", "года", "лет")
        }
    }

    var rhythm: String {
        switch unit {
        case .day: "каждый день"
        case .week: "раз в неделю"
        case .month: "раз в месяц"
        case .year: "раз в год"
        }
    }
}

enum RetentionPlan {
    private static let ending = "Всё, что старше, удаляется само."

    static func steps(_ rules: RetentionRules) -> [RetentionStep] {
        [
            RetentionStep(unit: .day, count: rules.daily),
            RetentionStep(unit: .week, count: rules.weekly),
            RetentionStep(unit: .month, count: rules.monthly),
            RetentionStep(unit: .year, count: rules.yearly),
        ]
        .filter { $0.count > 0 }
    }

    static func summary(_ rules: RetentionRules) -> String {
        if let preset = RetentionPreset.matching(rules) { return "за \(preset.title)" }
        guard let farthest = steps(rules).last else { return "только последнюю копию" }
        return "за \(farthest.span)"
    }

    static func explanation(_ rules: RetentionRules, schedule: Schedule) -> String {
        let all = steps(rules)
        guard !all.isEmpty else { return "Хранится только самая свежая копия." }
        let visible = all.filter { $0.unit.rawValue >= finestUnit(of: schedule).rawValue }
        guard !visible.isEmpty else {
            let count = all.map(\.count).max() ?? 0
            let kept = Texts.plural(count, "Хранится \(count) последняя копия", "Хранятся \(count) последние копии", "Хранятся \(count) последних копий")
            return "\(kept). \(ending)"
        }
        let parts = visible.map { "\($0.moment) за \($0.span)" }
        let list = parts.count > 1
            ? "\(parts.dropLast().joined(separator: ", ")) и \(parts[parts.count - 1])"
            : parts[0]
        return "Можно вернуться \(list). \(ending)"
    }

    private static func finestUnit(of schedule: Schedule) -> RetentionStep.Unit {
        switch schedule {
        case .daily, .manual: .day
        case .weekly: .week
        case .monthly: .month
        }
    }
}

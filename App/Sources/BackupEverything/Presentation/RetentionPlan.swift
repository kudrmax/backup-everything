import BackupCore

struct RetentionStage: Equatable, Identifiable {
    enum Unit: CaseIterable {
        case day
        case week
        case month
        case year
    }

    let unit: Unit
    let count: Int
    let opensStory: Bool

    var id: Unit { unit }
    var isKept: Bool { count > 0 }

    var prefix: String {
        guard isKept else { return "—" }
        guard opensStory else { return "Потом до" }
        guard count == 1 else { return "Первые" }
        return unit == .week ? "Первую" : "Первый"
    }

    var unitName: String {
        opensStory ? Texts.plural(count, accusative.0, accusative.1, accusative.2) : genitive
    }

    var effect: String {
        guard isKept else { return "не используется" }
        switch unit {
        case .day: "хранятся все копии"
        case .week: "остаётся одна в неделю"
        case .month: "остаётся одна в месяц"
        case .year: "остаётся одна в год"
        }
    }

    var limit: String { "до \(count) \(genitive)" }

    private var genitive: String {
        let isSingular = count % 10 == 1 && count % 100 != 11
        switch unit {
        case .day: return isSingular ? "дня" : "дней"
        case .week: return isSingular ? "недели" : "недель"
        case .month: return isSingular ? "месяца" : "месяцев"
        case .year: return isSingular ? "года" : "лет"
        }
    }

    private var accusative: (String, String, String) {
        switch unit {
        case .day: ("день", "дня", "дней")
        case .week: ("неделю", "недели", "недель")
        case .month: ("месяц", "месяца", "месяцев")
        case .year: ("год", "года", "лет")
        }
    }
}

enum RetentionPlan {
    static func stages(_ rules: RetentionRules) -> [RetentionStage] {
        let counts: [(RetentionStage.Unit, Int)] = [
            (.day, rules.daily), (.week, rules.weekly), (.month, rules.monthly), (.year, rules.yearly),
        ]
        let opening = counts.first { $0.1 > 0 }?.0 ?? .day
        return counts.map { RetentionStage(unit: $0.0, count: $0.1, opensStory: $0.0 == opening) }
    }

    static func summary(_ rules: RetentionRules) -> String {
        stages(rules).last(where: \.isKept)?.limit ?? "только последнюю копию"
    }
}

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
        return opensStory ? "First" : "Then up to"
    }

    var unitName: String {
        switch unit {
        case .day: Texts.plural(count, "day", "days")
        case .week: Texts.plural(count, "week", "weeks")
        case .month: Texts.plural(count, "month", "months")
        case .year: Texts.plural(count, "year", "years")
        }
    }

    var effect: String {
        guard isKept else { return "not used" }
        switch unit {
        case .day: return "every copy is kept"
        case .week: return "one per week is kept"
        case .month: return "one per month is kept"
        case .year: return "one per year is kept"
        }
    }

    var limit: String { "up to \(count) \(unitName)" }
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
        stages(rules).last(where: \.isKept)?.limit ?? "only the latest copy"
    }
}

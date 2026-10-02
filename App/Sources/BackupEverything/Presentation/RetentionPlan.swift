import BackupCore

struct RetentionStage: Equatable, Identifiable {
    enum Unit: CaseIterable {
        case day
        case week
        case month
        case year

        /// The most copies of this kind the editor allows.
        var maximum: Int {
            switch self {
            case .day: 365
            case .week: 104
            case .month: 120
            case .year: 50
            }
        }
    }

    let unit: Unit
    let count: Int

    var id: Unit { unit }
    var isKept: Bool { count > 0 }

    var lead: String {
        switch unit {
        case .day: "Keep one copy per day"
        case .week: "Keep one copy per week"
        case .month: "Keep one copy per month"
        case .year: "Keep one copy per year"
        }
    }

    var tail: String {
        let units = switch unit {
        case .day: Texts.plural(count, "day", "days")
        case .week: Texts.plural(count, "week", "weeks")
        case .month: Texts.plural(count, "month", "months")
        case .year: Texts.plural(count, "year", "years")
        }
        return "\(units) you backed up"
    }

    var sentence: String { "\(lead) for the last \(count) \(tail)" }
}

enum RetentionPlan {
    static let footnote = "Older copies are deleted. The newest copy is always kept."
    static let newestOnly = "Only the newest copy is kept."

    static func stages(_ rules: RetentionRules) -> [RetentionStage] {
        let counts: [(RetentionStage.Unit, Int)] = [
            (.day, rules.daily), (.week, rules.weekly), (.month, rules.monthly), (.year, rules.yearly),
        ]
        return counts.map { RetentionStage(unit: $0.0, count: $0.1) }
    }

    static func footnote(_ rules: RetentionRules) -> String {
        stages(rules).contains(where: \.isKept) ? footnote : newestOnly
    }

    static func summary(_ rules: RetentionRules) -> String {
        stages(rules).last(where: \.isKept).map { "last \($0.count) \($0.tail)" } ?? "only the newest copy"
    }
}

import Foundation

public struct RetentionPolicy: Sendable {
    private enum Level: CaseIterable {
        case day, week, month, year

        func limit(in rules: RetentionRules) -> Int {
            switch self {
            case .day: rules.daily
            case .week: rules.weekly
            case .month: rules.monthly
            case .year: rules.yearly
            }
        }

        func bucket(of date: Date, calendar: Calendar) -> String {
            switch self {
            case .day:
                "\(calendar.component(.year, from: date))-\(calendar.component(.month, from: date))-\(calendar.component(.day, from: date))"
            case .week:
                "\(calendar.component(.yearForWeekOfYear, from: date))-W\(calendar.component(.weekOfYear, from: date))"
            case .month:
                "\(calendar.component(.year, from: date))-\(calendar.component(.month, from: date))"
            case .year:
                "\(calendar.component(.year, from: date))"
            }
        }
    }

    private let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    public func snapshotsToKeep(_ snapshots: [Snapshot], rules: RetentionRules) -> Set<Snapshot> {
        let sorted = snapshots.sorted { $0.date > $1.date }
        guard let newest = sorted.first else { return [] }
        var keep: Set<Snapshot> = [newest]
        for level in Level.allCases {
            let limit = level.limit(in: rules)
            guard limit > 0 else { continue }
            var seen: Set<String> = []
            for snapshot in sorted {
                let bucket = level.bucket(of: snapshot.date, calendar: calendar)
                if seen.contains(bucket) { continue }
                if seen.count == limit { break }
                seen.insert(bucket)
                keep.insert(snapshot)
            }
        }
        return keep
    }

    public func snapshotsToDelete(_ snapshots: [Snapshot], rules: RetentionRules) -> [Snapshot] {
        let keep = snapshotsToKeep(snapshots, rules: rules)
        return snapshots.filter { !keep.contains($0) }.sorted { $0.date < $1.date }
    }
}

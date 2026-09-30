import Foundation

public enum Schedule: String, Codable, Sendable, CaseIterable {
    case daily
    case weekly
    case monthly
    case manual

    public func nextDue(after date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .daily: calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly: calendar.date(byAdding: .day, value: 7, to: date)
        case .monthly: calendar.date(byAdding: .month, value: 1, to: date)
        case .manual: nil
        }
    }
}

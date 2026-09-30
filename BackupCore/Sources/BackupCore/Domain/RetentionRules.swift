import Foundation

public struct RetentionRules: Codable, Sendable, Equatable {
    public var daily: Int
    public var weekly: Int
    public var monthly: Int
    public var yearly: Int

    public static let standard = RetentionRules(daily: 7, weekly: 4, monthly: 12, yearly: 0)

    public init(daily: Int, weekly: Int, monthly: Int, yearly: Int) {
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
        self.yearly = yearly
    }
}

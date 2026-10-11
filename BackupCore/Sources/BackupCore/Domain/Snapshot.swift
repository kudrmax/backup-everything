import Foundation

public struct Snapshot: Sendable, Equatable, Hashable {
    public let name: String
    public let date: Date

    public init(name: String, date: Date) {
        self.name = name
        self.date = date
    }
}

/// Copies are named by local time, `2026-09-28_143000`. When clocks go back, an hour repeats; names in it carry the UTC offset,
/// `2026-10-25_023000+0200` and `2026-10-25_023000+0100`, so that two copies never share a name and each reads back as its own moment.
public struct SnapshotNaming: Sendable {
    private static let localFormat = "yyyy-MM-dd_HHmmss"
    private static let offsetFormat = "yyyy-MM-dd_HHmmssZ"

    private let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func name(for date: Date) -> String {
        let local = formatter(Self.localFormat).string(from: date)
        return isRepeated(local, at: date) ? formatter(Self.offsetFormat).string(from: date) : local
    }

    /// A name with an offset is one moment wherever the Mac is now; a plain name is read in the current time zone.
    public func date(from name: String) -> Date? {
        if let date = Self.date(from: name, format: Self.localFormat, in: timeZone) { return date }
        return Self.offsetZone(of: name).flatMap { Self.date(from: name, format: Self.offsetFormat, in: $0) }
    }

    public func snapshot(named name: String) -> Snapshot? {
        date(from: name).map { Snapshot(name: name, date: $0) }
    }

    /// Whether another moment with a different UTC offset shows the same local time.
    private func isRepeated(_ local: String, at date: Date) -> Bool {
        let offset = timeZone.secondsFromGMT(for: date)
        let neighbouringOffsets = Set([-1.0, 1.0].map { timeZone.secondsFromGMT(for: date.addingTimeInterval($0 * 86_400)) })
        return neighbouringOffsets.subtracting([offset]).contains { other in
            formatter(Self.localFormat).string(from: date.addingTimeInterval(TimeInterval(offset - other))) == local
        }
    }

    private func formatter(_ format: String) -> DateFormatter {
        Self.formatter(format, in: timeZone)
    }

    private static func date(from name: String, format: String, in zone: TimeZone) -> Date? {
        let formatter = formatter(format, in: zone)
        guard let date = formatter.date(from: name), formatter.string(from: date) == name else { return nil }
        return date
    }

    /// `+0200` at the end of the name as a fixed zone: the name is checked against the offset it carries, not against today's zone.
    private static func offsetZone(of name: String) -> TimeZone? {
        let offset = name.suffix(5)
        guard let sign = offset.first, sign == "+" || sign == "-" else { return nil }
        let digits = offset.dropFirst()
        guard digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits) else { return nil }
        let seconds = (value / 100 * 3600 + value % 100 * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    private static func formatter(_ format: String, in zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }
}

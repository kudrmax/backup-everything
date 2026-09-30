import Foundation

public struct Snapshot: Sendable, Equatable, Hashable {
    public let name: String
    public let date: Date

    public init(name: String, date: Date) {
        self.name = name
        self.date = date
    }
}

public struct SnapshotManifest: Codable, Sendable, Equatable {
    public static let fileName = "_snapshot.json"

    public var sourceId: UUID
    public var sourceName: String
    public var collectedAt: Date
    public var fileCount: Int
    public var totalBytes: Int64

    public init(sourceId: UUID, sourceName: String, collectedAt: Date, fileCount: Int, totalBytes: Int64) {
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.collectedAt = collectedAt
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }
}

public struct SnapshotNaming: Sendable {
    private let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func name(for date: Date) -> String {
        formatter().string(from: date)
    }

    public func date(from name: String) -> Date? {
        let formatter = formatter()
        guard let date = formatter.date(from: name), formatter.string(from: date) == name else { return nil }
        return date
    }

    public func snapshot(named name: String) -> Snapshot? {
        date(from: name).map { Snapshot(name: name, date: $0) }
    }

    private func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }
}

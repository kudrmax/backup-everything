import Foundation
@testable import BackupCore

enum Fixtures {
    static let utc = TimeZone(identifier: "UTC")!
    static let naming = SnapshotNaming(timeZone: utc)

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = utc
        return calendar
    }

    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    static func snapshot(_ text: String) -> Snapshot {
        let date = date(text)
        return Snapshot(name: naming.name(for: date), date: date)
    }

    static func source(
        name: String = "Obsidian",
        kind: SourceKind = .folder(path: "/tmp/none", excludes: []),
        schedule: Schedule = .daily,
        retention: RetentionRules = .standard,
        destinations: [Destination] = [],
        createdAt: Date = date("2026-09-01 00:00:00")
    ) -> Source {
        Source(
            name: name,
            slug: Slug.make(from: name, existing: []),
            kind: kind,
            schedule: schedule,
            retention: retention,
            destinationIds: destinations.map(\.id),
            createdAt: createdAt
        )
    }

    static func localDestination(_ name: String, at url: URL, expectedEvery: ExpectedEvery = .always) -> Destination {
        Destination(name: name, kind: .localFolder(path: url.path), expectedEvery: expectedEvery)
    }
}

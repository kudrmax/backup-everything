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
    /// Put into a copy folder before writing starts and removed after the manifest: only such folders are ever cleaned up as unfinished.
    public static let unfinishedMarker = "_unfinished"
    static let unfinishedNote = "Backup Everything was writing this copy and did not finish. It will be cleaned up after the next successful backup.\n"

    public var sourceId: UUID
    public var sourceName: String
    public var collectedAt: Date
    public var fileCount: Int
    public var totalBytes: Int64
    /// Files of the copy with their hashes. Absent in the cloud and in local copies written before clones appeared.
    public var files: [SnapshotFile]?
    /// Unchanged files of the copy are clones of files from earlier copies of this source.
    public var sharesData: Bool?

    public init(
        sourceId: UUID,
        sourceName: String,
        collectedAt: Date,
        fileCount: Int,
        totalBytes: Int64,
        files: [SnapshotFile]? = nil,
        sharesData: Bool? = nil
    ) {
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.collectedAt = collectedAt
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.files = files
        self.sharesData = sharesData
    }
}

public struct SnapshotFile: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int64
    public var sha256: String
    public var modified: Date

    public init(path: String, size: Int64, sha256: String, modified: Date) {
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.modified = modified
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

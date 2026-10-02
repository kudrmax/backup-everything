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
    /// Names of the app's own files at the top of every copy.
    public static let serviceFileNames = [fileName, unfinishedMarker]

    /// Data under a service name at the top of a copy would be taken for the app's own file, so such data is refused.
    /// Names are compared the way the disk does: regardless of case and Unicode form.
    static func checkTopLevelNames(of entries: [PayloadEntry]) throws {
        let reserved = serviceFileNames.map(GlobPattern.init)
        let clash = entries.first { entry in
            !entry.relativePath.contains("/") && reserved.contains { $0.matches(entry.relativePath) }
        }
        if let clash { throw SourceError.reservedName(clash.relativePath) }
    }

    public var sourceId: UUID
    public var sourceName: String
    public var collectedAt: Date
    public var fileCount: Int
    public var totalBytes: Int64
    /// Files of the copy with their hashes. Absent in the cloud and in local copies written before clones appeared.
    public var files: [SnapshotFile]?
    /// Unchanged files of the copy are clones of files from earlier copies of this source.
    public var sharesData: Bool?

    private struct Owner: Decodable {
        let sourceId: UUID
    }

    /// The source named in the manifest of the copy in `directory`; `nil` when there is no readable manifest.
    static func owner(of directory: URL) -> UUID? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return (try? JSONCoding.decoder().decode(Owner.self, from: data))?.sourceId
    }

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

    public func date(from name: String) -> Date? {
        for format in [Self.localFormat, Self.offsetFormat] {
            let formatter = formatter(format)
            if let date = formatter.date(from: name), formatter.string(from: date) == name { return date }
        }
        return nil
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

import Foundation

/// Copies of a source on a destination that the retention rule no longer keeps. The app only tells about them; the
/// person removes them with the command given here.
public struct ExcessCopies: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let snapshot: Snapshot
        public let folder: URL
        public let bytes: Int64

        public init(snapshot: Snapshot, folder: URL, bytes: Int64) {
            self.snapshot = snapshot
            self.folder = folder
            self.bytes = bytes
        }
    }

    public let sourceId: UUID
    public let destinationId: UUID
    public let items: [Item]
    public let asOf: Date?

    public init(sourceId: UUID, destinationId: UUID, items: [Item], asOf: Date?) {
        self.sourceId = sourceId
        self.destinationId = destinationId
        self.items = items
        self.asOf = asOf
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    public static func command(for items: [Item], user: String) -> String {
        let folders = items.map { quoted($0.folder.path) }.joined(separator: " ")
        return "sudo chown -R \(quoted(user)) \(folders) && trash \(folders)"
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct ExcessCalculator: Sendable {
    private let retention: RetentionPolicy

    public init(retention: RetentionPolicy) {
        self.retention = retention
    }

    public func excess(of source: Source, on destination: Destination, copies: [Snapshot], folder: (Snapshot) throws -> URL, asOf: Date?) throws -> ExcessCopies {
        let doomed = retention.snapshotsToDelete(copies, rules: source.retention)
        let items = try doomed.map { snapshot -> ExcessCopies.Item in
            let url = try folder(snapshot)
            let bytes = asOf == nil ? (try? DestinationUsage().bytes(under: url)) ?? 0 : 0
            return ExcessCopies.Item(snapshot: snapshot, folder: url, bytes: bytes)
        }
        return ExcessCopies(sourceId: source.id, destinationId: destination.id, items: items, asOf: asOf)
    }
}

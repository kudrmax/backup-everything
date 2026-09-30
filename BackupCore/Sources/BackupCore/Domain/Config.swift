import Foundation

public struct Config: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var sources: [Source]
    public var destinations: [Destination]

    public init(sources: [Source] = [], destinations: [Destination] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sources = sources
        self.destinations = destinations
    }

    public func source(_ id: UUID) -> Source? {
        sources.first { $0.id == id }
    }

    public func destination(_ id: UUID) -> Destination? {
        destinations.first { $0.id == id }
    }

    public func destinations(of source: Source) -> [Destination] {
        source.destinationIds.compactMap(destination)
    }
}

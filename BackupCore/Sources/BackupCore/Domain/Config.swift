import Foundation

public struct Config: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var sources: [Source]
    public var destinations: [Destination]
    /// Folder names of removed sources. A new source never takes one: the folder still holds the removed source's copies.
    public var retiredSlugs: [String]

    public init(sources: [Source] = [], destinations: [Destination] = [], retiredSlugs: [String] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sources = sources
        self.destinations = destinations
        self.retiredSlugs = retiredSlugs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sources, destinations, retiredSlugs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sources = try container.decode([Source].self, forKey: .sources)
        destinations = try container.decode([Destination].self, forKey: .destinations)
        retiredSlugs = try container.decodeIfPresent([String].self, forKey: .retiredSlugs) ?? []
    }

    /// Folder names that a new source cannot take: those of the current sources and of removed ones.
    public var takenSlugs: Set<String> {
        Set(sources.map(\.slug)).union(retiredSlugs)
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

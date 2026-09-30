import Foundation

public struct ConfigEditor: Sendable {
    public init() {}

    public func makeSource(
        name: String,
        kind: SourceKind,
        schedule: Schedule = .daily,
        retention: RetentionRules = .standard,
        instructions: String = "",
        now: Date,
        in config: Config
    ) -> Source {
        Source(
            name: name,
            slug: Slug.make(from: name, existing: Set(config.sources.map(\.slug))),
            kind: kind,
            schedule: schedule,
            retention: retention,
            instructions: instructions,
            createdAt: now
        )
    }

    public func save(_ source: Source, in config: inout Config) {
        guard let index = config.sources.firstIndex(where: { $0.id == source.id }) else {
            config.sources.append(source)
            return
        }
        var updated = source
        updated.slug = config.sources[index].slug
        config.sources[index] = updated
    }

    public func removeSource(_ id: UUID, from config: inout Config) {
        config.sources.removeAll { $0.id == id }
    }

    public func save(_ destination: Destination, in config: inout Config) {
        if let index = config.destinations.firstIndex(where: { $0.id == destination.id }) {
            config.destinations[index] = destination
        } else {
            config.destinations.append(destination)
        }
    }

    public func removeDestination(_ id: UUID, from config: inout Config) {
        config.destinations.removeAll { $0.id == id }
        for index in config.sources.indices {
            config.sources[index].destinationIds.removeAll { $0 == id }
        }
    }

    public func maskConflicts(for source: Source, in config: Config) -> [Source] {
        guard case let .manualExport(watchPath, filePattern, _, _) = source.kind, !filePattern.isEmpty else { return [] }
        let folder = Paths.url(watchPath).standardizedFileURL
        return config.sources.filter { other in
            guard other.id != source.id,
                  case let .manualExport(otherPath, otherPattern, _, _) = other.kind,
                  !otherPattern.isEmpty,
                  Paths.url(otherPath).standardizedFileURL == folder else { return false }
            return GlobPattern(filePattern).matches(Self.sample(of: otherPattern))
                || GlobPattern(otherPattern).matches(Self.sample(of: filePattern))
        }
    }

    private static func sample(of pattern: String) -> String {
        pattern.replacingOccurrences(of: "*", with: "x").replacingOccurrences(of: "?", with: "x")
    }
}

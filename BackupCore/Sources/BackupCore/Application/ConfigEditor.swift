import Foundation

public struct ConfigEditor: Sendable {
    public init() {}

    public func makeSource(
        name: String,
        steps: [SourceStep],
        schedule: Schedule = .daily,
        retention: RetentionRules = .standard,
        description: String = "",
        instructions: String = "",
        now: Date,
        in config: Config
    ) -> Source {
        Source(
            name: name,
            slug: Slug.make(from: name, existing: Set(config.sources.map(\.slug))),
            steps: steps,
            schedule: schedule,
            retention: retention,
            description: description,
            instructions: instructions,
            createdAt: now
        )
    }

    public func save(_ source: Source, in config: inout Config) {
        var updated = source
        guard let index = config.sources.firstIndex(where: { $0.id == source.id }) else {
            updated.slug = Slug.make(from: source.name, existing: Set(config.sources.map(\.slug)))
            config.sources.append(updated)
            return
        }
        updated.name = config.sources[index].name
        updated.slug = config.sources[index].slug
        config.sources[index] = updated
    }

    public func removeSource(_ id: UUID, from config: inout Config) {
        config.sources.removeAll { $0.id == id }
    }

    /// Sources missing from `ids` (for example, added in the meantime) stay at the end in their previous order.
    public func orderSources(_ ids: [UUID], in config: inout Config) {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        config.sources = config.sources.enumerated()
            .sorted { (rank[$0.element.id] ?? ids.count + $0.offset, $0.offset) < (rank[$1.element.id] ?? ids.count + $1.offset, $1.offset) }
            .map(\.element)
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
        let own = source.watchedFiles.filter { !$0.filePattern.isEmpty }
        guard !own.isEmpty else { return [] }
        return config.sources.filter { other in
            other.id != source.id && other.watchedFiles.contains { theirs in
                !theirs.filePattern.isEmpty && own.contains { Self.overlap($0, theirs) }
            }
        }
    }

    private static func overlap(_ first: WatchedFile, _ second: WatchedFile) -> Bool {
        guard Paths.url(first.watchPath).standardizedFileURL == Paths.url(second.watchPath).standardizedFileURL else { return false }
        return GlobPattern(first.filePattern).matches(sample(of: second.filePattern))
            || GlobPattern(second.filePattern).matches(sample(of: first.filePattern))
    }

    private static func sample(of pattern: String) -> String {
        pattern.replacingOccurrences(of: "*", with: "x").replacingOccurrences(of: "?", with: "x")
    }
}

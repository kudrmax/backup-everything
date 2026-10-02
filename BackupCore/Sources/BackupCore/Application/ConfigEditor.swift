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
            slug: Slug.make(from: name, existing: config.takenSlugs),
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
            updated.slug = Slug.make(from: source.name, existing: config.takenSlugs)
            config.sources.append(updated)
            return
        }
        updated.name = config.sources[index].name
        updated.slug = config.sources[index].slug
        config.sources[index] = updated
    }

    public func removeSource(_ id: UUID, from config: inout Config) {
        guard let removed = config.source(id) else { return }
        config.sources.removeAll { $0.id == id }
        if !config.takenSlugs.contains(removed.slug) {
            config.retiredSlugs.append(removed.slug)
        }
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
        folderKey(first.watchPath) == folderKey(second.watchPath)
            && GlobPattern(first.filePattern).overlaps(GlobPattern(second.filePattern))
    }

    /// Folder names on macOS volumes ignore case and Unicode form: `~/Downloads` and `~/downloads/` are one folder.
    private static func folderKey(_ path: String) -> String {
        Paths.url(path).resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

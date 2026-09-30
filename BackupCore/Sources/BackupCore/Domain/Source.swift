import Foundation

public struct Source: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var slug: String
    public var steps: [SourceStep]
    public var schedule: Schedule
    public var retention: RetentionRules
    public var destinationIds: [UUID]
    public var description: String
    public var instructions: String
    public var icon: String?
    public var enabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        steps: [SourceStep],
        schedule: Schedule,
        retention: RetentionRules = .standard,
        destinationIds: [UUID] = [],
        description: String = "",
        instructions: String = "",
        icon: String? = nil,
        enabled: Bool = true,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.steps = steps
        self.schedule = schedule
        self.retention = retention
        self.destinationIds = destinationIds
        self.description = description
        self.instructions = instructions
        self.icon = icon
        self.enabled = enabled
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, slug, steps, schedule, retention, destinationIds, description, instructions, icon, enabled, createdAt
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        schedule = try container.decode(Schedule.self, forKey: .schedule)
        retention = try container.decode(RetentionRules.self, forKey: .retention)
        destinationIds = try container.decode([UUID].self, forKey: .destinationIds)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        instructions = try container.decode(String.self, forKey: .instructions)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        if let steps = try container.decodeIfPresent([SourceStep].self, forKey: .steps) {
            self.steps = steps
        } else {
            let legacy = try container.decode(LegacySourceKind.self, forKey: .kind)
            (steps, instructions) = legacy.converted(owner: id, instructions: instructions)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(slug, forKey: .slug)
        try container.encode(steps, forKey: .steps)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(retention, forKey: .retention)
        try container.encode(destinationIds, forKey: .destinationIds)
        try container.encode(description, forKey: .description)
        try container.encode(instructions, forKey: .instructions)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Хотя бы один шаг делает человек: результат нельзя собрать заново, поэтому он хранится в pending до доставки.
    public var needsHuman: Bool {
        steps.contains(where: \.needsHuman)
    }

    /// Источник из одной папки отдаёт её как есть, без промежуточной копии.
    public var singleFolder: (path: String, excludes: [String])? {
        guard steps.count == 1, case let .folder(path, excludes) = steps[0].kind else { return nil }
        return (path, excludes)
    }

    public var watchedFiles: [WatchedFile] {
        steps.compactMap { step in
            guard case let .file(_, watchPath, filePattern, _, _, _) = step.kind else { return nil }
            return WatchedFile(watchPath: watchPath, filePattern: filePattern)
        }
    }

    public var hasDevice: Bool {
        steps.contains { if case .device = $0.kind { true } else { false } }
    }

    /// Оригиналы файлов, забранных у человека, после доставки уходят в Корзину, а не удаляются.
    public var trashesPickedUpFiles: Bool {
        steps.contains { if case let .file(_, _, _, _, _, removeOriginal) = $0.kind { removeOriginal } else { false } }
    }
}

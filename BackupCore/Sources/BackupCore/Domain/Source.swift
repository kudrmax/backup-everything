import Foundation

public enum FileMode: String, Codable, Sendable, CaseIterable {
    case single
    case multiple
}

public enum SourceKind: Codable, Sendable, Equatable {
    case folder(path: String, excludes: [String])
    case command(command: String, timeoutSeconds: Int)
    case manualExport(watchPath: String, filePattern: String, fileMode: FileMode, removeOriginal: Bool)
}

public struct Source: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var slug: String
    public var kind: SourceKind
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
        kind: SourceKind,
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
        self.kind = kind
        self.schedule = schedule
        self.retention = retention
        self.destinationIds = destinationIds
        self.description = description
        self.instructions = instructions
        self.icon = icon
        self.enabled = enabled
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        kind = try container.decode(SourceKind.self, forKey: .kind)
        schedule = try container.decode(Schedule.self, forKey: .schedule)
        retention = try container.decode(RetentionRules.self, forKey: .retention)
        destinationIds = try container.decode([UUID].self, forKey: .destinationIds)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        instructions = try container.decode(String.self, forKey: .instructions)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public var isManualExport: Bool {
        if case .manualExport = kind { return true }
        return false
    }
}

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
    public var instructions: String
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
        instructions: String = "",
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
        self.instructions = instructions
        self.enabled = enabled
        self.createdAt = createdAt
    }

    public var isManualExport: Bool {
        if case .manualExport = kind { return true }
        return false
    }
}

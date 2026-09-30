import Foundation

public struct SourceTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: SourceKind
    public var schedule: Schedule
    public var retention: RetentionRules
    public var description: String
    public var instructions: String

    public init(
        id: String,
        name: String,
        kind: SourceKind,
        schedule: Schedule,
        retention: RetentionRules,
        description: String,
        instructions: String
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.schedule = schedule
        self.retention = retention
        self.description = description
        self.instructions = instructions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(SourceKind.self, forKey: .kind)
        schedule = try container.decode(Schedule.self, forKey: .schedule)
        retention = try container.decode(RetentionRules.self, forKey: .retention)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        instructions = try container.decode(String.self, forKey: .instructions)
    }
}

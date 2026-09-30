import Foundation

public struct SourceTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var steps: [SourceStep]
    public var schedule: Schedule
    public var retention: RetentionRules
    public var description: String
    public var instructions: String

    public init(
        id: String,
        name: String,
        steps: [SourceStep],
        schedule: Schedule,
        retention: RetentionRules,
        description: String,
        instructions: String
    ) {
        self.id = id
        self.name = name
        self.steps = steps
        self.schedule = schedule
        self.retention = retention
        self.description = description
        self.instructions = instructions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, steps, schedule, retention, description, instructions
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        schedule = try container.decode(Schedule.self, forKey: .schedule)
        retention = try container.decode(RetentionRules.self, forKey: .retention)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        instructions = try container.decode(String.self, forKey: .instructions)
        if let steps = try container.decodeIfPresent([SourceStep].self, forKey: .steps) {
            self.steps = steps
        } else {
            let legacy = try container.decode(LegacySourceKind.self, forKey: .kind)
            (steps, instructions) = legacy.converted(owner: UUID(), instructions: instructions)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(steps, forKey: .steps)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(retention, forKey: .retention)
        try container.encode(description, forKey: .description)
        try container.encode(instructions, forKey: .instructions)
    }
}

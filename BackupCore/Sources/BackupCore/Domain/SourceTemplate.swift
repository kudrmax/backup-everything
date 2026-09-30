import Foundation

public struct SourceTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: SourceKind
    public var schedule: Schedule
    public var retention: RetentionRules
    public var instructions: String

    public init(id: String, name: String, kind: SourceKind, schedule: Schedule, retention: RetentionRules, instructions: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.schedule = schedule
        self.retention = retention
        self.instructions = instructions
    }
}

import Foundation

public enum StepKind: Codable, Sendable, Equatable {
    case manual(instructions: String, watchPath: String, filePattern: String, includeInCopy: Bool)
    case command(command: String, timeoutSeconds: Int)
}

public struct SourceStep: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: StepKind

    public init(id: UUID = UUID(), name: String, kind: StepKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var isManual: Bool {
        if case .manual = kind { return true }
        return false
    }
}

public struct WatchedFile: Sendable, Equatable {
    public let watchPath: String
    public let filePattern: String

    public init(watchPath: String, filePattern: String) {
        self.watchPath = watchPath
        self.filePattern = filePattern
    }
}

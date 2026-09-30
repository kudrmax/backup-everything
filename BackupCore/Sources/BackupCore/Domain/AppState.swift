import Foundation

public struct SourceState: Codable, Sendable, Equatable {
    public var lastRun: Date?
    public var lastPickup: Date?
    public var lastError: String?
    public var retryAfter: Date?

    public init(lastRun: Date? = nil, lastPickup: Date? = nil, lastError: String? = nil, retryAfter: Date? = nil) {
        self.lastRun = lastRun
        self.lastPickup = lastPickup
        self.lastError = lastError
        self.retryAfter = retryAfter
    }
}

public struct DestinationState: Codable, Sendable, Equatable {
    public var lastCaughtUp: Date?

    public init(lastCaughtUp: Date? = nil) {
        self.lastCaughtUp = lastCaughtUp
    }
}

public struct Debt: Codable, Sendable, Equatable {
    public var sourceId: UUID
    public var destinationId: UUID
    public var since: Date
    public var lastAttempt: Date?

    public init(sourceId: UUID, destinationId: UUID, since: Date, lastAttempt: Date? = nil) {
        self.sourceId = sourceId
        self.destinationId = destinationId
        self.since = since
        self.lastAttempt = lastAttempt
    }
}

public struct AppState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sources: [String: SourceState]
    public var destinations: [String: DestinationState]
    public var debts: [Debt]
    public var lastReminders: [String: Date]

    public init() {
        self.schemaVersion = Self.currentSchemaVersion
        self.sources = [:]
        self.destinations = [:]
        self.debts = []
        self.lastReminders = [:]
    }

    public func sourceState(_ id: UUID) -> SourceState {
        sources[id.uuidString] ?? SourceState()
    }

    public mutating func updateSource(_ id: UUID, _ change: (inout SourceState) -> Void) {
        var value = sourceState(id)
        change(&value)
        sources[id.uuidString] = value
    }

    public func destinationState(_ id: UUID) -> DestinationState {
        destinations[id.uuidString] ?? DestinationState()
    }

    public mutating func updateDestination(_ id: UUID, _ change: (inout DestinationState) -> Void) {
        var value = destinationState(id)
        change(&value)
        destinations[id.uuidString] = value
    }

    public func debts(forDestination id: UUID) -> [Debt] {
        debts.filter { $0.destinationId == id }
    }
}

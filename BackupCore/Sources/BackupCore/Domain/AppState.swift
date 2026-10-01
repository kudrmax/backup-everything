import Foundation

/// Кто начал запуск: от этого зависит, жёлто ли напоминать о шаге человека или спокойно ждать.
public enum RunStart: String, Codable, Sendable {
    case schedule
    case button
}

public struct ChainState: Codable, Sendable, Equatable {
    public var stepIndex: Int
    public var stepId: UUID?
    public var startedAt: Date
    public var stepEnteredAt: Date
    public var failure: String?
    public var startedBy: RunStart?
    public var retryAfter: Date?

    public init(
        stepIndex: Int,
        stepId: UUID? = nil,
        startedAt: Date,
        stepEnteredAt: Date,
        failure: String? = nil,
        startedBy: RunStart? = nil,
        retryAfter: Date? = nil
    ) {
        self.stepIndex = stepIndex
        self.stepId = stepId
        self.startedAt = startedAt
        self.stepEnteredAt = stepEnteredAt
        self.failure = failure
        self.startedBy = startedBy
        self.retryAfter = retryAfter
    }
}

public struct SourceState: Codable, Sendable, Equatable {
    public var lastRun: Date?
    public var lastSuccess: Date?
    public var lastPickup: Date?
    public var lastError: String?
    public var retryAfter: Date?
    public var chain: ChainState?
    public var armedAt: Date?

    public init(
        lastRun: Date? = nil,
        lastSuccess: Date? = nil,
        lastPickup: Date? = nil,
        lastError: String? = nil,
        retryAfter: Date? = nil,
        chain: ChainState? = nil,
        armedAt: Date? = nil
    ) {
        self.lastRun = lastRun
        self.lastSuccess = lastSuccess
        self.lastPickup = lastPickup
        self.lastError = lastError
        self.retryAfter = retryAfter
        self.chain = chain
        self.armedAt = armedAt
    }
}

public struct DestinationState: Codable, Sendable, Equatable {
    public var lastCaughtUp: Date?
    public var lastVerified: Date?

    public init(lastCaughtUp: Date? = nil, lastVerified: Date? = nil) {
        self.lastCaughtUp = lastCaughtUp
        self.lastVerified = lastVerified
    }
}

public struct Debt: Codable, Sendable, Equatable {
    public var sourceId: UUID
    public var destinationId: UUID
    public var since: Date
    public var lastAttempt: Date?
    /// Каждый пропущенный бэкап есть на другом назначении. Если хоть один нигде больше нет — диск нужен сразу, а не к своему сроку.
    public var elsewhere: Bool

    public init(sourceId: UUID, destinationId: UUID, since: Date, lastAttempt: Date? = nil, elsewhere: Bool = true) {
        self.sourceId = sourceId
        self.destinationId = destinationId
        self.since = since
        self.lastAttempt = lastAttempt
        self.elsewhere = elsewhere
    }

    private enum CodingKeys: String, CodingKey {
        case sourceId, destinationId, since, lastAttempt, elsewhere
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try container.decode(UUID.self, forKey: .sourceId)
        destinationId = try container.decode(UUID.self, forKey: .destinationId)
        since = try container.decode(Date.self, forKey: .since)
        lastAttempt = try container.decodeIfPresent(Date.self, forKey: .lastAttempt)
        elsewhere = try container.decodeIfPresent(Bool.self, forKey: .elsewhere) ?? true
    }
}

public struct AppState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sources: [String: SourceState]
    public var destinations: [String: DestinationState]
    public var debts: [Debt]
    public var lastReminders: [String: Date]
    public var lastDelivered: [String: String]

    public init() {
        self.schemaVersion = Self.currentSchemaVersion
        self.sources = [:]
        self.destinations = [:]
        self.debts = []
        self.lastReminders = [:]
        self.lastDelivered = [:]
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sources = try container.decodeIfPresent([String: SourceState].self, forKey: .sources) ?? [:]
        destinations = try container.decodeIfPresent([String: DestinationState].self, forKey: .destinations) ?? [:]
        debts = try container.decodeIfPresent([Debt].self, forKey: .debts) ?? []
        lastReminders = try container.decodeIfPresent([String: Date].self, forKey: .lastReminders) ?? [:]
        lastDelivered = try container.decodeIfPresent([String: String].self, forKey: .lastDelivered) ?? [:]
    }

    public static func deliveryKey(sourceId: UUID, destinationId: UUID) -> String {
        "\(sourceId.uuidString)|\(destinationId.uuidString)"
    }

    public func lastDeliveredSnapshot(sourceId: UUID, destinationId: UUID) -> String? {
        lastDelivered[Self.deliveryKey(sourceId: sourceId, destinationId: destinationId)]
    }

    public func hasDebt(sourceId: UUID, destinationId: UUID) -> Bool {
        debts.contains { $0.sourceId == sourceId && $0.destinationId == destinationId }
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

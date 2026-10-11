import Foundation

/// Who started the run: this decides whether to remind about a manual step in yellow or wait calmly.
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
    /// The result folder when the current step began; `nil` in state saved by older versions, which did not record it.
    public var outputAtStepEntry: [String]?
    /// The result folder when the last device step passed: if the device is unplugged mid-copy, every step after it runs
    /// again from there. `nil` before any device step and in state saved by older versions.
    public var outputAtDeviceStep: [String]?
    /// Whether `outputAtStepEntry` / `outputAtDeviceStep` list every name. `nil` in state saved by versions that listed
    /// the folder through Foundation, which leaves out names starting with “._”.
    public var outputAtStepEntryIsComplete: Bool?
    public var outputAtDeviceStepIsComplete: Bool?

    public init(
        stepIndex: Int,
        stepId: UUID? = nil,
        startedAt: Date,
        stepEnteredAt: Date,
        failure: String? = nil,
        startedBy: RunStart? = nil,
        retryAfter: Date? = nil,
        outputAtStepEntry: [String]? = [],
        outputAtDeviceStep: [String]? = nil,
        outputAtStepEntryIsComplete: Bool? = true,
        outputAtDeviceStepIsComplete: Bool? = true
    ) {
        self.stepIndex = stepIndex
        self.stepId = stepId
        self.startedAt = startedAt
        self.stepEnteredAt = stepEnteredAt
        self.failure = failure
        self.startedBy = startedBy
        self.retryAfter = retryAfter
        self.outputAtStepEntry = outputAtStepEntry
        self.outputAtDeviceStep = outputAtDeviceStep
        self.outputAtStepEntryIsComplete = outputAtStepEntryIsComplete
        self.outputAtDeviceStepIsComplete = outputAtDeviceStepIsComplete
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

public struct CachedCopy: Codable, Sendable, Equatable {
    public var name: String
    public var date: Date

    public init(name: String, date: Date) {
        self.name = name
        self.date = date
    }
}

/// What the copies of a source on a destination looked like when the destination was last reachable. For showing and
/// reminding while the destination is away; never a ground for writing.
public struct CopyCacheEntry: Codable, Sendable, Equatable {
    public var copies: [CachedCopy]
    public var seenAt: Date

    public init(copies: [CachedCopy], seenAt: Date) {
        self.copies = copies
        self.seenAt = seenAt
    }

    public var newest: Date? { copies.map(\.date).max() }
}

public struct AppState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var sources: [String: SourceState]
    public var lastReminders: [String: Date]
    public var copyCache: [String: CopyCacheEntry]

    public init() {
        schemaVersion = Self.currentSchemaVersion
        sources = [:]
        lastReminders = [:]
        copyCache = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sources, lastReminders, copyCache
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sources = try container.decodeIfPresent([String: SourceState].self, forKey: .sources) ?? [:]
        lastReminders = try container.decodeIfPresent([String: Date].self, forKey: .lastReminders) ?? [:]
        copyCache = try container.decodeIfPresent([String: CopyCacheEntry].self, forKey: .copyCache) ?? [:]
    }

    public static func deliveryKey(sourceId: UUID, destinationId: UUID) -> String {
        "\(sourceId.uuidString)|\(destinationId.uuidString)"
    }

    public func sourceState(_ id: UUID) -> SourceState {
        sources[id.uuidString] ?? SourceState()
    }

    public mutating func updateSource(_ id: UUID, _ change: (inout SourceState) -> Void) {
        var value = sourceState(id)
        change(&value)
        sources[id.uuidString] = value
    }

    public func cachedCopies(sourceId: UUID, destinationId: UUID) -> CopyCacheEntry? {
        copyCache[Self.deliveryKey(sourceId: sourceId, destinationId: destinationId)]
    }

    public func newestCopyDate(sourceId: UUID, destinationId: UUID) -> Date? {
        cachedCopies(sourceId: sourceId, destinationId: destinationId)?.newest
    }

    public mutating func recordCopies(sourceId: UUID, destinationId: UUID, _ copies: [Snapshot], seenAt: Date) {
        copyCache[Self.deliveryKey(sourceId: sourceId, destinationId: destinationId)] = CopyCacheEntry(
            copies: copies.map { CachedCopy(name: $0.name, date: $0.date) },
            seenAt: seenAt
        )
    }
}

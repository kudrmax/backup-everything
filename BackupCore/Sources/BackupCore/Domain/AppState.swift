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

public struct DestinationState: Codable, Sendable, Equatable {
    public var lastCaughtUp: Date?
    public var lastVerified: Date?
    /// The place the facts about this destination's copies were learned at; `nil` until the state is first reconciled
    /// with the settings (`StateReducer.reconcile`).
    public var location: DestinationLocation?

    public init(lastCaughtUp: Date? = nil, lastVerified: Date? = nil, location: DestinationLocation? = nil) {
        self.lastCaughtUp = lastCaughtUp
        self.lastVerified = lastVerified
        self.location = location
    }
}

public struct Debt: Codable, Sendable, Equatable {
    public var sourceId: UUID
    public var destinationId: UUID
    public var since: Date
    public var lastAttempt: Date?
    /// Every missed backup exists on another destination. If even one exists nowhere else, the disk is needed right away, not when it is due.
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
    /// When each copy in `lastDelivered` was collected, by `deliveryKey`: the age of the copy that the status is built on.
    /// `nil` in state saved before it was kept; `Store` then learns it from the history (`learningDeliveryDates`).
    public var deliveredAt: [String: Date]?
    /// What went wrong after the last copy was delivered (old copies not cleaned up), by `deliveryKey`; absent when nothing did.
    public var deliveryWarnings: [String: String]
    /// Since when each pair has been expected to hold a copy at the destination's current place, by `deliveryKey`: the
    /// moment the destination was added to the source or moved to another place. `nil` until the state is first
    /// reconciled with the settings; pairs that existed then count from the creation of their source.
    public var expectedSince: [String: Date]?

    public init() {
        self.schemaVersion = Self.currentSchemaVersion
        self.sources = [:]
        self.destinations = [:]
        self.debts = []
        self.lastReminders = [:]
        self.lastDelivered = [:]
        self.deliveredAt = [:]
        self.deliveryWarnings = [:]
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sources = try container.decodeIfPresent([String: SourceState].self, forKey: .sources) ?? [:]
        destinations = try container.decodeIfPresent([String: DestinationState].self, forKey: .destinations) ?? [:]
        debts = try container.decodeIfPresent([Debt].self, forKey: .debts) ?? []
        lastReminders = try container.decodeIfPresent([String: Date].self, forKey: .lastReminders) ?? [:]
        lastDelivered = try container.decodeIfPresent([String: String].self, forKey: .lastDelivered) ?? [:]
        deliveredAt = try container.decodeIfPresent([String: Date].self, forKey: .deliveredAt)
        deliveryWarnings = try container.decodeIfPresent([String: String].self, forKey: .deliveryWarnings) ?? [:]
        expectedSince = try container.decodeIfPresent([String: Date].self, forKey: .expectedSince)
    }

    public static func deliveryKey(sourceId: UUID, destinationId: UUID) -> String {
        "\(sourceId.uuidString)|\(destinationId.uuidString)"
    }

    public func lastDeliveredSnapshot(sourceId: UUID, destinationId: UUID) -> String? {
        lastDelivered[Self.deliveryKey(sourceId: sourceId, destinationId: destinationId)]
    }

    /// When the newest copy of the source on the destination was collected; `nil` when no copy is known to be there.
    public func deliveredCopyDate(sourceId: UUID, destinationId: UUID) -> Date? {
        deliveredAt?[Self.deliveryKey(sourceId: sourceId, destinationId: destinationId)]
    }

    public mutating func recordDelivery(sourceId: UUID, destinationId: UUID, snapshotName: String?, collectedAt: Date) {
        let key = Self.deliveryKey(sourceId: sourceId, destinationId: destinationId)
        if let snapshotName { lastDelivered[key] = snapshotName }
        var dates = deliveredAt ?? [:]
        dates[key] = collectedAt
        deliveredAt = dates
    }

    public mutating func forgetDelivery(sourceId: UUID, destinationId: UUID) {
        let key = Self.deliveryKey(sourceId: sourceId, destinationId: destinationId)
        lastDelivered[key] = nil
        deliveredAt?[key] = nil
    }

    /// Everything known about copies at the destination: which copy is there, how old it is, what went wrong after it,
    /// when it was last caught up and checked.
    public mutating func forgetCopies(at destinationId: UUID) {
        let suffix = "|" + destinationId.uuidString
        lastDelivered = lastDelivered.filter { !$0.key.hasSuffix(suffix) }
        deliveredAt = deliveredAt?.filter { !$0.key.hasSuffix(suffix) }
        deliveryWarnings = deliveryWarnings.filter { !$0.key.hasSuffix(suffix) }
        updateDestination(destinationId) {
            $0.lastCaughtUp = nil
            $0.lastVerified = nil
        }
    }

    /// Whether anything is known about copies at the destination: what `forgetCopies` forgets.
    public func knowsCopies(at destinationId: UUID) -> Bool {
        let suffix = "|" + destinationId.uuidString
        let destination = destinationState(destinationId)
        return lastDelivered.keys.contains { $0.hasSuffix(suffix) }
            || (deliveredAt ?? [:]).keys.contains { $0.hasSuffix(suffix) }
            || deliveryWarnings.keys.contains { $0.hasSuffix(suffix) }
            || destination.lastCaughtUp != nil
            || destination.lastVerified != nil
    }

    /// Since when the source has been expected to hold a copy at the destination's current place; `nil` when not recorded.
    public func copyExpectedSince(sourceId: UUID, destinationId: UUID) -> Date? {
        expectedSince?[Self.deliveryKey(sourceId: sourceId, destinationId: destinationId)]
    }

    /// State saved before `deliveredAt` was kept learns the dates from the history: the run that delivered the copy named in
    /// `lastDelivered`, else the date in its name (5.3.1). A date is a fact about a copy that is there now, so it is learned
    /// only for a pair whose copy is named in `lastDelivered`: the check forgets the name of a copy it finds missing. An
    /// open debt says a newer copy is owed, not that the named one is gone, so it does not hold the date back. Pairs
    /// without a name get their date from the check of the destination, which looks at the copies themselves. Facts at a
    /// place where copies cannot be proven are forgotten when the state is reconciled (`StateReducer.reconcile`).
    public func learningDeliveryDates(from history: [RunRecord], naming: SnapshotNaming) -> AppState {
        guard deliveredAt == nil else { return self }
        let named = lastDelivered
        var dates: [String: Date] = [:]
        for run in history.sorted(by: { $0.startedAt > $1.startedAt }) {
            for delivery in run.deliveries where delivery.outcome.isDelivered {
                let key = Self.deliveryKey(sourceId: run.sourceId, destinationId: delivery.destinationId)
                guard dates[key] == nil, let expected = named[key], expected == run.snapshotName else { continue }
                dates[key] = run.copyCollectedAt
            }
        }
        for (key, name) in named where dates[key] == nil {
            guard let date = naming.date(from: name) else { continue }
            let sourceId = key.split(separator: "|").first.flatMap { UUID(uuidString: String($0)) }
            let lastSuccess = sourceId.flatMap { sourceState($0).lastSuccess }
            dates[key] = min(date, lastSuccess ?? date)
        }
        var learned = self
        learned.deliveredAt = dates
        return learned
    }

    /// What went wrong after the last copies of the source were delivered to its destinations.
    public func deliveryWarnings(of source: Source) -> [String] {
        var warnings: [String] = []
        for destinationId in source.destinationIds {
            guard let warning = deliveryWarnings[Self.deliveryKey(sourceId: source.id, destinationId: destinationId)],
                  !warnings.contains(warning) else { continue }
            warnings.append(warning)
        }
        return warnings
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

    /// Debts of a disabled source wait for it to be enabled again: until then nothing pays them, so they neither show nor remind.
    public func pausingDisabledSources(of config: Config) -> AppState {
        var active = self
        active.debts.removeAll { debt in config.source(debt.sourceId).map { !$0.enabled } ?? false }
        return active
    }
}

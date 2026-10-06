import Foundation

public enum RunTrigger: String, Codable, Sendable {
    case scheduled
    case manual
    case catchUp
    case pickup
}

public enum DeliveryOutcome: Codable, Sendable, Equatable {
    case delivered(pruned: Int, warning: String?)
    case unavailable
    case failed(message: String)

    public var isDelivered: Bool {
        if case .delivered = self { return true }
        return false
    }

    /// The same outcome with one more problem told about it. An undelivered copy keeps its reason first.
    func adding(_ problem: String) -> DeliveryOutcome {
        switch self {
        case let .delivered(pruned, warning):
            .delivered(pruned: pruned, warning: warning.map { "\($0) \(problem)" } ?? problem)
        case let .failed(message):
            .failed(message: "\(message) \(problem)")
        case .unavailable:
            .unavailable
        }
    }
}

public struct Delivery: Codable, Sendable, Equatable {
    public var destinationId: UUID
    public var destinationName: String
    public var outcome: DeliveryOutcome

    public init(destinationId: UUID, destinationName: String, outcome: DeliveryOutcome) {
        self.destinationId = destinationId
        self.destinationName = destinationName
        self.outcome = outcome
    }
}

public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sourceId: UUID
    public var sourceName: String
    public var trigger: RunTrigger
    public var startedAt: Date
    public var finishedAt: Date
    public var snapshotName: String?
    public var collectedAt: Date?
    public var fileCount: Int?
    public var totalBytes: Int64?
    public var collectError: String?
    public var details: String?
    /// Catch-up with a ready copy: the name of the destination it was taken from. The source was not gathered.
    public var copiedFrom: String?
    /// A catch-up that delivered a copy made earlier (from another destination or `pending`) instead of gathering the source now.
    public var deliversAnOlderCopy: Bool
    public var deliveries: [Delivery]

    public init(
        id: UUID = UUID(),
        sourceId: UUID,
        sourceName: String,
        trigger: RunTrigger,
        startedAt: Date,
        finishedAt: Date,
        snapshotName: String? = nil,
        collectedAt: Date? = nil,
        fileCount: Int? = nil,
        totalBytes: Int64? = nil,
        collectError: String? = nil,
        details: String? = nil,
        copiedFrom: String? = nil,
        deliversAnOlderCopy: Bool = false,
        deliveries: [Delivery] = []
    ) {
        self.id = id
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.snapshotName = snapshotName
        self.collectedAt = collectedAt
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.collectError = collectError
        self.details = details
        self.copiedFrom = copiedFrom
        self.deliversAnOlderCopy = deliversAnOlderCopy
        self.deliveries = deliveries
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceId, sourceName, trigger, startedAt, finishedAt, snapshotName, collectedAt, fileCount, totalBytes
        case collectError, details, copiedFrom, deliversAnOlderCopy, deliveries
    }

    /// History written before `deliversAnOlderCopy` knows for sure only about copies taken from another destination.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceId = try container.decode(UUID.self, forKey: .sourceId)
        sourceName = try container.decode(String.self, forKey: .sourceName)
        trigger = try container.decode(RunTrigger.self, forKey: .trigger)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        snapshotName = try container.decodeIfPresent(String.self, forKey: .snapshotName)
        collectedAt = try container.decodeIfPresent(Date.self, forKey: .collectedAt)
        fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount)
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes)
        collectError = try container.decodeIfPresent(String.self, forKey: .collectError)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        copiedFrom = try container.decodeIfPresent(String.self, forKey: .copiedFrom)
        deliversAnOlderCopy = try container.decodeIfPresent(Bool.self, forKey: .deliversAnOlderCopy) ?? (copiedFrom != nil)
        deliveries = try container.decode([Delivery].self, forKey: .deliveries)
    }

    /// When the delivered copy was collected. A name read in another time zone can put the copy after the run; it was made
    /// no later than the run ended.
    public var copyCollectedAt: Date {
        min(collectedAt ?? startedAt, finishedAt)
    }

    public var firstFailure: String? {
        if let collectError { return collectError }
        for delivery in deliveries {
            if case let .failed(message) = delivery.outcome { return message }
        }
        return nil
    }

    public var isDeferredOnly: Bool {
        collectError == nil && !deliveries.isEmpty && deliveries.allSatisfy { $0.outcome == .unavailable }
    }
}

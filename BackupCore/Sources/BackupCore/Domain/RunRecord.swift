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
        self.deliveries = deliveries
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

    /// A catch-up that delivered a copy made earlier (from another destination or `pending`) instead of gathering the source now.
    public var deliversAnOlderCopy: Bool {
        trigger == .catchUp && (collectedAt.map { $0 < startedAt } ?? true)
    }
}

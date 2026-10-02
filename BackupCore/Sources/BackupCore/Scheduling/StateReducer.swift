import Foundation

public struct StateReducer: Sendable {
    public init() {}

    public func apply(_ record: RunRecord, to state: inout AppState, config: Config) {
        if let collectError = record.collectError {
            state.updateSource(record.sourceId) {
                $0.lastError = collectError
                $0.retryAfter = record.finishedAt.addingTimeInterval(SchedulePlanner.retryInterval)
            }
            for index in state.debts.indices where state.debts[index].sourceId == record.sourceId {
                state.debts[index].lastAttempt = record.finishedAt
            }
            return
        }
        for delivery in record.deliveries {
            let key = AppState.deliveryKey(sourceId: record.sourceId, destinationId: delivery.destinationId)
            switch delivery.outcome {
            case let .delivered(_, warning):
                state.debts.removeAll { $0.sourceId == record.sourceId && $0.destinationId == delivery.destinationId }
                if let snapshotName = record.snapshotName {
                    state.lastDelivered[key] = snapshotName
                }
                state.deliveryWarnings[key] = warning
            case .unavailable:
                upsertDebt(record, delivery, attemptedAt: nil, in: &state)
            case .failed:
                upsertDebt(record, delivery, attemptedAt: record.finishedAt, in: &state)
            }
        }
        let active = state.pausingDisabledSources(of: config)
        for delivery in record.deliveries where delivery.outcome.isDelivered {
            if active.debts(forDestination: delivery.destinationId).isEmpty {
                state.updateDestination(delivery.destinationId) { $0.lastCaughtUp = record.finishedAt }
            }
        }
        state.updateSource(record.sourceId) {
            // An older copy says nothing about a collection that keeps failing.
            if $0.retryAfter == nil || !record.deliversAnOlderCopy {
                $0.lastError = record.firstFailure
                $0.retryAfter = nil
            }
            if record.deliveries.contains(where: \.outcome.isDelivered) {
                // A name read in another time zone can put the copy after the run; it was made no later than the run ended.
                let collectedAt = min(record.collectedAt ?? record.startedAt, record.finishedAt)
                $0.lastSuccess = max($0.lastSuccess ?? .distantPast, collectedAt)
            }
            if record.trigger != .catchUp { $0.lastRun = record.startedAt }
        }
    }

    public func dropOrphans(config: Config, state: inout AppState) {
        state.debts.removeAll { debt in
            guard let source = config.source(debt.sourceId) else { return true }
            return config.destination(debt.destinationId) == nil || !source.destinationIds.contains(debt.destinationId)
        }
        let sourceKeys = Set(config.sources.map(\.id.uuidString))
        let destinationKeys = Set(config.destinations.map(\.id.uuidString))
        state.sources = state.sources.filter { sourceKeys.contains($0.key) }
        state.destinations = state.destinations.filter { destinationKeys.contains($0.key) }
        let pairs = Set(config.sources.flatMap { source in
            source.destinationIds.map { AppState.deliveryKey(sourceId: source.id, destinationId: $0) }
        })
        state.lastDelivered = state.lastDelivered.filter { pairs.contains($0.key) }
        state.deliveryWarnings = state.deliveryWarnings.filter { pairs.contains($0.key) }
    }

    private func upsertDebt(_ record: RunRecord, _ delivery: Delivery, attemptedAt: Date?, in state: inout AppState) {
        let elsewhere = record.deliveries.contains { $0.destinationId != delivery.destinationId && $0.outcome.isDelivered }
        if let index = state.debts.firstIndex(where: { $0.sourceId == record.sourceId && $0.destinationId == delivery.destinationId }) {
            if let attemptedAt { state.debts[index].lastAttempt = attemptedAt }
            if record.trigger != .catchUp { state.debts[index].elsewhere = state.debts[index].elsewhere && elsewhere }
        } else {
            state.debts.append(Debt(
                sourceId: record.sourceId,
                destinationId: delivery.destinationId,
                since: record.startedAt,
                lastAttempt: attemptedAt,
                elsewhere: elsewhere
            ))
        }
    }
}

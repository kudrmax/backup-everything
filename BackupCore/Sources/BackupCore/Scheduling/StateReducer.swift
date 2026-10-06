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
                state.recordDelivery(
                    sourceId: record.sourceId,
                    destinationId: delivery.destinationId,
                    snapshotName: record.snapshotName,
                    collectedAt: record.copyCollectedAt
                )
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
                $0.lastSuccess = max($0.lastSuccess ?? .distantPast, record.copyCollectedAt)
            }
            if record.trigger != .catchUp { $0.lastRun = record.startedAt }
        }
    }

    /// Brings the state in line with the settings before anything is judged or done by it. Facts belong to a place: when a
    /// destination now points to another folder, remote or disk than the one its facts were learned at, they are forgotten,
    /// so it is checked and caught up and no copy counts there until one is proven. A place where copies cannot be proven
    /// (`unverifiable`: a folder on an external disk that no disk is confirmed for, so any disk may be there) holds no
    /// facts at all: those an older version left there are forgotten in the same way. Each pair remembers since when it is
    /// expected to hold a copy: pairs present at the first reconciliation since their source was created, later ones since
    /// they appeared or the facts of their destination were forgotten.
    public func reconcile(config: Config, state: inout AppState, now: Date, unverifiable: Set<UUID>) {
        dropOrphans(config: config, state: &state)
        let isFirst = state.expectedSince == nil
        var since = state.expectedSince ?? [:]
        for destination in config.destinations {
            let recorded = state.destinationState(destination.id).location
            let moved = recorded != nil && recorded != destination.location
            let unproven = unverifiable.contains(destination.id) && state.knowsCopies(at: destination.id)
            if moved || unproven {
                state.forgetCopies(at: destination.id)
                for source in config.sources where source.destinationIds.contains(destination.id) {
                    since[AppState.deliveryKey(sourceId: source.id, destinationId: destination.id)] = now
                }
            }
            if recorded != destination.location {
                state.updateDestination(destination.id) { $0.location = destination.location }
            }
        }
        for source in config.sources {
            for destination in config.destinations(of: source) {
                let key = AppState.deliveryKey(sourceId: source.id, destinationId: destination.id)
                if since[key] == nil { since[key] = isFirst ? source.createdAt : now }
            }
        }
        state.expectedSince = since
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
            config.destinations(of: source).map { AppState.deliveryKey(sourceId: source.id, destinationId: $0.id) }
        })
        state.expectedSince = state.expectedSince?.filter { pairs.contains($0.key) }
        state.lastDelivered = state.lastDelivered.filter { pairs.contains($0.key) }
        state.deliveredAt = state.deliveredAt?.filter { pairs.contains($0.key) }
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

import Foundation

public struct StateReducer: Sendable {
    public init() {}

    /// What a run says about its source: when it ran, when it last succeeded, what failed and when to try again.
    /// Nothing about copies: those are read from the destinations. Delivering a package from pending later is not a run of
    /// the source, so it leaves the last run, and with it the schedule, where it was.
    public func apply(_ record: RunRecord, to state: inout AppState) {
        state.updateSource(record.sourceId) {
            if record.trigger != .catchUp { $0.lastRun = record.startedAt }
            if let failure = record.firstFailure {
                $0.lastError = failure
                $0.retryAfter = record.finishedAt.addingTimeInterval(SchedulePlanner.retryInterval)
            } else {
                $0.lastError = nil
                $0.retryAfter = nil
            }
            if record.deliveries.contains(where: \.outcome.isDelivered) {
                $0.lastSuccess = max($0.lastSuccess ?? .distantPast, record.copyCollectedAt)
            }
        }
    }

    public func dropOrphans(config: Config, state: inout AppState) {
        let sourceKeys = Set(config.sources.map(\.id.uuidString))
        state.sources = state.sources.filter { sourceKeys.contains($0.key) }
        let pairs = Set(config.sources.flatMap { source in
            config.destinations(of: source).map { AppState.deliveryKey(sourceId: source.id, destinationId: $0.id) }
        })
        state.copyCache = state.copyCache.filter { pairs.contains($0.key) }
    }
}

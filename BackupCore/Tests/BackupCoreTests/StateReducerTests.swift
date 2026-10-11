import Foundation
import Testing
@testable import BackupCore

struct StateReducerTests {
    private let reducer = StateReducer()
    private let sourceId = UUID()
    private let disk = UUID()
    private let cloud = UUID()
    private let started = Fixtures.date("2026-09-28 10:00:00")
    private let finished = Fixtures.date("2026-09-28 10:05:00")

    private func record(_ outcomes: [(UUID, DeliveryOutcome)], trigger: RunTrigger = .scheduled, collectError: String? = nil) -> RunRecord {
        RunRecord(
            sourceId: sourceId,
            sourceName: "Obsidian",
            trigger: trigger,
            startedAt: started,
            finishedAt: finished,
            collectError: collectError,
            deliveries: outcomes.map { Delivery(destinationId: $0.0, destinationName: "d", outcome: $0.1) }
        )
    }

    @Test func collectFailureSchedulesARetryInAnHour() {
        var state = AppState()
        reducer.apply(record([], collectError: "auth"), to: &state)
        #expect(state.sourceState(sourceId) == SourceState(lastRun: started, lastError: "auth", retryAfter: finished.addingTimeInterval(3600)))
    }

    @Test func failedWriteSchedulesARetryToo() {
        var state = AppState()
        reducer.apply(record([(disk, .failed(message: "I/O error")), (cloud, .delivered(pruned: 0, warning: nil))]), to: &state)
        #expect(state.sourceState(sourceId).lastError == "I/O error")
        #expect(state.sourceState(sourceId).retryAfter == finished.addingTimeInterval(3600))
        #expect(state.sourceState(sourceId).lastSuccess == started)
    }

    @Test func successfulDeliveryClearsTheErrorAndSetsLastSuccess() {
        var state = AppState()
        reducer.apply(record([], collectError: "auth"), to: &state)
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil)), (cloud, .unavailable)]), to: &state)
        #expect(state.sourceState(sourceId) == SourceState(lastRun: started, lastSuccess: started))
    }

    @Test func deferredOrFailedRunsDoNotCountAsSuccess() {
        var state = AppState()
        reducer.apply(record([(disk, .unavailable)]), to: &state)
        reducer.apply(record([], collectError: "auth"), to: &state)
        #expect(state.sourceState(sourceId).lastSuccess == nil)
    }

    /// A copy collected earlier than the last success does not move it back.
    @Test func lastSuccessNeverMovesBack() {
        var state = AppState()
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil))]), to: &state)
        var older = record([(disk, .delivered(pruned: 0, warning: nil))], trigger: .pickup)
        older.collectedAt = started.addingTimeInterval(-86_400)
        reducer.apply(older, to: &state)
        #expect(state.sourceState(sourceId).lastSuccess == started)
    }

    /// Delivering a package from pending later is not a run of the source: its schedule stays where it was.
    @Test func lateDeliveryOfAPendingPackageLeavesTheLastRun() {
        var state = AppState()
        let earlier = Fixtures.date("2026-09-20 10:00:00")
        state.updateSource(sourceId) { $0.lastRun = earlier }
        reducer.apply(record([(disk, .failed(message: "I/O error"))], trigger: .catchUp), to: &state)
        #expect(state.sourceState(sourceId) == SourceState(lastRun: earlier, lastError: "I/O error", retryAfter: finished.addingTimeInterval(3600)))
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil))], trigger: .catchUp), to: &state)
        #expect(state.sourceState(sourceId) == SourceState(lastRun: earlier, lastSuccess: started))
    }

    @Test func dropOrphansForgetsSourcesAndCachedPairsTheSettingsNoLongerKnow() {
        let hdd = Fixtures.localDestination("HDD", at: URL(fileURLWithPath: "/unused/hdd"))
        let ssd = Fixtures.localDestination("SSD", at: URL(fileURLWithPath: "/unused/ssd"))
        let kept = Fixtures.source(destinations: [hdd])
        let removed = UUID()
        let config = Config(sources: [kept], destinations: [hdd, ssd])
        var state = AppState()
        state.updateSource(kept.id) { $0.lastRun = started }
        state.updateSource(removed) { $0.lastRun = started }
        let copy = [Fixtures.snapshot("2026-09-28 10:00:00")]
        state.recordCopies(sourceId: kept.id, destinationId: hdd.id, copy, seenAt: finished)
        state.recordCopies(sourceId: kept.id, destinationId: ssd.id, copy, seenAt: finished)
        state.recordCopies(sourceId: removed, destinationId: hdd.id, copy, seenAt: finished)

        reducer.dropOrphans(config: config, state: &state)

        #expect(Set(state.sources.keys) == [kept.id.uuidString])
        #expect(Set(state.copyCache.keys) == [AppState.deliveryKey(sourceId: kept.id, destinationId: hdd.id)])
    }
}

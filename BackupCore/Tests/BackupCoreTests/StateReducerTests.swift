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

    @Test func missedDiskRemembersWhetherTheBackupReachedAnotherDisk() {
        var covered = AppState()
        reducer.apply(record([(disk, .unavailable), (cloud, .delivered(pruned: 0, warning: nil))]), to: &covered)
        #expect(covered.debts.map(\.elsewhere) == [true])

        var alone = AppState()
        reducer.apply(record([(disk, .unavailable)]), to: &alone)
        #expect(alone.debts.map(\.elsewhere) == [false])
        reducer.apply(record([(disk, .unavailable), (cloud, .delivered(pruned: 0, warning: nil))]), to: &alone)
        #expect(alone.debts.map(\.elsewhere) == [false])
    }

    @Test func successAdvancesScheduleAndMarksDestinationsCaughtUp() {
        var state = AppState()
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil)), (cloud, .delivered(pruned: 1, warning: nil))]), to: &state)
        #expect(state.sourceState(sourceId) == SourceState(lastRun: started, lastSuccess: started))
        #expect(state.debts.isEmpty)
        #expect(state.destinationState(disk).lastCaughtUp == finished)
    }

    @Test func unavailableAndFailedDestinationsBecomeDebts() {
        var state = AppState()
        reducer.apply(record([(disk, .unavailable), (cloud, .failed(message: "quota"))]), to: &state)
        #expect(state.debts == [
            Debt(sourceId: sourceId, destinationId: disk, since: started, elsewhere: false),
            Debt(sourceId: sourceId, destinationId: cloud, since: started, lastAttempt: finished, elsewhere: false),
        ])
        #expect(state.sourceState(sourceId).lastRun == started)
        #expect(state.sourceState(sourceId).lastError == "quota")
        #expect(state.destinationState(disk).lastCaughtUp == nil)
    }

    @Test func repeatedMissKeepsOriginalDebtDate() {
        var state = AppState()
        let earlier = Fixtures.date("2026-09-20 10:00:00")
        state.debts = [Debt(sourceId: sourceId, destinationId: disk, since: earlier)]
        reducer.apply(record([(disk, .unavailable)]), to: &state)
        #expect(state.debts == [Debt(sourceId: sourceId, destinationId: disk, since: earlier, elsewhere: false)])
    }

    @Test func catchUpClearsDebtAndErrorWithoutMovingSchedule() {
        var state = AppState()
        let lastRun = Fixtures.date("2026-09-27 10:00:00")
        state.updateSource(sourceId) { $0.lastRun = lastRun; $0.lastError = "quota" }
        state.debts = [Debt(sourceId: sourceId, destinationId: disk, since: lastRun)]
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil))], trigger: .catchUp), to: &state)
        #expect(state.debts.isEmpty)
        #expect(state.sourceState(sourceId) == SourceState(lastRun: lastRun, lastSuccess: started))
        #expect(state.destinationState(disk).lastCaughtUp == finished)
    }

    @Test func destinationIsNotCaughtUpWhileOtherSourcesAreOwed() {
        var state = AppState()
        state.debts = [Debt(sourceId: UUID(), destinationId: disk, since: started)]
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil))]), to: &state)
        #expect(state.destinationState(disk).lastCaughtUp == nil)
    }

    @Test func collectFailureSchedulesRetryAndKeepsSchedule() {
        var state = AppState()
        reducer.apply(record([], collectError: "auth required"), to: &state)
        #expect(state.sourceState(sourceId) == SourceState(lastError: "auth required", retryAfter: finished.addingTimeInterval(3600)))
    }

    @Test func dropsStateOfRemovedSourcesAndDestinations() {
        let keptDestination = Destination(name: "Cloud", kind: .localFolder(path: "/c"))
        let removedFromSource = Destination(name: "HDD", kind: .localFolder(path: "/h"))
        let source = Fixtures.source(destinations: [keptDestination])
        let config = Config(sources: [source], destinations: [keptDestination, removedFromSource])
        var state = AppState()
        state.debts = [
            Debt(sourceId: source.id, destinationId: keptDestination.id, since: started),
            Debt(sourceId: source.id, destinationId: removedFromSource.id, since: started),
            Debt(sourceId: UUID(), destinationId: keptDestination.id, since: started),
            Debt(sourceId: source.id, destinationId: UUID(), since: started),
        ]
        state.updateSource(UUID()) { $0.lastRun = started }
        state.updateSource(source.id) { $0.lastRun = started }

        reducer.dropOrphans(config: config, state: &state)
        #expect(state.debts == [Debt(sourceId: source.id, destinationId: keptDestination.id, since: started)])
        #expect(Array(state.sources.keys) == [source.id.uuidString])
    }

    @Test func collectFailurePostponesRetryOfTheSourceDebts() {
        var state = AppState()
        state.debts = [Debt(sourceId: sourceId, destinationId: disk, since: started)]
        reducer.apply(record([], trigger: .catchUp, collectError: "auth required"), to: &state)
        #expect(state.debts == [Debt(sourceId: sourceId, destinationId: disk, since: started, lastAttempt: finished)])
    }

    @Test func remembersWhichCopyReachedEachDestination() {
        var state = AppState()
        var delivered = record([(disk, .delivered(pruned: 0, warning: nil)), (cloud, .unavailable)])
        delivered.snapshotName = "2026-09-28_100000"
        reducer.apply(delivered, to: &state)
        #expect(state.lastDeliveredSnapshot(sourceId: sourceId, destinationId: disk) == "2026-09-28_100000")
        #expect(state.lastDeliveredSnapshot(sourceId: sourceId, destinationId: cloud) == nil)
    }

    @Test func lastSuccessFollowsTheFreshestDeliveredCopyIncludingCatchUps() {
        var state = AppState()
        var scheduled = record([(disk, .delivered(pruned: 0, warning: nil))])
        scheduled.collectedAt = started
        reducer.apply(scheduled, to: &state)
        #expect(state.sourceState(sourceId).lastSuccess == started)

        let later = started.addingTimeInterval(3600)
        var catchUp = record([(cloud, .delivered(pruned: 0, warning: nil))], trigger: .catchUp)
        catchUp.collectedAt = later
        reducer.apply(catchUp, to: &state)
        #expect(state.sourceState(sourceId).lastSuccess == later)
        #expect(state.sourceState(sourceId).lastRun == started)

        var stalePackage = record([(disk, .delivered(pruned: 0, warning: nil))], trigger: .catchUp)
        stalePackage.collectedAt = started.addingTimeInterval(-86_400)
        reducer.apply(stalePackage, to: &state)
        #expect(state.sourceState(sourceId).lastSuccess == later)
    }

    @Test func deferredOrFailedRunsDoNotCountAsSuccess() {
        var state = AppState()
        reducer.apply(record([(disk, .unavailable), (cloud, .failed(message: "quota"))]), to: &state)
        reducer.apply(record([], collectError: "auth"), to: &state)
        #expect(state.sourceState(sourceId).lastSuccess == nil)
    }

    @Test func unpluggedDiskDoesNotPostponeTheRetryOfAFailedWrite() {
        var state = AppState()
        reducer.apply(record([(disk, .failed(message: "I/O error"))]), to: &state)
        #expect(state.debts.map(\.lastAttempt) == [finished])

        var later = record([(disk, .unavailable)])
        later.finishedAt = finished.addingTimeInterval(7200)
        reducer.apply(later, to: &state)
        #expect(state.debts.map(\.lastAttempt) == [finished])

        var retried = record([(disk, .failed(message: "I/O error"))])
        retried.finishedAt = finished.addingTimeInterval(10_800)
        reducer.apply(retried, to: &state)
        #expect(state.debts.map(\.lastAttempt) == [retried.finishedAt])
        #expect(state.debts.count == 1)
    }
}

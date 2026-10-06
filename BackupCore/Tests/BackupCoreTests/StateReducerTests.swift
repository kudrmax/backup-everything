import Foundation
import Testing
@testable import BackupCore

struct StateReducerTests {
    private let reducer = StateReducer()
    private let config = Config()
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
        reducer.apply(record([(disk, .unavailable), (cloud, .delivered(pruned: 0, warning: nil))]), to: &covered, config: config)
        #expect(covered.debts.map(\.elsewhere) == [true])

        var alone = AppState()
        reducer.apply(record([(disk, .unavailable)]), to: &alone, config: config)
        #expect(alone.debts.map(\.elsewhere) == [false])
        reducer.apply(record([(disk, .unavailable), (cloud, .delivered(pruned: 0, warning: nil))]), to: &alone, config: config)
        #expect(alone.debts.map(\.elsewhere) == [false])
    }

    @Test func successAdvancesScheduleAndMarksDestinationsCaughtUp() {
        var state = AppState()
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil)), (cloud, .delivered(pruned: 1, warning: nil))]), to: &state, config: config)
        #expect(state.sourceState(sourceId) == SourceState(lastRun: started, lastSuccess: started))
        #expect(state.debts.isEmpty)
        #expect(state.destinationState(disk).lastCaughtUp == finished)
    }

    @Test func unavailableAndFailedDestinationsBecomeDebts() {
        var state = AppState()
        reducer.apply(record([(disk, .unavailable), (cloud, .failed(message: "quota"))]), to: &state, config: config)
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
        reducer.apply(record([(disk, .unavailable)]), to: &state, config: config)
        #expect(state.debts == [Debt(sourceId: sourceId, destinationId: disk, since: earlier, elsewhere: false)])
    }

    @Test func catchUpClearsDebtAndErrorWithoutMovingSchedule() {
        var state = AppState()
        let lastRun = Fixtures.date("2026-09-27 10:00:00")
        state.updateSource(sourceId) { $0.lastRun = lastRun; $0.lastError = "quota" }
        state.debts = [Debt(sourceId: sourceId, destinationId: disk, since: lastRun)]
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil))], trigger: .catchUp), to: &state, config: config)
        #expect(state.debts.isEmpty)
        #expect(state.sourceState(sourceId) == SourceState(lastRun: lastRun, lastSuccess: started))
        #expect(state.destinationState(disk).lastCaughtUp == finished)
    }

    /// A catch-up delivers a copy made before the source broke: the source stays red and its hourly retry stays.
    @Test func catchUpKeepsTheErrorOfACollectionThatKeepsFailing() {
        var state = AppState()
        let retryAfter = started.addingTimeInterval(3600)
        state.updateSource(sourceId) { $0.lastError = "path missing"; $0.retryAfter = retryAfter }
        state.debts = [Debt(sourceId: sourceId, destinationId: disk, since: started)]
        var olderCopy = record([(disk, .delivered(pruned: 0, warning: nil))], trigger: .catchUp)
        olderCopy.deliversAnOlderCopy = true
        reducer.apply(olderCopy, to: &state, config: config)
        #expect(state.debts.isEmpty)
        #expect(state.sourceState(sourceId) == SourceState(lastSuccess: started, lastError: "path missing", retryAfter: retryAfter))
    }

    /// The name of a copy made in a zone east of the current one reads as a later moment than the catch-up itself.
    /// The copy is still old: the source stays red, and its last success is not put in the future.
    @Test func olderCopyWhoseNameReadsAsTheFutureKeepsTheCollectError() {
        var state = AppState()
        reducer.apply(record([], collectError: "boom"), to: &state, config: config)
        var olderCopy = record([(disk, .delivered(pruned: 0, warning: nil))], trigger: .catchUp)
        olderCopy.collectedAt = finished.addingTimeInterval(3600)
        olderCopy.copiedFrom = "Cloud"
        olderCopy.deliversAnOlderCopy = true

        reducer.apply(olderCopy, to: &state, config: config)

        #expect(state.sourceState(sourceId).lastError == "boom")
        #expect(state.sourceState(sourceId).retryAfter == finished.addingTimeInterval(3600))
        #expect(state.sourceState(sourceId).lastSuccess == finished)
    }

    /// A disabled source pays nothing, so its debt must not keep the disk from counting as caught up: otherwise the deadline
    /// to connect it is counted from a long-gone date and asks for the disk right away.
    @Test func debtOfADisabledSourceDoesNotHoldBackTheCatchUpOfItsDestination() {
        let paused = Fixtures.source(name: "Paused")
        var disabled = paused
        disabled.enabled = false
        let config = Config(sources: [disabled])
        var state = AppState()
        state.updateDestination(disk) { $0.lastCaughtUp = Fixtures.date("2026-08-01 00:00:00") }
        state.debts = [Debt(sourceId: paused.id, destinationId: disk, since: Fixtures.date("2026-08-20 00:00:00"))]

        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil))]), to: &state, config: config)
        #expect(state.destinationState(disk).lastCaughtUp == finished)
        #expect(state.debts.map(\.sourceId) == [paused.id])

        var nextDay = record([(disk, .delivered(pruned: 0, warning: nil))])
        nextDay.finishedAt = finished.addingTimeInterval(86_400)
        reducer.apply(nextDay, to: &state, config: Config(sources: [paused]))
        #expect(state.destinationState(disk).lastCaughtUp == finished)
    }

    @Test func catchUpThatGatheredTheSourceAgainClearsItsError() {
        var state = AppState()
        state.updateSource(sourceId) { $0.lastError = "path missing"; $0.retryAfter = started.addingTimeInterval(3600) }
        var gathered = record([(disk, .delivered(pruned: 0, warning: nil))], trigger: .catchUp)
        gathered.collectedAt = started
        reducer.apply(gathered, to: &state, config: config)
        #expect(state.sourceState(sourceId) == SourceState(lastSuccess: started))
    }

    @Test func scheduledRunClearsTheErrorOfAFailedCollection() {
        var state = AppState()
        state.updateSource(sourceId) { $0.lastError = "path missing"; $0.retryAfter = started }
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil))]), to: &state, config: config)
        #expect(state.sourceState(sourceId) == SourceState(lastRun: started, lastSuccess: started))
    }

    @Test func destinationIsNotCaughtUpWhileOtherSourcesAreOwed() {
        var state = AppState()
        state.debts = [Debt(sourceId: UUID(), destinationId: disk, since: started)]
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: nil))]), to: &state, config: config)
        #expect(state.destinationState(disk).lastCaughtUp == nil)
    }

    @Test func collectFailureSchedulesRetryAndKeepsSchedule() {
        var state = AppState()
        reducer.apply(record([], collectError: "auth required"), to: &state, config: config)
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
        let kept = AppState.deliveryKey(sourceId: source.id, destinationId: keptDestination.id)
        state.deliveryWarnings = [kept: "old", AppState.deliveryKey(sourceId: source.id, destinationId: removedFromSource.id): "old"]
        state.recordDelivery(sourceId: source.id, destinationId: keptDestination.id, snapshotName: "a", collectedAt: started)
        state.recordDelivery(sourceId: source.id, destinationId: removedFromSource.id, snapshotName: "a", collectedAt: started)

        reducer.dropOrphans(config: config, state: &state)
        #expect(state.deliveredAt == [kept: started])
        #expect(state.debts == [Debt(sourceId: source.id, destinationId: keptDestination.id, since: started)])
        #expect(Array(state.sources.keys) == [source.id.uuidString])
        #expect(state.deliveryWarnings == [kept: "old"])
    }

    @Test func collectFailurePostponesRetryOfTheSourceDebts() {
        var state = AppState()
        state.debts = [Debt(sourceId: sourceId, destinationId: disk, since: started)]
        reducer.apply(record([], trigger: .catchUp, collectError: "auth required"), to: &state, config: config)
        #expect(state.debts == [Debt(sourceId: sourceId, destinationId: disk, since: started, lastAttempt: finished)])
    }

    /// A cleanup that failed after delivery stays visible until a later delivery to that destination goes without it.
    @Test func remembersWhatWentWrongAfterEachDelivery() {
        var state = AppState()
        reducer.apply(record([(disk, .delivered(pruned: 0, warning: "Could not clean up old copies: busy")), (cloud, .delivered(pruned: 0, warning: nil))]), to: &state, config: config)
        reducer.apply(record([(disk, .unavailable), (cloud, .failed(message: "quota"))]), to: &state, config: config)
        #expect(state.deliveryWarnings == [AppState.deliveryKey(sourceId: sourceId, destinationId: disk): "Could not clean up old copies: busy"])

        reducer.apply(record([(disk, .delivered(pruned: 1, warning: nil))]), to: &state, config: config)
        #expect(state.deliveryWarnings.isEmpty)
    }

    @Test func remembersWhichCopyReachedEachDestination() {
        var state = AppState()
        var delivered = record([(disk, .delivered(pruned: 0, warning: nil)), (cloud, .unavailable)])
        delivered.snapshotName = "2026-09-28_100000"
        reducer.apply(delivered, to: &state, config: config)
        #expect(state.lastDeliveredSnapshot(sourceId: sourceId, destinationId: disk) == "2026-09-28_100000")
        #expect(state.lastDeliveredSnapshot(sourceId: sourceId, destinationId: cloud) == nil)
    }

    /// The status is built on when each delivered copy was collected, not on when the run happened (5.5).
    @Test func remembersWhenTheCopyOnEachDestinationWasCollected() {
        var state = AppState()
        var delivered = record([(disk, .delivered(pruned: 0, warning: nil)), (cloud, .unavailable)])
        delivered.collectedAt = started.addingTimeInterval(60)
        reducer.apply(delivered, to: &state, config: config)
        #expect(state.deliveredCopyDate(sourceId: sourceId, destinationId: disk) == started.addingTimeInterval(60))
        #expect(state.deliveredCopyDate(sourceId: sourceId, destinationId: cloud) == nil)

        var olderCopy = record([(cloud, .delivered(pruned: 0, warning: nil))], trigger: .catchUp)
        olderCopy.collectedAt = started.addingTimeInterval(-86_400)
        reducer.apply(olderCopy, to: &state, config: config)
        #expect(state.deliveredCopyDate(sourceId: sourceId, destinationId: cloud) == started.addingTimeInterval(-86_400))

        var futureName = record([(disk, .delivered(pruned: 0, warning: nil))])
        futureName.collectedAt = finished.addingTimeInterval(7200)
        reducer.apply(futureName, to: &state, config: config)
        #expect(state.deliveredCopyDate(sourceId: sourceId, destinationId: disk) == finished)
    }

    /// A copy found missing no longer counts: neither its name nor its date stays.
    @Test func forgottenDeliveryLeavesNoDate() {
        var state = AppState()
        state.recordDelivery(sourceId: sourceId, destinationId: disk, snapshotName: "2026-09-28_100000", collectedAt: started)
        state.forgetDelivery(sourceId: sourceId, destinationId: disk)
        #expect(state.lastDeliveredSnapshot(sourceId: sourceId, destinationId: disk) == nil)
        #expect(state.deliveredCopyDate(sourceId: sourceId, destinationId: disk) == nil)
    }

    @Test func lastSuccessFollowsTheFreshestDeliveredCopyIncludingCatchUps() {
        var state = AppState()
        var scheduled = record([(disk, .delivered(pruned: 0, warning: nil))])
        scheduled.collectedAt = started
        reducer.apply(scheduled, to: &state, config: config)
        #expect(state.sourceState(sourceId).lastSuccess == started)

        let later = started.addingTimeInterval(3600)
        var catchUp = record([(cloud, .delivered(pruned: 0, warning: nil))], trigger: .catchUp)
        catchUp.collectedAt = later
        catchUp.startedAt = later
        catchUp.finishedAt = later.addingTimeInterval(60)
        reducer.apply(catchUp, to: &state, config: config)
        #expect(state.sourceState(sourceId).lastSuccess == later)
        #expect(state.sourceState(sourceId).lastRun == started)

        var stalePackage = record([(disk, .delivered(pruned: 0, warning: nil))], trigger: .catchUp)
        stalePackage.collectedAt = started.addingTimeInterval(-86_400)
        reducer.apply(stalePackage, to: &state, config: config)
        #expect(state.sourceState(sourceId).lastSuccess == later)
    }

    @Test func deferredOrFailedRunsDoNotCountAsSuccess() {
        var state = AppState()
        reducer.apply(record([(disk, .unavailable), (cloud, .failed(message: "quota"))]), to: &state, config: config)
        reducer.apply(record([], collectError: "auth"), to: &state, config: config)
        #expect(state.sourceState(sourceId).lastSuccess == nil)
    }

    @Test func unpluggedDiskDoesNotPostponeTheRetryOfAFailedWrite() {
        var state = AppState()
        reducer.apply(record([(disk, .failed(message: "I/O error"))]), to: &state, config: config)
        #expect(state.debts.map(\.lastAttempt) == [finished])

        var later = record([(disk, .unavailable)])
        later.finishedAt = finished.addingTimeInterval(7200)
        reducer.apply(later, to: &state, config: config)
        #expect(state.debts.map(\.lastAttempt) == [finished])

        var retried = record([(disk, .failed(message: "I/O error"))])
        retried.finishedAt = finished.addingTimeInterval(10_800)
        reducer.apply(retried, to: &state, config: config)
        #expect(state.debts.map(\.lastAttempt) == [retried.finishedAt])
        #expect(state.debts.count == 1)
    }
}

import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct ActivityTrackerTests {
    private let first = UUID()
    private let second = UUID()
    private let disk = UUID()

    @Test func followsARunFromQueueToFinish() {
        var tracker = ActivityTracker()
        tracker.apply(.queued(sourceIds: [first, second]))
        #expect(tracker.stage(of: first) == .queued)
        #expect(tracker.stage(of: second) == .queued)
        #expect(tracker.current == nil)

        tracker.apply(.collecting(sourceId: first))
        #expect(tracker.stage(of: first) == .collecting)
        #expect(tracker.current == first)

        tracker.apply(.delivering(sourceId: first, destinationId: disk))
        #expect(tracker.stage(of: first) == .delivering(destinationId: disk))

        tracker.apply(.finished(sourceId: first))
        #expect(tracker.stage(of: first) == nil)
        #expect(tracker.current == nil)
        #expect(tracker.waitingCount == 1)
    }

    @Test func resetForgetsSourcesThatNeverStarted() {
        var tracker = ActivityTracker()
        tracker.apply(.queued(sourceIds: [first, second]))
        tracker.reset()
        #expect(tracker.stage(of: first) == nil)
        #expect(tracker.waitingCount == 0)
    }

    @Test func stageTextsArePlainEnglish() {
        #expect(Texts.stage(.queued, destinationName: nil) == "queued")
        #expect(Texts.stage(.collecting, destinationName: nil) == "preparing the copy…")
        #expect(Texts.stage(.delivering(destinationId: disk), destinationName: "HDD") == "copying to “HDD”…")
    }

    @Test func deliveryStateCombinesLastOutcomeAndDebt() {
        #expect(DeliveryState.of(lastOutcome: nil, isWaiting: false) == .none)
        #expect(DeliveryState.of(lastOutcome: nil, isWaiting: true) == .waiting)
        #expect(DeliveryState.of(lastOutcome: .delivered(pruned: 0, warning: nil), isWaiting: false) == .delivered)
        #expect(DeliveryState.of(lastOutcome: .delivered(pruned: 0, warning: nil), isWaiting: true) == .waiting)
        #expect(DeliveryState.of(lastOutcome: .unavailable, isWaiting: true) == .waiting)
        #expect(DeliveryState.of(lastOutcome: .failed(message: "quota"), isWaiting: true) == .failed)
        #expect(DeliveryState.of(lastOutcome: .failed(message: "quota"), isWaiting: false) == .none)
    }

    @Test func remembersWhenTheRunStartedAndWhatTheSourceReports() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var tracker = ActivityTracker()
        tracker.apply(.queued(sourceIds: [first]), at: start)
        #expect(tracker.startedAt(of: first) == nil)

        tracker.apply(.collecting(sourceId: first), at: start.addingTimeInterval(5))
        tracker.apply(.status(sourceId: first, text: "3 of 40 · repo"), at: start.addingTimeInterval(60))
        #expect(tracker.stage(of: first) == .collecting)
        #expect(tracker.status(of: first) == "3 of 40 · repo")
        #expect(tracker.startedAt(of: first) == start.addingTimeInterval(5))

        tracker.apply(.delivering(sourceId: first, destinationId: disk), at: start.addingTimeInterval(90))
        #expect(tracker.status(of: first) == nil)
        #expect(tracker.startedAt(of: first) == start.addingTimeInterval(5))

        tracker.apply(.finished(sourceId: first), at: start.addingTimeInterval(120))
        #expect(tracker.startedAt(of: first) == nil)
    }

    @Test func durationIsShortAndCoarse() {
        #expect(Texts.duration(0) == "0 s")
        #expect(Texts.duration(42) == "42 s")
        #expect(Texts.duration(60) == "1 min")
        #expect(Texts.duration(16 * 60 + 30) == "16 min")
        #expect(Texts.duration(3600 + 5 * 60) == "1 h 5 min")
    }

    @Test func usualDurationComesFromTheLatestCompleteRun() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func run(_ source: UUID, _ trigger: RunTrigger, seconds: TimeInterval, error: String? = nil, delivered: Bool = true) -> RunRecord {
            var record = RunRecord(sourceId: source, sourceName: "S", trigger: trigger, startedAt: start, finishedAt: start.addingTimeInterval(seconds))
            record.collectError = error
            record.deliveries = delivered ? [Delivery(destinationId: disk, destinationName: "Disk", outcome: .delivered(pruned: 0, warning: nil))] : []
            return record
        }
        let runs = [
            run(first, .catchUp, seconds: 2),
            run(first, .manual, seconds: 5, error: "broke", delivered: false),
            run(second, .scheduled, seconds: 900),
            run(first, .scheduled, seconds: 1320),
            run(first, .scheduled, seconds: 60),
        ]
        #expect(RunTiming.usualDuration(of: first, in: runs, copying: false) == 1320)
        #expect(RunTiming.usualDuration(of: UUID(), in: runs, copying: false) == nil)
    }

    @Test func copyingIsComparedWithAnEarlierCopyAndPickupsTellNothingAboutCollecting() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func run(_ trigger: RunTrigger, seconds: TimeInterval, copiedFrom: String? = nil) -> RunRecord {
            RunRecord(
                sourceId: first, sourceName: "PocketBook", trigger: trigger, startedAt: start,
                finishedAt: start.addingTimeInterval(seconds), copiedFrom: copiedFrom,
                deliveries: [Delivery(destinationId: disk, destinationName: "HDD", outcome: .delivered(pruned: 0, warning: nil))]
            )
        }
        let runs = [run(.pickup, seconds: 1), run(.catchUp, seconds: 78, copiedFrom: "Laptop folder")]
        #expect(RunTiming.usualDuration(of: first, in: runs, copying: true) == 78)
        #expect(RunTiming.usualDuration(of: first, in: runs, copying: false) == nil)
    }

    @Test func trackerTellsACopyFromACollection() {
        let id = UUID()
        var tracker = ActivityTracker()
        tracker.apply(.delivering(sourceId: id, destinationId: disk))
        #expect(tracker.isCopying(id))
        tracker.apply(.finished(sourceId: id))
        tracker.apply(.collecting(sourceId: id))
        tracker.apply(.delivering(sourceId: id, destinationId: disk))
        #expect(!tracker.isCopying(id))
    }

    @Test func elapsedTipMentionsTheUsualDurationWhenKnown() {
        #expect(RunTiming.tip(elapsed: 960, usual: 1320) == "Running for 16 min\nLast time took 22 min")
        #expect(RunTiming.tip(elapsed: 960, usual: nil) == "Running for 16 min")
    }

    @Test func trackerRemembersWhichStepIsRunning() {
        let id = UUID()
        var tracker = ActivityTracker()
        tracker.apply(.collecting(sourceId: id))
        #expect(tracker.step(of: id) == nil)
        tracker.apply(.step(sourceId: id, index: 1, count: 2))
        #expect(tracker.step(of: id)?.index == 1)
        #expect(tracker.step(of: id)?.count == 2)
        tracker.apply(.finished(sourceId: id))
        #expect(tracker.step(of: id) == nil)
    }
}

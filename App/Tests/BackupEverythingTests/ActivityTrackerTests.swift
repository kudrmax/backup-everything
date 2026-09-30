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

    @Test func stageTextsArePlainRussian() {
        #expect(Texts.stage(.queued, destinationName: nil) == "в очереди")
        #expect(Texts.stage(.collecting, destinationName: nil) == "готовит копию…")
        #expect(Texts.stage(.delivering(destinationId: disk), destinationName: "HDD") == "копирует на «HDD»…")
    }

    @Test func deliveryStateCombinesLastOutcomeAndDebt() {
        #expect(DeliveryState.of(lastOutcome: nil, isWaiting: false) == .none)
        #expect(DeliveryState.of(lastOutcome: nil, isWaiting: true) == .waiting)
        #expect(DeliveryState.of(lastOutcome: .delivered(pruned: 0, warning: nil), isWaiting: false) == .delivered)
        #expect(DeliveryState.of(lastOutcome: .delivered(pruned: 0, warning: nil), isWaiting: true) == .waiting)
        #expect(DeliveryState.of(lastOutcome: .unavailable, isWaiting: true) == .waiting)
        #expect(DeliveryState.of(lastOutcome: .failed(message: "квота"), isWaiting: true) == .failed)
        #expect(DeliveryState.of(lastOutcome: .failed(message: "квота"), isWaiting: false) == .none)
    }

    @Test func remembersWhenTheRunStartedAndWhatTheSourceReports() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var tracker = ActivityTracker()
        tracker.apply(.queued(sourceIds: [first]), at: start)
        #expect(tracker.startedAt(of: first) == nil)

        tracker.apply(.collecting(sourceId: first), at: start.addingTimeInterval(5))
        tracker.apply(.status(sourceId: first, text: "3 из 40 · repo"), at: start.addingTimeInterval(60))
        #expect(tracker.stage(of: first) == .collecting)
        #expect(tracker.status(of: first) == "3 из 40 · repo")
        #expect(tracker.startedAt(of: first) == start.addingTimeInterval(5))

        tracker.apply(.delivering(sourceId: first, destinationId: disk), at: start.addingTimeInterval(90))
        #expect(tracker.status(of: first) == nil)
        #expect(tracker.startedAt(of: first) == start.addingTimeInterval(5))

        tracker.apply(.finished(sourceId: first), at: start.addingTimeInterval(120))
        #expect(tracker.startedAt(of: first) == nil)
    }

    @Test func durationIsShortAndCoarse() {
        #expect(Texts.duration(0) == "0 с")
        #expect(Texts.duration(42) == "42 с")
        #expect(Texts.duration(60) == "1 мин")
        #expect(Texts.duration(16 * 60 + 30) == "16 мин")
        #expect(Texts.duration(3600 + 5 * 60) == "1 ч 5 мин")
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
            run(first, .manual, seconds: 5, error: "сломалось", delivered: false),
            run(second, .scheduled, seconds: 900),
            run(first, .scheduled, seconds: 1320),
            run(first, .scheduled, seconds: 60),
        ]
        #expect(RunTiming.usualDuration(of: first, in: runs) == 1320)
        #expect(RunTiming.usualDuration(of: UUID(), in: runs) == nil)
    }

    @Test func elapsedTipMentionsTheUsualDurationWhenKnown() {
        #expect(RunTiming.tip(elapsed: 960, usual: 1320) == "Идёт 16 мин\nВ прошлый раз заняло 22 мин")
        #expect(RunTiming.tip(elapsed: 960, usual: nil) == "Идёт 16 мин\nСколько займёт, станет известно после первого запуска")
    }
}

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
        #expect(Texts.stage(.queued, destinationName: nil) == "В очереди")
        #expect(Texts.stage(.collecting, destinationName: nil) == "Собирает данные…")
        #expect(Texts.stage(.delivering(destinationId: disk), destinationName: "HDD") == "Записывает в «HDD»…")
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
}

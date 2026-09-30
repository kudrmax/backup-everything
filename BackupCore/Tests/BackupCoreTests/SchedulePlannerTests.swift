import Foundation
import Testing
@testable import BackupCore

struct SchedulePlannerTests {
    private let planner = SchedulePlanner(calendar: Fixtures.calendar)
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/c"))
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/h"), expectedEvery: .days(30))
    private let created = Fixtures.date("2026-09-01 00:00:00")
    private let now = Fixtures.date("2026-09-28 10:00:00")

    @Test func neverRunSourceIsDueSinceCreation() {
        let source = Fixtures.source(destinations: [cloud], createdAt: created)
        #expect(planner.dueDate(for: source, state: SourceState()) == created)
        #expect(planner.isDue(source, state: SourceState(), now: now))
    }

    @Test func sourceIsDueOneIntervalAfterLastRun() {
        let source = Fixtures.source(schedule: .weekly, destinations: [cloud])
        let state = SourceState(lastRun: Fixtures.date("2026-09-22 10:00:00"))
        #expect(!planner.isDue(source, state: state, now: Fixtures.date("2026-09-29 09:59:59")))
        #expect(planner.isDue(source, state: state, now: Fixtures.date("2026-09-29 10:00:00")))
    }

    @Test func retryDelayPostponesDueSource() {
        let source = Fixtures.source(destinations: [cloud])
        let state = SourceState(retryAfter: now.addingTimeInterval(600))
        #expect(!planner.isDue(source, state: state, now: now))
        #expect(planner.isDue(source, state: state, now: now.addingTimeInterval(600)))
    }

    @Test func manualScheduleAndDisabledSourcesAreNeverDue() {
        var disabled = Fixtures.source(destinations: [cloud])
        disabled.enabled = false
        #expect(planner.dueDate(for: disabled, state: SourceState()) == nil)
        #expect(planner.dueDate(for: Fixtures.source(schedule: .manual, destinations: [cloud]), state: SourceState()) == nil)
    }

    @Test func automaticRunsSkipManualExportsAndSourcesWithoutDestinations() {
        let folder = Fixtures.source(name: "Obsidian", destinations: [cloud])
        let orphan = Fixtures.source(name: "Orphan")
        let manual = Fixtures.source(
            name: "Photos",
            kind: .manualExport(watchPath: "/d", filePattern: "*.zip", fileMode: .multiple, removeOriginal: true),
            destinations: [cloud]
        )
        let config = Config(sources: [folder, orphan, manual], destinations: [cloud])
        #expect(planner.dueAutomaticSources(config: config, state: AppState(), now: now).map(\.name) == ["Obsidian"])
    }

    @Test func severeOverdueStartsAfterTwoMissedIntervals() {
        let source = Fixtures.source(schedule: .daily, destinations: [cloud])
        let state = SourceState(lastRun: Fixtures.date("2026-09-25 10:00:00"))
        #expect(!planner.isSeverelyOverdue(source, state: state, now: Fixtures.date("2026-09-28 10:00:00")))
        #expect(planner.isSeverelyOverdue(source, state: state, now: Fixtures.date("2026-09-28 10:00:01")))
    }

    @Test func failedDebtsWaitAnHourBeforeRetry() {
        var state = AppState()
        let fresh = Debt(sourceId: UUID(), destinationId: cloud.id, since: now)
        let recentFailure = Debt(sourceId: UUID(), destinationId: cloud.id, since: now, lastAttempt: now.addingTimeInterval(-600))
        let oldFailure = Debt(sourceId: UUID(), destinationId: cloud.id, since: now, lastAttempt: now.addingTimeInterval(-3600))
        state.debts = [fresh, recentFailure, oldFailure]
        #expect(planner.retryableDebts(state: state, now: now) == [fresh, oldFailure])
    }

    @Test func connectDeadlineCountsFromLastCatchUpOrFirstDebt() {
        var state = AppState()
        #expect(planner.connectDeadline(for: disk, state: state) == nil)

        state.debts = [Debt(sourceId: UUID(), destinationId: disk.id, since: Fixtures.date("2026-09-10 10:00:00"))]
        #expect(planner.connectDeadline(for: disk, state: state) == Fixtures.date("2026-10-10 10:00:00"))

        state.updateDestination(disk.id) { $0.lastCaughtUp = Fixtures.date("2026-09-05 10:00:00") }
        #expect(planner.connectDeadline(for: disk, state: state) == Fixtures.date("2026-10-05 10:00:00"))
        #expect(planner.connectDeadline(for: cloud, state: state) == nil)
    }

    @Test func nextWakeIsEarliestFutureEvent() {
        let daily = Fixtures.source(name: "Daily", schedule: .daily, destinations: [cloud, disk])
        let weekly = Fixtures.source(name: "Weekly", schedule: .weekly, destinations: [cloud])
        let config = Config(sources: [daily, weekly], destinations: [cloud, disk])
        var state = AppState()
        state.updateSource(daily.id) { $0.lastRun = Fixtures.date("2026-09-28 08:00:00") }
        state.updateSource(weekly.id) { $0.lastRun = Fixtures.date("2026-09-27 08:00:00") }

        #expect(planner.nextWake(config: config, state: state, now: now, needsAttention: false) == Fixtures.date("2026-09-29 08:00:00"))
        #expect(planner.nextWake(config: config, state: state, now: now, needsAttention: true) == now.addingTimeInterval(3600))

        state.updateDestination(disk.id) { $0.lastCaughtUp = Fixtures.date("2026-08-29 20:00:00") }
        state.debts = [Debt(sourceId: daily.id, destinationId: disk.id, since: now)]
        #expect(planner.nextWake(config: config, state: state, now: now, needsAttention: false) == Fixtures.date("2026-09-28 20:00:00"))
    }

    @Test func nothingScheduledMeansNoWake() {
        let config = Config(sources: [Fixtures.source(schedule: .manual, destinations: [cloud])], destinations: [cloud])
        #expect(planner.nextWake(config: config, state: AppState(), now: now, needsAttention: false) == nil)
    }

    @Test func sourceWithOnlyDeletedDestinationsIsNotRunAutomatically() {
        let source = Fixtures.source(destinations: [cloud])
        let config = Config(sources: [source], destinations: [])
        #expect(planner.dueAutomaticSources(config: config, state: AppState(), now: now).isEmpty)
    }
}

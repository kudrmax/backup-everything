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

    private func newest(_ copies: [(Destination, Date)]) -> (UUID) -> Date? {
        let dates = Dictionary(copies.map { ($0.0.id, $0.1) }, uniquingKeysWith: max)
        return { dates[$0] }
    }

    private func overdue(_ source: Source, copies: [(Destination, Date)] = [], hasRun: Bool = true, at now: String, on destinations: [Destination]? = nil) -> Bool {
        let destinations = destinations ?? [cloud, disk].filter { source.destinationIds.contains($0.id) }
        return planner.isSeverelyOverdue(source, on: destinations, newest: newest(copies), hasRun: hasRun, now: Fixtures.date(now))
    }

    private func needing(_ source: Source, copies: [(Destination, Date)] = [], in config: Config? = nil) -> [String] {
        let config = config ?? Config(sources: [source], destinations: [cloud, disk])
        return planner.destinationsNeedingCopy(of: source, in: config, newest: newest(copies), now: now).map(\.name)
    }

    @Test func destinationWithoutACopyNeedsOne() {
        let source = Fixtures.source(destinations: [cloud])
        #expect(needing(source) == ["Cloud"])
    }

    @Test func copyFromYesterdayOfADailySourceIsNotEnough() {
        let source = Fixtures.source(schedule: .daily, destinations: [cloud])
        #expect(needing(source, copies: [(cloud, now.addingTimeInterval(-86_400))]) == ["Cloud"])
    }

    @Test func copyFromTodayIsEnough() {
        let source = Fixtures.source(schedule: .daily, destinations: [cloud, disk])
        #expect(needing(source, copies: [(cloud, now.addingTimeInterval(-3600)), (disk, now.addingTimeInterval(-90_000))]) == ["HDD"])
    }

    @Test func manualOrDisabledSourceNeedsNothingByItself() {
        #expect(needing(Fixtures.source(schedule: .manual, destinations: [cloud])).isEmpty)
        var disabled = Fixtures.source(destinations: [cloud])
        disabled.enabled = false
        #expect(needing(disabled).isEmpty)
    }

    @Test func deletedDestinationNeedsNothing() {
        let source = Fixtures.source(destinations: [cloud])
        #expect(needing(source, in: Config(sources: [source], destinations: [])).isEmpty)
    }

    @Test func severeOverdueStartsTwoMissedIntervalsAfterTheNewestCopy() {
        let source = Fixtures.source(schedule: .daily, destinations: [cloud])
        let copies = [(cloud, Fixtures.date("2026-09-25 10:00:00"))]
        #expect(!overdue(source, copies: copies, at: "2026-09-28 10:00:00"))
        #expect(overdue(source, copies: copies, at: "2026-09-28 10:00:01"))
    }

    /// Runs that deliver nothing are no backup: without any copy the source is overdue counting from its creation.
    @Test func sourceWithoutACopyIsOverdueCountingFromItsCreation() {
        let source = Fixtures.source(schedule: .daily, destinations: [cloud], createdAt: Fixtures.date("2026-09-25 10:00:00"))
        #expect(!overdue(source, at: "2026-09-28 10:00:00"))
        #expect(overdue(source, at: "2026-09-28 10:00:01"))
    }

    /// A disk that may stay unplugged for a week is not late with a copy of a daily source until the week is over: the
    /// two missed intervals count from the end of its own rhythm.
    @Test func copyOnADiskThatCanStayUnpluggedIsLongOverdueOnlyAfterItsRhythm() {
        let weekDisk = Destination(name: "HDD", kind: .localFolder(path: "/h"), expectedEvery: .days(7))
        let source = Fixtures.source(schedule: .daily, destinations: [weekDisk])
        let copies = [(weekDisk, Fixtures.date("2026-09-20 10:00:00"))]
        #expect(!overdue(source, copies: copies, at: "2026-09-24 10:00:00", on: [weekDisk]))
        #expect(!overdue(source, copies: copies, at: "2026-09-29 10:00:00", on: [weekDisk]))
        #expect(overdue(source, copies: copies, at: "2026-09-29 10:00:01", on: [weekDisk]))
    }

    /// The freshest copy anywhere decides: a fresh copy in the cloud keeps the source from being long overdue, however old
    /// the copy on the disk is.
    @Test func freshestCopyAnywhereDecides() {
        let source = Fixtures.source(schedule: .daily, destinations: [cloud, disk])
        let copies = [(cloud, Fixtures.date("2026-09-28 09:00:00")), (disk, Fixtures.date("2026-07-01 10:00:00"))]
        #expect(!overdue(source, copies: copies, at: "2026-09-28 10:00:00"))
    }

    @Test func sourceThatHasNeverRunIsNotSeverelyOverdue() {
        let source = Fixtures.source(schedule: .daily, destinations: [cloud], createdAt: created)
        #expect(!overdue(source, hasRun: false, at: "2026-09-28 10:00:00"))
        #expect(planner.isDue(source, state: SourceState(), now: now))
    }

    @Test func copyOnAnAlwaysConnectedDestinationIsFreshUntilTheNextBackupAndAnHour() {
        let source = Fixtures.source(schedule: .daily, destinations: [cloud])
        let fresh = now.addingTimeInterval(-(25 * 3600 - 1))
        let stale = now.addingTimeInterval(-26 * 3600)
        #expect(planner.isCopyFresh(source, on: cloud, copiedAt: fresh, now: now))
        #expect(!planner.isCopyFresh(source, on: cloud, copiedAt: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(!planner.isCopyFresh(source, on: cloud, copiedAt: stale, now: now))
        #expect(!planner.isCopyFresh(source, on: cloud, copiedAt: nil, now: now))
    }

    @Test func copyOfASourceWithoutScheduleStaysFresh() {
        let source = Fixtures.source(schedule: .manual, destinations: [cloud])
        #expect(planner.isCopyFresh(source, on: cloud, copiedAt: Fixtures.date("2026-01-01 00:00:00"), now: now))
    }

    @Test func copyOnADiskThatCanStayUnpluggedIsFreshUntilItsConnectDeadline() {
        let source = Fixtures.source(schedule: .daily, destinations: [cloud, disk])
        #expect(planner.isCopyFresh(source, on: disk, copiedAt: now.addingTimeInterval(-10 * 86_400), now: now))
        #expect(!planner.isCopyFresh(source, on: disk, copiedAt: now.addingTimeInterval(-31 * 86_400), now: now))
        #expect(!planner.isCopyFresh(source, on: disk, copiedAt: nil, now: now))
    }

    @Test func connectDeadlineIsTheIntervalAfterTheNewestCopy() {
        #expect(planner.connectDeadline(for: disk, newestCopy: nil) == nil)
        #expect(planner.connectDeadline(for: disk, newestCopy: Fixtures.date("2026-09-10 10:00:00")) == Fixtures.date("2026-10-10 10:00:00"))
        #expect(planner.connectDeadline(for: cloud, newestCopy: Fixtures.date("2026-09-10 10:00:00")) == nil)
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

        let oldCopy = Fixtures.snapshot("2026-08-29 20:00:00")
        state.recordCopies(sourceId: daily.id, destinationId: disk.id, [oldCopy], seenAt: now)
        #expect(planner.nextWake(config: config, state: state, now: now, needsAttention: false) == Fixtures.date("2026-09-28 20:00:00"))
    }

    @Test func nothingScheduledMeansNoWake() {
        let config = Config(sources: [Fixtures.source(schedule: .manual, destinations: [cloud])], destinations: [cloud])
        #expect(planner.nextWake(config: config, state: AppState(), now: now, needsAttention: false) == nil)
    }
}

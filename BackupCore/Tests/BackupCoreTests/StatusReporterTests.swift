import Foundation
import Testing
@testable import BackupCore

struct StatusReporterTests {
    private let reporter = StatusReporter(planner: SchedulePlanner(calendar: Fixtures.calendar))
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/c"))
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/h"), expectedEvery: .days(30))
    private let now = Fixtures.date("2026-09-28 10:00:00")

    private func report(
        _ sources: [Source],
        _ state: AppState,
        unavailable: Set<UUID> = [],
        scans: [UUID: InboxScan] = [:]
    ) -> StatusReport {
        reporter.report(
            config: Config(sources: sources, destinations: [cloud, disk]),
            state: state,
            now: now,
            unavailableDestinations: unavailable,
            inboxScans: scans
        )
    }

    private func fresh(_ source: Source) -> AppState {
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = now.addingTimeInterval(-3600) }
        return state
    }

    private func photos(_ schedule: Schedule = .monthly) -> Source {
        Fixtures.source(
            name: "Photos",
            kind: .manualExport(watchPath: "/d", filePattern: "takeout-*.zip", fileMode: .multiple, removeOriginal: true),
            schedule: schedule,
            destinations: [cloud]
        )
    }

    @Test func freshSourcesAreOk() {
        let source = Fixtures.source(destinations: [cloud, disk])
        let result = report([source], fresh(source))
        #expect(result.items.isEmpty)
        #expect(result.overall == .ok)
    }

    @Test func failedRunIsError() {
        let source = Fixtures.source(destinations: [cloud])
        var state = fresh(source)
        state.updateSource(source.id) { $0.lastError = "quota" }
        let result = report([source], state)
        #expect(result.items == [.runFailed(sourceId: source.id, message: "quota")])
        #expect(result.overall == .error)
    }

    @Test func longOverdueSourceIsError() {
        let source = Fixtures.source(destinations: [cloud])
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = Fixtures.date("2026-09-20 10:00:00") }
        #expect(report([source], state).items == [.severelyOverdue(sourceId: source.id)])
    }

    @Test func sourceWithoutDestinationsNeedsAttention() {
        let source = Fixtures.source()
        let result = report([source], AppState())
        #expect(result.items == [.noDestinations(sourceId: source.id)])
        #expect(result.overall == .attention)
    }

    @Test func disabledSourceIsIgnored() {
        var source = Fixtures.source()
        source.enabled = false
        #expect(report([source], AppState()).overall == .ok)
    }

    @Test func dueManualExportAsksForExport() {
        let source = photos()
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = Fixtures.date("2026-08-20 10:00:00") }
        #expect(report([source], state).items == [.manualExportDue(sourceId: source.id)])
    }

    @Test func foundFilesReplaceTheReminder() {
        let source = photos()
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = Fixtures.date("2026-08-20 10:00:00") }
        let scan = InboxScan(files: [URL(fileURLWithPath: "/d/takeout-1.zip")], totalBytes: 12, downloadInProgress: true)
        #expect(report([source], state, scans: [source.id: scan]).items == [
            .filesAwaitingPickup(sourceId: source.id, fileCount: 1, totalBytes: 12, downloadInProgress: true),
        ])
    }

    @Test func unfinishedDownloadWithoutMatchingFilesIsNotReported() {
        let source = photos()
        let scan = InboxScan(files: [], totalBytes: 0, downloadInProgress: true)
        #expect(report([source], fresh(source), scans: [source.id: scan]).items.isEmpty)
    }

    @Test func alwaysOnDestinationWithDebtIsReportedWhenUnreachable() {
        let source = Fixtures.source(destinations: [cloud])
        var state = fresh(source)
        state.debts = [Debt(sourceId: source.id, destinationId: cloud.id, since: now)]
        #expect(report([source], state, unavailable: [cloud.id]).items == [.destinationUnavailable(destinationId: cloud.id)])
        #expect(report([source], state).items.isEmpty)
    }

    @Test func periodicDiskIsQuietUntilItsDeadline() {
        let source = Fixtures.source(destinations: [disk])
        var state = fresh(source)
        state.debts = [Debt(sourceId: source.id, destinationId: disk.id, since: Fixtures.date("2026-09-10 10:00:00"))]
        state.updateDestination(disk.id) { $0.lastCaughtUp = Fixtures.date("2026-09-09 10:00:00") }
        #expect(report([source], state, unavailable: [disk.id]).overall == .ok)

        state.updateDestination(disk.id) { $0.lastCaughtUp = Fixtures.date("2026-08-29 10:00:00") }
        #expect(report([source], state, unavailable: [disk.id]).items == [.connectDestination(destinationId: disk.id)])
    }
}

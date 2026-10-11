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

    /// A source that ran an hour ago and delivered its copy to every destination.
    private func fresh(_ source: Source) -> AppState {
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = now.addingTimeInterval(-3600) }
        for destinationId in source.destinationIds {
            state.recordCopy(sourceId: source.id, destinationId: destinationId, at: now.addingTimeInterval(-3600))
        }
        return state
    }

    private func photos(_ schedule: Schedule = .monthly) -> Source {
        Fixtures.source(
            name: "Photos",
            steps: [.file("takeout-*.zip", in: "/d", mode: .multiple, removeOriginal: true)],
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

    /// Overdue counts from the newest delivered copy: a recent run that delivered nothing does not help.
    @Test func longOverdueSourceIsError() {
        let source = Fixtures.source(destinations: [cloud])
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = now.addingTimeInterval(-3600) }
        state.recordCopy(sourceId: source.id, destinationId: cloud.id, at: Fixtures.date("2026-09-20 10:00:00"))
        #expect(report([source], state).items == [
            .copiesOutdated(sourceId: source.id, OutdatedCopies(destinationIds: [cloud.id], freshElsewhere: false, noCopyAnywhere: false)),
            .severelyOverdue(sourceId: source.id),
        ])
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

    private func exportedLastMonth(_ source: Source) -> AppState {
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = Fixtures.date("2026-08-20 10:00:00") }
        state.recordCopy(sourceId: source.id, destinationId: cloud.id, at: Fixtures.date("2026-08-20 10:00:00"))
        return state
    }

    private func outdatedCloud(_ source: Source) -> AttentionItem {
        .copiesOutdated(sourceId: source.id, OutdatedCopies(destinationIds: [cloud.id], freshElsewhere: false, noCopyAnywhere: false))
    }

    @Test func dueManualExportAsksForExport() {
        let source = photos()
        #expect(report([source], exportedLastMonth(source)).items == [outdatedCloud(source), .manualExportDue(sourceId: source.id)])
    }

    @Test func foundFilesReplaceTheReminder() {
        let source = photos()
        let scan = InboxScan(files: [URL(fileURLWithPath: "/d/takeout-1.zip")], totalBytes: 12, downloadInProgress: true)
        #expect(report([source], exportedLastMonth(source), scans: [source.id: scan]).items == [
            outdatedCloud(source),
            .filesAwaitingPickup(sourceId: source.id, fileCount: 1, totalBytes: 12, downloadInProgress: true),
        ])
    }

    @Test func exportWaitingAfterTheRunButtonIsQuiet() {
        let source = photos(.manual)
        var state = AppState()
        state.updateSource(source.id) { $0.armedAt = now.addingTimeInterval(-60) }
        let result = report([source], state)
        #expect(result.items == [.waitingForFile(sourceId: source.id)])
        #expect(result.overall == .ok)
    }

    @Test func unfinishedDownloadWithoutMatchingFilesIsNotReported() {
        let source = photos()
        let scan = InboxScan(files: [], totalBytes: 0, downloadInProgress: true)
        #expect(report([source], fresh(source), scans: [source.id: scan]).items.isEmpty)
    }

    @Test func alwaysOnDestinationIsReportedWhenUnreachable() {
        let source = Fixtures.source(destinations: [cloud])
        let state = fresh(source)
        #expect(report([source], state, unavailable: [cloud.id]).items == [.destinationUnavailable(destinationId: cloud.id)])
        #expect(report([source], state).items.isEmpty)
    }

    @Test func alwaysOnDestinationNoEnabledSourceUsesIsNotMentioned() {
        var source = Fixtures.source(destinations: [cloud])
        source.enabled = false
        #expect(report([source], fresh(source), unavailable: [cloud.id]).items.isEmpty)
    }

    private func copiedToDisk(_ source: Source, at date: Date) -> AppState {
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = now.addingTimeInterval(-3600) }
        state.recordCopy(sourceId: source.id, destinationId: disk.id, at: date)
        return state
    }

    @Test func periodicDiskIsQuietUntilItsDeadline() {
        let source = Fixtures.source(destinations: [disk])
        #expect(report([source], copiedToDisk(source, at: Fixtures.date("2026-09-09 10:00:00")), unavailable: [disk.id]).overall == .ok)
        #expect(report([source], copiedToDisk(source, at: Fixtures.date("2026-08-29 10:00:00")), unavailable: [disk.id]).items == [
            .copiesOutdated(sourceId: source.id, OutdatedCopies(destinationIds: [disk.id], freshElsewhere: false, noCopyAnywhere: false)),
            .connectDestination(destinationId: disk.id),
        ])
    }

    @Test func diskUnpluggedForLongerThanItsIntervalIsAskedFor() {
        let fortnightly = Destination(name: "HDD", kind: .localFolder(path: "/h"), expectedEvery: .days(14))
        let source = Fixtures.source(destinations: [fortnightly])
        func items(copiedDaysAgo days: Double) -> [AttentionItem] {
            var state = AppState()
            state.updateSource(source.id) { $0.lastRun = now.addingTimeInterval(-3600) }
            state.recordCopy(sourceId: source.id, destinationId: fortnightly.id, at: now.addingTimeInterval(-days * 86_400))
            return reporter.report(
                config: Config(sources: [source], destinations: [fortnightly]), state: state, now: now,
                unavailableDestinations: [fortnightly.id], inboxScans: [:]
            ).items
        }
        #expect(items(copiedDaysAgo: 20).contains(.connectDestination(destinationId: fortnightly.id)))
        #expect(!items(copiedDaysAgo: 5).contains(.connectDestination(destinationId: fortnightly.id)))
    }

    @Test func disabledSourceAsksForNoDisk() {
        var source = Fixtures.source(destinations: [disk, cloud])
        source.enabled = false
        let state = fresh(source)
        #expect(report([source], state, unavailable: [disk.id, cloud.id]).items.isEmpty)

        let planner = SchedulePlanner(calendar: Fixtures.calendar)
        let config = Config(sources: [source], destinations: [cloud, disk])
        #expect(planner.nextWake(config: config, state: state, now: now, needsAttention: false) == nil)
    }

    @Test func periodicDiskWithoutAnyCopyIsAskedForAtOnce() {
        let source = Fixtures.source(destinations: [disk])
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = now.addingTimeInterval(-3600) }
        #expect(report([source], state, unavailable: [disk.id]).items == [
            .copiesOutdated(sourceId: source.id, OutdatedCopies(destinationIds: [disk.id], freshElsewhere: false, noCopyAnywhere: true)),
            .connectDestination(destinationId: disk.id),
        ])
    }

    /// The disk got yesterday's backup and was unplugged; an old copy of a disabled source must not make it overdue.
    @Test func diskCopiedYesterdayIsNotAskedForBecauseOfADisabledSource() {
        let active = Fixtures.source(name: "Active", destinations: [disk])
        var paused = Fixtures.source(name: "Paused", destinations: [disk])
        paused.enabled = false
        let config = Config(sources: [active, paused], destinations: [disk])
        var state = copiedToDisk(active, at: Fixtures.date("2026-09-27 10:00:00"))
        state.recordCopy(sourceId: paused.id, destinationId: disk.id, at: Fixtures.date("2026-08-01 00:00:00"))

        let items = reporter.report(config: config, state: state, now: now, unavailableDestinations: [disk.id], inboxScans: [:]).items
        #expect(!items.contains(.connectDestination(destinationId: disk.id)))
    }

    @Test func stepChainReportsWhereItIsStuck() {
        let now = Fixtures.date("2026-09-28 10:00:00")
        let cloud = Fixtures.localDestination("Cloud", at: URL(fileURLWithPath: "/tmp/cloud"))
        let steps = [
            SourceStep(name: "Open page", kind: .command(command: "true", timeoutSeconds: 60)),
            SourceStep(name: "File", kind: .file(instructions: "", watchPath: "~/Downloads", filePattern: "x-*.csv", fileMode: .single, includeInCopy: true, removeOriginal: true)),
        ]
        let chain = Fixtures.source(name: "Chain", steps: steps, schedule: .manual, destinations: [cloud])
        let manualFirst = Fixtures.source(
            name: "Claude",
            steps: [steps[1], steps[0]],
            schedule: .monthly,
            destinations: [cloud],
            createdAt: Fixtures.date("2026-09-01 00:00:00")
        )
        let config = Config(sources: [chain, manualFirst], destinations: [cloud])
        let reporter = StatusReporter(planner: SchedulePlanner(calendar: Fixtures.calendar))
        func items(_ state: AppState) -> [AttentionItem] {
            reporter.report(config: config, state: state, now: now, unavailableDestinations: [], inboxScans: [:]).items
        }

        var state = AppState()
        #expect(items(state) == [.manualExportDue(sourceId: manualFirst.id)])

        state.updateSource(chain.id) { $0.chain = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now) }
        state.updateSource(manualFirst.id) { $0.chain = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now, failure: "Command exited with code 1. no archives") }
        #expect(items(state) == [
            .manualExportDue(sourceId: chain.id),
            .runFailed(sourceId: manualFirst.id, message: "Command exited with code 1. no archives"),
        ])
    }

    @Test func chainBlockedByAnUnfinishedDownloadSaysSoInsteadOfTheOldError() {
        let now = Fixtures.date("2026-09-28 10:00:00")
        let cloud = Fixtures.localDestination("Cloud", at: URL(fileURLWithPath: "/tmp/cloud"))
        let steps = [
            SourceStep(name: "File", kind: .file(instructions: "", watchPath: "~/Downloads", filePattern: "manifest-*.json", fileMode: .single, includeInCopy: false, removeOriginal: true)),
            SourceStep(name: "Command", kind: .command(command: "true", timeoutSeconds: 60)),
        ]
        let source = Fixtures.source(name: "Claude", steps: steps, schedule: .manual, destinations: [cloud])
        var state = AppState()
        state.updateSource(source.id) { $0.chain = ChainState(stepIndex: 1, startedAt: now, stepEnteredAt: now, failure: "links expired") }
        let reporter = StatusReporter(planner: SchedulePlanner(calendar: Fixtures.calendar))
        func items(_ scan: InboxScan) -> [AttentionItem] {
            reporter.report(
                config: Config(sources: [source], destinations: [cloud]),
                state: state,
                now: now,
                unavailableDestinations: [],
                inboxScans: [source.id: scan]
            ).items
        }
        let manifest = URL(fileURLWithPath: "/tmp/manifest-b.json")

        #expect(items(InboxScan(files: [manifest], totalBytes: 2, downloadInProgress: true)) == [
            .filesAwaitingPickup(sourceId: source.id, fileCount: 1, totalBytes: 2, downloadInProgress: true),
        ])
        #expect(items(InboxScan(files: [manifest], totalBytes: 2, downloadInProgress: false)) == [.runFailed(sourceId: source.id, message: "links expired")])
        #expect(items(.empty) == [.runFailed(sourceId: source.id, message: "links expired")])
    }

    @Test func unpluggedDiskWithAFreshCopyIsNotMentioned() {
        let source = Fixtures.source(destinations: [cloud, disk])
        #expect(report([source], fresh(source), unavailable: [disk.id]).items.isEmpty)
    }

    @Test func chainBusyWithAnAutomaticStepAsksNothingOfThePerson() {
        let source = Fixtures.source(
            name: "Claude",
            steps: [.file("manifest-*.json", in: "/d"), .command("download", timeoutSeconds: 60)],
            schedule: .monthly,
            destinations: [cloud]
        )
        var state = fresh(source)
        state.updateSource(source.id) {
            $0.chain = ChainState(stepIndex: 1, stepId: source.steps[1].id, startedAt: now, stepEnteredAt: now, startedBy: .schedule)
        }
        #expect(report([source], state).items.isEmpty)
    }

    @Test func connectedDeviceIsNotWaitedFor() {
        let source = Fixtures.source(name: "PocketBook", steps: [.device("/Volumes/PB"), .folder("/Volumes/PB/Books")], destinations: [cloud])
        var state = fresh(source)
        state.updateSource(source.id) {
            $0.chain = ChainState(stepIndex: 0, stepId: source.steps[0].id, startedAt: now, stepEnteredAt: now, startedBy: .button)
        }
        let result = reporter.report(
            config: Config(sources: [source], destinations: [cloud]),
            state: state,
            now: now,
            unavailableDestinations: [],
            inboxScans: [:],
            missingDevices: []
        )
        #expect(result.items.isEmpty)
    }

    enum FreshnessCase: String, CaseIterable {
        case freshCopiesEverywhere
        case staleAlwaysConnectedDestination
        case bothDestinationsRefused
        case diskEvery30DaysWithCopy10DaysOld
        case diskEvery30DaysPastItsDeadline
        case neverDeliveredAfterRuns
        case failedRun
        case severelyOverdueByDeliveredAgeDespiteRecentRun
        case disabled
        case neverRun
    }

    private struct Expectation {
        var items: (Source) -> [AttentionItem]
        var isFresh: Bool
        var isExpected = true
        var overall: OverallStatus
    }

    /// The status of a source is built from the copies found on its destinations, never from the absence of known problems (5.5).
    @Test(arguments: FreshnessCase.allCases)
    func sourceStatusFollowsDeliveredCopies(_ scenario: FreshnessCase) {
        let nas = Destination(name: "NAS", kind: .localFolder(path: "/n"))
        let created = now.addingTimeInterval(-7200)
        var source = Fixtures.source(destinations: [cloud, nas], createdAt: created)
        var state = AppState()
        var unavailable: Set<UUID> = []
        let ranAnHourAgo = now.addingTimeInterval(-3600)
        func ran(at date: Date = ranAnHourAgo) { state.updateSource(source.id) { $0.lastRun = date } }
        func copy(to destination: Destination, at date: Date) {
            state.recordCopy(sourceId: source.id, destinationId: destination.id, at: date)
        }
        func outdated(_ destinations: [Destination], freshElsewhere: Bool, noCopy: Bool) -> AttentionItem {
            .copiesOutdated(sourceId: source.id, OutdatedCopies(destinationIds: destinations.map(\.id), freshElsewhere: freshElsewhere, noCopyAnywhere: noCopy))
        }
        let expectation: Expectation
        switch scenario {
        case .freshCopiesEverywhere:
            ran()
            copy(to: cloud, at: ranAnHourAgo)
            copy(to: nas, at: ranAnHourAgo)
            expectation = Expectation(items: { _ in [] }, isFresh: true, overall: .ok)
        case .staleAlwaysConnectedDestination:
            ran()
            copy(to: cloud, at: ranAnHourAgo)
            copy(to: nas, at: Fixtures.date("2026-09-26 10:00:00"))
            expectation = Expectation(items: { _ in [outdated([nas], freshElsewhere: true, noCopy: false)] }, isFresh: false, overall: .attention)
        case .bothDestinationsRefused:
            ran()
            unavailable = [cloud.id, nas.id]
            expectation = Expectation(
                items: { _ in [
                    outdated([cloud, nas], freshElsewhere: false, noCopy: true),
                    .destinationUnavailable(destinationId: cloud.id),
                    .destinationUnavailable(destinationId: nas.id),
                ] },
                isFresh: false,
                overall: .attention
            )
        case .diskEvery30DaysWithCopy10DaysOld:
            source = Fixtures.source(destinations: [cloud, disk], createdAt: created)
            ran()
            copy(to: cloud, at: ranAnHourAgo)
            copy(to: disk, at: Fixtures.date("2026-09-18 10:00:00"))
            unavailable = [disk.id]
            expectation = Expectation(items: { _ in [] }, isFresh: true, overall: .ok)
        case .diskEvery30DaysPastItsDeadline:
            source = Fixtures.source(destinations: [cloud, disk], createdAt: created)
            ran()
            copy(to: cloud, at: ranAnHourAgo)
            copy(to: disk, at: Fixtures.date("2026-08-28 10:00:00"))
            unavailable = [disk.id]
            expectation = Expectation(
                items: { _ in [outdated([disk], freshElsewhere: true, noCopy: false), .connectDestination(destinationId: disk.id)] },
                isFresh: false,
                overall: .attention
            )
        case .neverDeliveredAfterRuns:
            ran()
            expectation = Expectation(items: { _ in [outdated([cloud, nas], freshElsewhere: false, noCopy: true)] }, isFresh: false, overall: .attention)
        case .failedRun:
            ran()
            copy(to: cloud, at: ranAnHourAgo)
            copy(to: nas, at: ranAnHourAgo)
            state.updateSource(source.id) { $0.lastError = "quota" }
            expectation = Expectation(items: { [.runFailed(sourceId: $0.id, message: "quota")] }, isFresh: true, overall: .error)
        case .severelyOverdueByDeliveredAgeDespiteRecentRun:
            ran()
            copy(to: cloud, at: Fixtures.date("2026-09-24 09:00:00"))
            copy(to: nas, at: Fixtures.date("2026-09-24 09:00:00"))
            expectation = Expectation(
                items: { [outdated([cloud, nas], freshElsewhere: false, noCopy: false), .severelyOverdue(sourceId: $0.id)] },
                isFresh: false,
                overall: .error
            )
        case .disabled:
            source.enabled = false
            ran()
            expectation = Expectation(items: { _ in [] }, isFresh: false, isExpected: false, overall: .ok)
        case .neverRun:
            expectation = Expectation(items: { _ in [] }, isFresh: false, isExpected: false, overall: .ok)
        }

        let result = reporter.report(
            config: Config(sources: [source], destinations: [cloud, nas, disk]),
            state: state,
            now: now,
            unavailableDestinations: unavailable,
            inboxScans: [:]
        )
        #expect(result.items == expectation.items(source))
        #expect(result.fresh.contains(source.id) == expectation.isFresh)
        #expect(result.expected.contains(source.id) == expectation.isExpected)
        #expect(result.overall == expectation.overall)
    }

    @Test func overallIsFineOnlyWhenEveryExpectedSourceProvedAFreshCopy() {
        let first = UUID()
        let second = UUID()
        #expect(StatusReport(items: [], fresh: [first, second], expected: [first, second]).overall == .ok)
        #expect(StatusReport(items: [], fresh: [first], expected: [first, second]).overall == .attention)
        #expect(StatusReport(items: [.waitingForFile(sourceId: second)], fresh: [first], expected: [first]).overall == .ok)
        #expect(StatusReport(items: [.severelyOverdue(sourceId: first)], fresh: [], expected: [first]).overall == .error)

        let running = StatusReport(
            items: [.copiesOutdated(sourceId: second, OutdatedCopies(destinationIds: [], freshElsewhere: false, noCopyAnywhere: true))],
            fresh: [first],
            expected: [first, second]
        ).excludingSources([second])
        #expect(running.items.isEmpty)
        #expect(running.overall == .ok)
    }
}

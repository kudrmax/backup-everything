import BackupCore
import Foundation
import Testing
@testable import BackupEverything

/// Every green mark comes from one check, and the headline, the menu and the icons say the same thing.
@MainActor
struct StatusSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let ssd = Destination(name: "TEST-BE-SSD", kind: .localFolder(path: "/Volumes/TEST-BE-SSD/Backups"))
    private let nas = Destination(name: "TEST-BE-NAS", kind: .localFolder(path: "/Volumes/TEST-BE-NAS/Backups"))

    private func source(_ destinations: [Destination], name: String = "Notes") -> Source {
        Source(name: name, slug: name.lowercased(), steps: [.folder("/a", excludes: [])], schedule: .daily, destinationIds: destinations.map(\.id), createdAt: now)
    }

    private func delivered(_ source: Source, to destinations: [Destination]) -> (AppState, [RunRecord]) {
        var state = AppState()
        state.updateSource(source.id) { $0.lastRun = now }
        for destination in destinations {
            state.recordDelivery(sourceId: source.id, destinationId: destination.id, snapshotName: "n", collectedAt: now)
        }
        let run = RunRecord(
            sourceId: source.id, sourceName: source.name, trigger: .scheduled, startedAt: now, finishedAt: now,
            deliveries: [ssd, nas].map { Delivery(destinationId: $0.id, destinationName: $0.name, outcome: .delivered(pruned: 0, warning: nil)) }
        )
        return (state, [run])
    }

    private func outdated(_ source: Source, _ destinations: [Destination], noCopy: Bool = false) -> AttentionItem {
        .copiesOutdated(sourceId: source.id, OutdatedCopies(destinationIds: destinations.map(\.id), freshElsewhere: !noCopy, noCopyAnywhere: noCopy))
    }

    @Test func nothingIsGreenBeforeTheFirstCheck() {
        let notes = source([ssd])
        let (state, runs) = delivered(notes, to: [ssd])
        let snapshot = StatusSnapshot(config: Config(sources: [notes], destinations: [ssd]), state: state, checked: nil, running: [], runs: runs)
        #expect(snapshot.delivery(of: notes, to: ssd) == .unconfirmed)
        #expect(snapshot.overall == nil)
        #expect(!snapshot.isAllGood)
        #expect(snapshot.headline(isWorking: false) == "Checking…")
        #expect(snapshot.status(of: notes, lastBackup: now).severity == .ok)
        #expect(snapshot.status(of: notes, lastBackup: now) != .ok)
    }

    /// The history says the copy was delivered, but the check found it gone: the icon must not be green.
    @Test func destinationIconFollowsTheCheckNotTheHistory() {
        let notes = source([ssd, nas])
        var (state, runs) = delivered(notes, to: [ssd, nas])
        state.forgetDelivery(sourceId: notes.id, destinationId: nas.id)
        let report = StatusReport(items: [outdated(notes, [nas])], expected: [notes.id])
        let snapshot = StatusSnapshot(config: Config(sources: [notes], destinations: [ssd, nas]), state: state, checked: report, running: [], runs: runs)
        #expect(snapshot.delivery(of: notes, to: ssd) == .delivered)
        #expect(snapshot.delivery(of: notes, to: nas) == .none)
    }

    /// A source being backed up keeps what the check proved: its stale copy stays orange, though it is not counted.
    @Test func runningSourceIsNeverUpgradedToGreen() {
        let notes = source([ssd])
        let (state, runs) = delivered(notes, to: [ssd])
        let report = StatusReport(items: [outdated(notes, [ssd])], expected: [notes.id])
        let snapshot = StatusSnapshot(config: Config(sources: [notes], destinations: [ssd]), state: state, checked: report, running: [notes.id], runs: runs)
        #expect(snapshot.delivery(of: notes, to: ssd) == .outdated)
        #expect(snapshot.status(of: notes, lastBackup: now) != .ok)
        #expect(snapshot.overall == .ok)
        #expect(snapshot.headline(isWorking: true) == "Backing up")
    }

    /// A destination no enabled source uses is not part of the backup health; one in use is, in every place at once.
    @Test func headlineMenuAndIconAgreeAboutDestinations() {
        let notes = source([ssd])
        let (state, runs) = delivered(notes, to: [ssd])
        let report = StatusReport(items: [], fresh: [notes.id], expected: [notes.id])
        let exFAT: DiskCheck = .unsupportedFormat(name: "TEST-BE-NAS", format: "exFAT")

        let unused = StatusSnapshot(
            config: Config(sources: [notes], destinations: [ssd, nas]), state: state, checked: report, running: [], disks: [nas.id: exFAT], runs: runs
        )
        #expect(unused.menuLines.isEmpty)
        #expect(unused.overall == .ok)
        #expect(unused.isAllGood)
        #expect(unused.headline(isWorking: false) == "All good")
        #expect(!unused.isUsed(nas))

        let used = StatusSnapshot(
            config: Config(sources: [notes], destinations: [ssd, nas]), state: state, checked: report, running: [], disks: [ssd.id: exFAT], runs: runs
        )
        #expect(used.menuLines.map(\.text) == ["formatted as exFAT, needs APFS"])
        #expect(used.overall == .attention)
        #expect(!used.isAllGood)
        #expect(used.headline(isWorking: false) == "Needs your action")
    }

    @Test func headlineCountsTheErrorsTheMenuShows() {
        let first = source([ssd], name: "First")
        let second = source([ssd], name: "Second")
        let config = Config(sources: [first, second], destinations: [ssd])
        func headline(_ items: [AttentionItem], fresh: Set<UUID> = [], expected: Set<UUID> = [], isWorking: Bool = false) -> String {
            StatusSnapshot(config: config, state: AppState(), checked: StatusReport(items: items, fresh: fresh, expected: expected), running: [])
                .headline(isWorking: isWorking)
        }
        #expect(headline([]) == "All good")
        #expect(headline([], isWorking: true) == "Backing up")
        #expect(headline([.waitingForFile(sourceId: first.id)]) == "All good")
        #expect(headline([.manualExportDue(sourceId: first.id)]) == "Needs your action")
        #expect(headline([], fresh: [first.id], expected: [first.id, second.id]) == "Needs your action")
        #expect(headline([], fresh: [first.id], expected: [first.id, second.id], isWorking: true) == "Needs your action")
        #expect(headline([.runFailed(sourceId: first.id, message: "a")], isWorking: true) == "1 error")
        #expect(headline([
            .runFailed(sourceId: first.id, message: "a"),
            .severelyOverdue(sourceId: first.id),
            .runFailed(sourceId: second.id, message: "b"),
            .manualExportDue(sourceId: second.id),
        ]) == "2 errors")
    }

    /// Red for a long-missing backup still says why copies are missing.
    @Test func longOverdueSourceShowsTheCauseWithTheSeverity() {
        let notes = source([ssd, nas])
        var state = AppState()
        state.updateSource(notes.id) { $0.lastRun = now }
        let report = StatusReport(items: [outdated(notes, [ssd, nas], noCopy: true), .severelyOverdue(sourceId: notes.id)], expected: [notes.id])
        let disks: [UUID: DiskCheck] = [
            ssd.id: .unsupportedFormat(name: "TEST-BE-SSD", format: "exFAT"),
            nas.id: .unsupportedFormat(name: "TEST-BE-NAS", format: "exFAT"),
        ]
        let snapshot = StatusSnapshot(config: Config(sources: [notes], destinations: [ssd, nas]), state: state, checked: report, running: [], disks: disks)
        let status = snapshot.status(of: notes, lastBackup: nil)
        #expect(status.severity == .error)
        #expect(status.note == "no copy anywhere · formatted as exFAT, needs APFS · no backup for a long time")
        #expect(status.text.hasPrefix("Backup is long overdue\nNo copy anywhere"))
    }
}

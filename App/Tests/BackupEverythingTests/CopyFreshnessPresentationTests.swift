import BackupCore
import Foundation
import Testing
@testable import BackupEverything

/// A source looks fine only with a fresh copy on every destination; otherwise it says which destination lacks one and why.
@MainActor
struct CopyFreshnessPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let ssd = Destination(name: "TEST-BE-SSD", kind: .localFolder(path: "/Volumes/TEST-BE-SSD/Backups"))
    private let nas = Destination(name: "TEST-BE-NAS", kind: .localFolder(path: "/Volumes/TEST-BE-NAS/Backups"))
    private let hdd = Destination(name: "TEST-BE-HDD", kind: .localFolder(path: "/Volumes/TEST-BE-HDD/Backups"), expectedEvery: .days(30))

    private func source(_ destinations: [Destination]) -> Source {
        Source(name: "Notes", slug: "notes", steps: [.folder("/a", excludes: [])], schedule: .daily, destinationIds: destinations.map(\.id), createdAt: now)
    }

    private func outdated(_ source: Source, _ destinations: [Destination], freshElsewhere: Bool, noCopy: Bool) -> AttentionItem {
        .copiesOutdated(sourceId: source.id, OutdatedCopies(destinationIds: destinations.map(\.id), freshElsewhere: freshElsewhere, noCopyAnywhere: noCopy))
    }

    /// The case found in the sandbox: both disks refused as not APFS, the copy went nowhere, yet the row was green.
    @Test func sourceWhoseDisksWereBothRefusedSaysThereIsNoCopyAnywhere() {
        let notes = source([ssd, nas])
        let config = Config(sources: [notes], destinations: [ssd, nas])
        var state = AppState()
        state.updateSource(notes.id) { $0.lastRun = now }
        state.debts = [ssd, nas].map { Debt(sourceId: notes.id, destinationId: $0.id, since: now, elsewhere: false) }
        let report = StatusReport(
            items: [outdated(notes, [ssd, nas], freshElsewhere: false, noCopy: true)],
            fresh: [],
            expected: [notes.id]
        )
        let disks: [UUID: DiskCheck] = [
            ssd.id: .unsupportedFormat(name: "TEST-BE-SSD", format: "exFAT"),
            nas.id: .unsupportedFormat(name: "TEST-BE-NAS", format: "exFAT"),
        ]
        let gaps = CopyGaps(config: config, state: state, report: report, unavailable: [ssd.id, nas.id], disks: disks, now: now)

        let status = SourceStatus.of(notes, report: report, lastBackup: nil, gaps: gaps)
        #expect(status.severity == .attention)
        #expect(status.note == "no copy anywhere · formatted as exFAT, needs APFS")
        #expect(status.text == "No copy anywhere\n“TEST-BE-SSD”: formatted as exFAT, needs APFS\n“TEST-BE-NAS”: formatted as exFAT, needs APFS")
        #expect(SourceMark.of(stage: nil, isEnabled: true, status: status) == .severity(.attention))
        #expect(StatusSnapshot(config: config, state: state, checked: report, running: [], unavailable: [ssd.id, nas.id], disks: disks, now: now)
            .headline(isWorking: false) == "Needs your action")
        #expect(MenuLines.of(config: config, state: state, report: report, unavailable: [ssd.id, nas.id], disks: disks, now: now) == [
            MenuLine(subject: .source(notes), severity: .attention, text: "no copy anywhere · formatted as exFAT, needs APFS", canPickUp: false),
            MenuLine(subject: .destination(ssd), severity: .attention, text: "formatted as exFAT, needs APFS", canPickUp: false),
            MenuLine(subject: .destination(nas), severity: .attention, text: "formatted as exFAT, needs APFS", canPickUp: false),
        ])
    }

    @Test func oneStaleDestinationIsNamedWithItsReason() {
        let notes = source([ssd, nas])
        let config = Config(sources: [notes], destinations: [ssd, nas])
        var state = AppState()
        state.recordDelivery(sourceId: notes.id, destinationId: nas.id, snapshotName: nil, collectedAt: now.addingTimeInterval(-3 * 86_400))
        let report = StatusReport(items: [outdated(notes, [nas], freshElsewhere: true, noCopy: false)], expected: [notes.id])
        let gaps = CopyGaps(config: config, state: state, report: report, now: now)

        let status = SourceStatus.of(notes, report: report, lastBackup: now, gaps: gaps)
        #expect(status.note == "no fresh copy on “TEST-BE-NAS” · last copy 3 days ago")
        #expect(status.severity == .attention)
    }

    @Test func severalStaleDestinationsWithDifferentReasonsAreListedInTheTip() {
        let notes = source([ssd, nas, hdd])
        let config = Config(sources: [notes], destinations: [ssd, nas, hdd])
        var state = AppState()
        state.recordDelivery(sourceId: notes.id, destinationId: ssd.id, snapshotName: nil, collectedAt: now.addingTimeInterval(-2 * 86_400))
        state.recordDelivery(sourceId: notes.id, destinationId: hdd.id, snapshotName: nil, collectedAt: now.addingTimeInterval(-40 * 86_400))
        state.debts = [Debt(sourceId: notes.id, destinationId: hdd.id, since: now.addingTimeInterval(-39 * 86_400))]
        let report = StatusReport(
            items: [outdated(notes, [ssd, nas, hdd], freshElsewhere: false, noCopy: false), .connectDestination(destinationId: hdd.id)],
            expected: [notes.id]
        )
        let gaps = CopyGaps(config: config, state: state, report: report, unavailable: [hdd.id], now: now)

        let status = SourceStatus.of(notes, report: report, lastBackup: now, gaps: gaps)
        #expect(status.note == "no fresh copy anywhere")
        #expect(status.text == "No fresh copy anywhere\n“TEST-BE-SSD”: last copy 2 days ago\n“TEST-BE-NAS”: no copy yet\n“TEST-BE-HDD”: time to connect")
    }

    @Test(arguments: [
        (DiskCheck.otherDisk(DiskIdentity(uuid: "U", name: "TEST-BE-X")), "another disk named “TEST-BE-X” is connected"),
        (.notConfirmed(connected: nil), "disk not confirmed"),
        (.unidentified(name: "TEST-BE-X"), "can’t read the ID of disk “TEST-BE-X”"),
        (.unsupportedFormat(name: "TEST-BE-X", format: "exFAT"), "formatted as exFAT, needs APFS"),
    ])
    func reasonComesFromWhatIsWrongWithTheDisk(check: DiskCheck, reason: String) {
        let notes = source([ssd])
        let gaps = CopyGaps(config: Config(sources: [notes], destinations: [ssd]), state: AppState(), report: StatusReport(items: []), unavailable: [ssd.id], disks: [ssd.id: check])
        #expect(gaps.gap(of: notes.id, at: ssd.id) == CopyGap(destinationName: "TEST-BE-SSD", reason: reason))
    }

    @Test func reasonComesFromTheDestinationThenFromTheCopy() {
        let notes = source([ssd, hdd])
        let config = Config(sources: [notes], destinations: [ssd, hdd])
        var state = AppState()
        func reason(_ destination: Destination, report: StatusReport = StatusReport(items: []), unavailable: Set<UUID> = [], runs: [RunRecord] = [], missing: MissingFolder? = nil) -> String? {
            CopyGaps(
                config: config, state: state, report: report, unavailable: unavailable,
                missingFolders: missing.map { [destination.id: $0] } ?? [:], runs: runs, now: now
            ).gap(of: notes.id, at: destination.id)?.reason
        }
        #expect(reason(ssd) == "no copy yet")
        #expect(reason(ssd, unavailable: [ssd.id]) == "unavailable")
        #expect(reason(hdd, unavailable: [hdd.id]) == "waiting for connection")
        #expect(reason(ssd, report: StatusReport(items: [.destinationUnavailable(destinationId: ssd.id)]), unavailable: [ssd.id]) == "unavailable")
        #expect(reason(hdd, report: StatusReport(items: [.connectDestination(destinationId: hdd.id)]), unavailable: [hdd.id]) == "time to connect")
        #expect(reason(ssd, missing: MissingFolder(path: "/Volumes/TEST-BE-SSD/Backups", disk: "TEST-BE-SSD")) == "folder not found")

        state.debts = [Debt(sourceId: notes.id, destinationId: ssd.id, since: now)]
        #expect(reason(ssd) == "waiting to be written")
        let failed = RunRecord(
            sourceId: notes.id, sourceName: "Notes", trigger: .scheduled, startedAt: now, finishedAt: now,
            deliveries: [Delivery(destinationId: ssd.id, destinationName: "TEST-BE-SSD", outcome: .failed(message: "Disk full: 2 GB needed"))]
        )
        #expect(reason(ssd, runs: [failed]) == "couldn’t write: Disk full")

        state.debts = []
        state.recordDelivery(sourceId: notes.id, destinationId: ssd.id, snapshotName: nil, collectedAt: now.addingTimeInterval(-7200))
        #expect(reason(ssd) == "last copy 2 hours ago")
    }

    /// “Waiting for a file” is calm, but not while the copies are stale; a reminder to export outranks the stale copy.
    @Test func staleCopyRanksBetweenTheActionsAndTheCalmWaits() {
        let notes = source([ssd])
        let stale = outdated(notes, [ssd], freshElsewhere: false, noCopy: false)
        func status(_ items: [AttentionItem]) -> SourceStatus {
            SourceStatus.of(notes, report: StatusReport(items: items, expected: [notes.id]), lastBackup: now)
        }
        #expect(status([stale, .waitingForFile(sourceId: notes.id)]).severity == .attention)
        #expect(status([stale, .manualExportDue(sourceId: notes.id)]) == .exportDue)
        #expect(status([stale, .runFailed(sourceId: notes.id, message: "boom")]) == .failed("boom"))
    }

    @Test func onlyAProvedFreshCopyIsGreen() {
        let notes = source([ssd])
        let fresh = SourceStatus.of(notes, report: StatusReport(items: [], fresh: [notes.id], expected: [notes.id]), lastBackup: now)
        #expect(SourceMark.of(stage: nil, isEnabled: true, status: fresh) == .severity(.ok))
        let neverRun = SourceStatus.of(notes, report: StatusReport(items: []), lastBackup: nil)
        #expect(neverRun == .neverRun)
        #expect(SourceMark.of(stage: nil, isEnabled: true, status: neverRun) == .symbol("circle.dashed"))
        let unproved = SourceStatus.of(notes, report: StatusReport(items: []), lastBackup: now)
        #expect(unproved == .unconfirmed)
        #expect(SourceMark.of(stage: nil, isEnabled: true, status: unproved) == .symbol("circle.dashed"))
        var disabled = notes
        disabled.enabled = false
        #expect(SourceStatus.of(disabled, report: StatusReport(items: [], expected: [notes.id]), lastBackup: now) == .disabled)
    }

    @Test func menuBarIsTintedWhileAnExpectedCopyIsNotProven() {
        #expect(MenuBarTint.of(StatusReport(items: [], fresh: [UUID()], expected: [UUID()]).overall) == .attention)
    }

    @Test func copyOlderThanItsRhythmIsMarkedOnTheDestinationIcon() {
        let notes = source([ssd, nas])
        var state = AppState()
        for destination in [ssd, nas] {
            state.recordDelivery(sourceId: notes.id, destinationId: destination.id, snapshotName: nil, collectedAt: now)
        }
        let report = StatusReport(items: [outdated(notes, [nas], freshElsewhere: true, noCopy: false)], expected: [notes.id])
        let snapshot = StatusSnapshot(config: Config(sources: [notes], destinations: [ssd, nas]), state: state, checked: report, running: [])
        #expect(snapshot.delivery(of: notes, to: nas) == .outdated)
        #expect(snapshot.delivery(of: notes, to: ssd) == .delivered)
        #expect(DeliveryState.outdated.mark == "exclamationmark.circle.fill")
        state.debts = [Debt(sourceId: notes.id, destinationId: nas.id, since: now)]
        #expect(StatusSnapshot(config: Config(sources: [notes], destinations: [ssd, nas]), state: state, checked: report, running: [])
            .delivery(of: notes, to: nas) == .waiting)
    }
}

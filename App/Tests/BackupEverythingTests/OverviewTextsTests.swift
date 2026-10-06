import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct OverviewTextsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func ageIsShortAndCoarse() {
        #expect(Texts.age(nil, now: now) == "—")
        #expect(Texts.age(now.addingTimeInterval(-20), now: now) == "now")
        #expect(Texts.age(now.addingTimeInterval(-5 * 60), now: now) == "5 min")
        #expect(Texts.age(now.addingTimeInterval(-3 * 3600), now: now) == "3 h")
        #expect(Texts.age(now.addingTimeInterval(-9 * 86_400), now: now) == "9 d")
        #expect(Texts.age(now.addingTimeInterval(-70 * 86_400), now: now) == "2 mo")
        #expect(Texts.age(now.addingTimeInterval(-800 * 86_400), now: now) == "2 y")
    }

    @Test(arguments: [(1, "1 error"), (2, "2 errors"), (5, "5 errors"), (11, "11 errors"), (21, "21 errors"), (24, "24 errors")])
    func errorCountAgreesWithTheNumber(count: Int, expected: String) {
        #expect(Texts.errors(count) == expected)
    }

    @Test(arguments: [(1, "1 file"), (3, "3 files"), (5, "5 files"), (12, "12 files"), (22, "22 files")])
    func fileCountAgreesWithTheNumber(count: Int, expected: String) {
        #expect(Texts.files(count) == expected)
    }

    @Test func headlineSummarisesTheReport() {
        let first = UUID()
        let second = UUID()
        #expect(Texts.headline(StatusReport(items: [])) == "All good")
        #expect(Texts.headline(StatusReport(items: [.waitingForFile(sourceId: first)])) == "All good")
        #expect(Texts.headline(StatusReport(items: [.manualExportDue(sourceId: first)])) == "Needs your action")
        #expect(Texts.headline(StatusReport(items: [
            .runFailed(sourceId: first, message: "a"),
            .severelyOverdue(sourceId: first),
            .runFailed(sourceId: second, message: "b"),
            .manualExportDue(sourceId: second),
        ])) == "2 errors")
    }

    @Test func rowNoteIsEmptyWhenNothingNeedsSaying() {
        #expect(SourceStatus.ok.note == nil)
        #expect(SourceStatus.neverRun.note == nil)
        #expect(SourceStatus.disabled.note == "disabled")
        #expect(SourceStatus.failed("disk dropped off").note == "disk dropped off")
        #expect(SourceStatus.failed("Command exited with code 1. fatal: early EOF").errorMessage == "Command exited with code 1. fatal: early EOF")
        #expect(SourceStatus.overdue.errorMessage == nil)
        #expect(SourceStatus.warning("Could not clean up old copies: “a.deleting”: busy").note == "Could not clean up old copies")
        #expect(SourceStatus.warning("x").severity == .attention)
        #expect(SourceStatus.failed("Source path not found: /Users/max/Obsidian").note == "Source path not found")
        #expect(SourceStatus.failed("Command exited with code 1. gh: run gh auth login").note == "gh: run gh auth login")
        #expect(SourceStatus.failed("Command exited with code 1. downloaded 0 of 1\nArchives not downloaded: a.zip. Request the export again.\n").note == "Archives not downloaded: a.zip. Request the export again.")
        #expect(SourceStatus.failed("Command did not finish within 60 s and was stopped. ").note == "Command did not finish within 60 s and was stopped")
        #expect(SourceStatus.failed("rclone failed: quota exceeded").note == "rclone failed")
        #expect(SourceStatus.filesFound(count: 3, bytes: 12_000_000_000, downloading: false).note == "3 files · 12 GB")
        #expect(SourceStatus.filesFound(count: 1, bytes: 5_000_000, downloading: true).note == "1 file · 5 MB · downloading")
        #expect(SourceStatus.exportDue.note == "time to export")
        #expect(SourceStatus.waiting.note == "waiting for a file")
        #expect(SourceStatus.waiting.severity == .ok)
        #expect(SourceStatus.deviceDue.note == "time to connect")
        #expect(SourceStatus.deviceDue.severity == .attention)
        #expect(SourceStatus.waitingForDevice.note == "waiting for the device")
        #expect(SourceStatus.waitingForDevice.severity == .ok)
        #expect(SourceStatus.noDestinations.note == "no destination chosen")
        #expect(SourceStatus.overdue.note == "no backup for a long time")
    }

    @Test(arguments: [(0, "0 copies"), (1, "1 copy"), (3, "3 copies"), (14, "14 copies"), (21, "21 copies")])
    func copyCountAgreesWithTheNumber(count: Int, expected: String) {
        #expect(Texts.copies(count) == expected)
    }

    @Test func destinationConditionPrefersReportedProblems() {
        let id = UUID()
        #expect(DestinationCondition.of(id, report: StatusReport(items: []), unavailable: []) == .available)
        #expect(DestinationCondition.of(id, report: StatusReport(items: []), unavailable: [id]) == .offline)
        #expect(DestinationCondition.of(id, report: StatusReport(items: [.connectDestination(destinationId: id)]), unavailable: [id]) == .needsConnection)
        #expect(DestinationCondition.of(id, report: StatusReport(items: [.destinationUnavailable(destinationId: id)]), unavailable: [id]) == .unreachable)
        #expect(DestinationCondition.of(UUID(), report: StatusReport(items: [.connectDestination(destinationId: id)]), unavailable: []) == .available)
    }

    @Test func runningSourcesDoNotShowTheirOldProblems() {
        let running = UUID()
        let idle = UUID()
        let disk = UUID()
        let report = StatusReport(items: [
            .runFailed(sourceId: running, message: "network"),
            .deliveryWarning(sourceId: running, message: "Could not clean up old copies: busy"),
            .severelyOverdue(sourceId: running),
            .runFailed(sourceId: idle, message: "disk"),
            .connectDestination(destinationId: disk),
        ])
        #expect(LiveReport.of(report, running: [running]).items == [
            .runFailed(sourceId: idle, message: "disk"),
            .connectDestination(destinationId: disk),
        ])
        #expect(LiveReport.of(report, running: []).items == report.items)
    }

    @Test func headlineSaysThatABackupIsRunningWhenNothingElseNeedsAttention() {
        #expect(Texts.headline(StatusReport(items: []), isWorking: true) == "Backing up")
        #expect(Texts.headline(StatusReport(items: [.runFailed(sourceId: UUID(), message: "a")]), isWorking: true) == "1 error")
        #expect(Texts.headline(StatusReport(items: []), isWorking: false) == "All good")
    }

    @Test func menuBarIconIsTintedOnlyWhenSomethingNeedsAttention() {
        #expect(MenuBarTint.of(.ok) == .standard)
        #expect(MenuBarTint.of(.attention) == .attention)
        #expect(MenuBarTint.of(.error) == .error)
    }

    @Test func chainWaitingForAFileNeedsAttention() {
        let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/tmp/cloud"))
        let source = Source(
            name: "Chain",
            slug: "chain",
            steps: [],
            schedule: .manual,
            destinationIds: [cloud.id],
            createdAt: now
        )
        let report = StatusReport(items: [.deviceDue(sourceId: source.id)])
        let status = SourceStatus.of(source, report: report, lastBackup: now)
        #expect(status == .deviceDue)
        #expect(status.severity == .attention)
        #expect(LiveReport.of(report, running: [source.id]).items.isEmpty)
    }
}

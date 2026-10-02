import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct TextsTests {
    private let cloud = Destination(name: "Cloud", kind: .localFolder(path: "/c"))
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/h"), expectedEvery: .days(30))
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ name: String) -> Source {
        Source(name: name, slug: name.lowercased(), steps: [.folder("/a", excludes: [])], schedule: .daily, createdAt: now)
    }

    @Test func menuListsOneLinePerProblemWithErrorsFirst() {
        let photos = source("Google Photos")
        let github = source("GitHub")
        let healthy = source("Obsidian")
        let config = Config(sources: [photos, github, healthy], destinations: [cloud, disk])
        let report = StatusReport(items: [
            .filesAwaitingPickup(sourceId: photos.id, fileCount: 2, totalBytes: 23_000_000_000, downloadInProgress: false),
            .runFailed(sourceId: github.id, message: "Command exited with code 1. fatal: early EOF"),
            .severelyOverdue(sourceId: github.id),
            .connectDestination(destinationId: disk.id),
        ])

        let lines = MenuLines.of(config: config, state: AppState(), report: report, unavailable: [disk.id])

        #expect(lines == [
            MenuLine(subject: .source(github), severity: .error, text: "fatal: early EOF", canPickUp: false),
            MenuLine(subject: .source(photos), severity: .attention, text: "2 files · 23 GB", canPickUp: true),
            MenuLine(subject: .destination(disk), severity: .attention, text: "time to connect", canPickUp: false),
        ])
    }

    @Test func menuHasNoLinesWhenNothingNeedsAttention() {
        let config = Config(sources: [source("Obsidian")], destinations: [cloud, disk])
        #expect(MenuLines.of(config: config, state: AppState(), report: StatusReport(items: []), unavailable: [disk.id]).isEmpty)
    }

    @Test func filesStillDownloadingCannotBePickedUp() {
        let photos = source("Google Photos")
        let report = StatusReport(items: [.filesAwaitingPickup(sourceId: photos.id, fileCount: 1, totalBytes: 5_000_000, downloadInProgress: true)])
        let lines = MenuLines.of(config: Config(sources: [photos]), state: AppState(), report: report, unavailable: [])
        #expect(lines.map(\.text) == ["1 file · 5 MB · downloading"])
        #expect(lines.map(\.canPickUp) == [false])
    }

    @Test func runSummaryNamesTheWorstOutcomeFirst() {
        func run(collectError: String? = nil, _ outcomes: [DeliveryOutcome]) -> RunRecord {
            RunRecord(
                sourceId: UUID(), sourceName: "Obsidian", trigger: .scheduled, startedAt: now, finishedAt: now,
                collectError: collectError,
                deliveries: outcomes.map { Delivery(destinationId: UUID(), destinationName: "d", outcome: $0) }
            )
        }
        #expect(Texts.runSummary(run(collectError: "no folder", [])) == "Error: no folder")
        #expect(Texts.runSummary(run([.delivered(pruned: 0, warning: nil), .failed(message: "quota")])) == "Delivered: 1 of 2. Error: quota")
        #expect(Texts.runSummary(run([.delivered(pruned: 2, warning: nil), .unavailable])) == "Delivered: 1 of 2, the rest are waiting")
        #expect(Texts.runSummary(run([.delivered(pruned: 2, warning: nil)])) == "Done. Old copies removed: 2")
        #expect(Texts.runSummary(run([.delivered(pruned: 0, warning: nil)])) == "Done")
        #expect(Texts.runSummary(run([.unavailable])) == "Destinations unavailable, backup postponed")
    }

    @Test func sourceStatusPicksTheMostImportantFact() {
        let obsidian = source("Obsidian")
        let report = StatusReport(items: [
            .severelyOverdue(sourceId: obsidian.id),
            .runFailed(sourceId: obsidian.id, message: "quota"),
            .manualExportDue(sourceId: UUID()),
        ])
        #expect(SourceStatus.of(obsidian, report: report, lastRun: now) == .failed("quota"))
        let warned = StatusReport(items: [.manualExportDue(sourceId: obsidian.id), .deliveryWarning(sourceId: obsidian.id, message: "left")])
        #expect(SourceStatus.of(obsidian, report: warned, lastRun: now) == .warning("left"))
        #expect(Texts.headline(warned) == "Needs your action")
        #expect(SourceStatus.of(obsidian, report: StatusReport(items: []), lastRun: now) == .ok)
        #expect(SourceStatus.of(obsidian, report: StatusReport(items: []), lastRun: nil) == .neverRun)
        var disabled = obsidian
        disabled.enabled = false
        #expect(SourceStatus.of(disabled, report: report, lastRun: now) == .disabled)
    }

    @Test func relativeTimeTreatsTheLastMinuteAsJustNow() {
        #expect(Texts.relative(now.addingTimeInterval(-20), to: now) == "just now")
        #expect(Texts.relative(now.addingTimeInterval(20), to: now) == "any moment")
        #expect(Texts.relative(now.addingTimeInterval(-7200), to: now) == "2 hours ago")
        #expect(Texts.relative(now.addingTimeInterval(86_400), to: now) == "in 1 day")
    }

    @Test(arguments: [
        (Int64(0), "0 B"),
        (999, "999 B"),
        (1_500, "1.5 KB"),
        (15_400, "15 KB"),
        (999_499, "999 KB"),
        (999_950, "1 MB"),
        (999_999_999, "1 GB"),
        (2_450_000_000, "2.5 GB"),
        (5_000_000_000_000_000, "5000 TB"),
    ])
    func sizeIsRoundedBeforeItsUnitIsChosen(bytes: Int64, text: String) {
        #expect(Texts.bytes(bytes) == text)
    }
}

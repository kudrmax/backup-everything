import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct TextsTests {
    private let cloud = Destination(name: "Облако", kind: .localFolder(path: "/c"))
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
            .runFailed(sourceId: github.id, message: "Команда завершилась с кодом 1. fatal: early EOF"),
            .severelyOverdue(sourceId: github.id),
            .connectDestination(destinationId: disk.id),
        ])

        let lines = MenuLines.of(config: config, state: AppState(), report: report, unavailable: [disk.id])

        #expect(lines == [
            MenuLine(subject: .source(github), severity: .error, text: "fatal: early EOF", canPickUp: false),
            MenuLine(subject: .source(photos), severity: .attention, text: "2 файла · 23 ГБ", canPickUp: true),
            MenuLine(subject: .destination(disk), severity: .attention, text: "пора подключить", canPickUp: false),
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
        #expect(lines.map(\.text) == ["1 файл · 5 МБ · идёт загрузка"])
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
        #expect(Texts.runSummary(run(collectError: "нет папки", [])) == "Ошибка: нет папки")
        #expect(Texts.runSummary(run([.delivered(pruned: 0, warning: nil), .failed(message: "квота")])) == "Доставлено: 1 из 2. Ошибка: квота")
        #expect(Texts.runSummary(run([.delivered(pruned: 2, warning: nil), .unavailable])) == "Доставлено: 1 из 2, остальные ждут")
        #expect(Texts.runSummary(run([.delivered(pruned: 2, warning: nil)])) == "Готово. Удалено старых копий: 2")
        #expect(Texts.runSummary(run([.delivered(pruned: 0, warning: nil)])) == "Готово")
        #expect(Texts.runSummary(run([.unavailable])) == "Назначения недоступны, бэкап отложен")
    }

    @Test func sourceStatusPicksTheMostImportantFact() {
        let obsidian = source("Obsidian")
        let report = StatusReport(items: [
            .severelyOverdue(sourceId: obsidian.id),
            .runFailed(sourceId: obsidian.id, message: "квота"),
            .manualExportDue(sourceId: UUID()),
        ])
        #expect(SourceStatus.of(obsidian, report: report, lastRun: now) == .failed("квота"))
        #expect(SourceStatus.of(obsidian, report: StatusReport(items: []), lastRun: now) == .ok)
        #expect(SourceStatus.of(obsidian, report: StatusReport(items: []), lastRun: nil) == .neverRun)
        var disabled = obsidian
        disabled.enabled = false
        #expect(SourceStatus.of(disabled, report: report, lastRun: now) == .disabled)
    }

    @Test func relativeTimeTreatsTheLastMinuteAsJustNow() {
        #expect(Texts.relative(now.addingTimeInterval(-20), to: now) == "только что")
        #expect(Texts.relative(now.addingTimeInterval(20), to: now) == "вот-вот")
        #expect(Texts.relative(now.addingTimeInterval(-7200), to: now) == "2 часа назад")
        #expect(Texts.relative(now.addingTimeInterval(86_400), to: now) == "через 1 день")
    }
}

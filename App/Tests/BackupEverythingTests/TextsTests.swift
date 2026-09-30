import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct TextsTests {
    private let cloud = Destination(name: "Облако", kind: .localFolder(path: "/c"))
    private let disk = Destination(name: "HDD", kind: .localFolder(path: "/h"), expectedEvery: .days(30))
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ name: String) -> Source {
        Source(name: name, slug: name.lowercased(), kind: .folder(path: "/a", excludes: []), schedule: .daily, createdAt: now)
    }

    @Test func attentionItemsAreExplainedInPlainRussian() {
        let photos = source("Google Photos")
        let config = Config(sources: [photos], destinations: [cloud, disk])

        #expect(Texts.attention(.manualExportDue(sourceId: photos.id), config: config)
            == AttentionText(title: "Google Photos", detail: "Пора сделать экспорт"))
        #expect(Texts.attention(.filesAwaitingPickup(sourceId: photos.id, fileCount: 3, totalBytes: 12_000_000_000, downloadInProgress: false), config: config)
            == AttentionText(title: "Google Photos", detail: "Найдено файлов: 3, 12 ГБ"))
        #expect(Texts.attention(.filesAwaitingPickup(sourceId: photos.id, fileCount: 1, totalBytes: 5_000_000, downloadInProgress: true), config: config)
            == AttentionText(title: "Google Photos", detail: "Найдено файлов: 1, 5 МБ. Идёт загрузка"))
        #expect(Texts.attention(.connectDestination(destinationId: disk.id), config: config)
            == AttentionText(title: "HDD", detail: "Пора подключить диск"))
        #expect(Texts.attention(.destinationUnavailable(destinationId: cloud.id), config: config)
            == AttentionText(title: "Облако", detail: "Назначение недоступно, бэкап ждёт"))
        #expect(Texts.attention(.runFailed(sourceId: photos.id, message: "диск отвалился"), config: config)
            == AttentionText(title: "Google Photos", detail: "Ошибка: диск отвалился"))
        #expect(Texts.attention(.noDestinations(sourceId: photos.id), config: config)
            == AttentionText(title: "Google Photos", detail: "Не выбрано, куда бэкапить"))
        #expect(Texts.attention(.severelyOverdue(sourceId: photos.id), config: config)
            == AttentionText(title: "Google Photos", detail: "Бэкап сильно просрочен"))
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

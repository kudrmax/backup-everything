import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct OverviewTextsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func ageIsShortAndCoarse() {
        #expect(Texts.age(nil, now: now) == "—")
        #expect(Texts.age(now.addingTimeInterval(-20), now: now) == "сейчас")
        #expect(Texts.age(now.addingTimeInterval(-5 * 60), now: now) == "5 мин")
        #expect(Texts.age(now.addingTimeInterval(-3 * 3600), now: now) == "3 ч")
        #expect(Texts.age(now.addingTimeInterval(-9 * 86_400), now: now) == "9 дн")
        #expect(Texts.age(now.addingTimeInterval(-70 * 86_400), now: now) == "2 мес")
        #expect(Texts.age(now.addingTimeInterval(-800 * 86_400), now: now) == "2 г")
    }

    @Test(arguments: [(1, "1 ошибка"), (2, "2 ошибки"), (5, "5 ошибок"), (11, "11 ошибок"), (21, "21 ошибка"), (24, "24 ошибки")])
    func errorCountIsDeclinedInRussian(count: Int, expected: String) {
        #expect(Texts.errors(count) == expected)
    }

    @Test(arguments: [(1, "1 файл"), (3, "3 файла"), (5, "5 файлов"), (12, "12 файлов"), (22, "22 файла")])
    func fileCountIsDeclinedInRussian(count: Int, expected: String) {
        #expect(Texts.files(count) == expected)
    }

    @Test func headlineSummarisesTheReport() {
        let first = UUID()
        let second = UUID()
        #expect(Texts.headline(StatusReport(items: [])) == "Всё в порядке")
        #expect(Texts.headline(StatusReport(items: [.manualExportDue(sourceId: first)])) == "Нужно твоё действие")
        #expect(Texts.headline(StatusReport(items: [
            .runFailed(sourceId: first, message: "a"),
            .severelyOverdue(sourceId: first),
            .runFailed(sourceId: second, message: "b"),
            .manualExportDue(sourceId: second),
        ])) == "2 ошибки")
    }

    @Test func rowNoteIsEmptyWhenNothingNeedsSaying() {
        #expect(SourceStatus.ok.note == nil)
        #expect(SourceStatus.neverRun.note == nil)
        #expect(SourceStatus.disabled.note == "выключен")
        #expect(SourceStatus.failed("диск отвалился").note == "диск отвалился")
        #expect(SourceStatus.failed("Команда завершилась с кодом 1. fatal: early EOF").errorMessage == "Команда завершилась с кодом 1. fatal: early EOF")
        #expect(SourceStatus.overdue.errorMessage == nil)
        #expect(SourceStatus.failed("Не найден путь источника: /Users/max/Obsidian").note == "Не найден путь источника")
        #expect(SourceStatus.failed("Команда завершилась с кодом 1. gh: run gh auth login").note == "Команда завершилась с кодом 1")
        #expect(SourceStatus.failed("rclone завершился с ошибкой: quota exceeded").note == "rclone завершился с ошибкой")
        #expect(SourceStatus.filesFound(count: 3, bytes: 12_000_000_000, downloading: false).note == "3 файла · 12 ГБ")
        #expect(SourceStatus.filesFound(count: 1, bytes: 5_000_000, downloading: true).note == "1 файл · 5 МБ · идёт загрузка")
        #expect(SourceStatus.exportDue.note == "пора сделать экспорт")
        #expect(SourceStatus.noDestinations.note == "не выбрано, куда бэкапить")
        #expect(SourceStatus.overdue.note == "давно не было бэкапа")
    }

    @Test(arguments: [(0, "0 копий"), (1, "1 копия"), (3, "3 копии"), (14, "14 копий"), (21, "21 копия")])
    func copyCountIsDeclinedInRussian(count: Int, expected: String) {
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
            .runFailed(sourceId: running, message: "сеть"),
            .severelyOverdue(sourceId: running),
            .runFailed(sourceId: idle, message: "диск"),
            .connectDestination(destinationId: disk),
        ])
        #expect(LiveReport.of(report, running: [running]).items == [
            .runFailed(sourceId: idle, message: "диск"),
            .connectDestination(destinationId: disk),
        ])
        #expect(LiveReport.of(report, running: []).items == report.items)
    }

    @Test func headlineSaysThatABackupIsRunningWhenNothingElseNeedsAttention() {
        #expect(Texts.headline(StatusReport(items: []), isWorking: true) == "Идёт бэкап")
        #expect(Texts.headline(StatusReport(items: [.runFailed(sourceId: UUID(), message: "a")]), isWorking: true) == "1 ошибка")
        #expect(Texts.headline(StatusReport(items: []), isWorking: false) == "Всё в порядке")
    }

    @Test func menuBarIconIsTintedOnlyWhenSomethingNeedsAttention() {
        #expect(MenuBarTint.of(.ok) == .standard)
        #expect(MenuBarTint.of(.attention) == .attention)
        #expect(MenuBarTint.of(.error) == .error)
    }
}

import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct NextBackupTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ schedule: Schedule, enabled: Bool = true) -> Source {
        Source(name: "Obsidian", slug: "obsidian", steps: [.folder("~/Obsidian", excludes: [])], schedule: schedule, enabled: enabled, createdAt: now)
    }

    @Test func futureIsShortAndCoarse() {
        #expect(Texts.until(now.addingTimeInterval(20), now: now) == "сейчас")
        #expect(Texts.until(now.addingTimeInterval(5 * 60), now: now) == "через 5 мин")
        #expect(Texts.until(now.addingTimeInterval(17 * 3600), now: now) == "через 17 ч")
        #expect(Texts.until(now.addingTimeInterval(3 * 86_400), now: now) == "через 3 дн")
        #expect(Texts.until(now.addingTimeInterval(90 * 86_400), now: now) == "через 3 мес")
    }

    @Test func nextBackupSaysWhenOrWhy() {
        #expect(NextBackup.note(source(.daily), nextDue: now.addingTimeInterval(17 * 3600), isWaiting: false, now: now) == "через 17 ч")
        #expect(NextBackup.note(source(.daily), nextDue: now.addingTimeInterval(-60), isWaiting: false, now: now) == "пора")
        #expect(NextBackup.note(source(.manual), nextDue: nil, isWaiting: false, now: now) == "по кнопке")
        #expect(NextBackup.note(source(.manual), nextDue: nil, isWaiting: true, now: now) == "ждёт")
        #expect(NextBackup.note(source(.daily, enabled: false), nextDue: nil, isWaiting: false, now: now) == nil)
    }

    @Test func settingsShowTheExactMoment() {
        let due = now.addingTimeInterval(17 * 3600)
        #expect(NextBackup.detail(source(.daily), nextDue: due, isWaiting: false, now: now) == Texts.dateTime(due))
        #expect(NextBackup.detail(source(.daily), nextDue: now.addingTimeInterval(-60), isWaiting: false, now: now) == "уже пора")
        #expect(NextBackup.detail(source(.manual), nextDue: nil, isWaiting: false, now: now) == "только по кнопке «Запустить»")
        #expect(NextBackup.detail(source(.manual), nextDue: nil, isWaiting: true, now: now) == "ждёт файл или устройство — начнётся сам")
        #expect(NextBackup.detail(source(.daily, enabled: false), nextDue: nil, isWaiting: false, now: now) == "источник выключен")
    }
}

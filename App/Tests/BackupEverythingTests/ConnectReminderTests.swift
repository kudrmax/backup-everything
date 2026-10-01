import Foundation
import Testing
@testable import BackupEverything

struct ConnectReminderTests {
    @Test func noticeNamesBackupsThatExistNowhereElse() {
        let one = ConnectReminder.notice(destinationName: "HDD", onlyCopyOf: ["PocketBook"])
        #expect(one.title == "Подключи «HDD»")
        #expect(one.body == "Бэкапа «PocketBook» больше нигде нет — он запишется, как только подключишь диск.")
        let two = ConnectReminder.notice(destinationName: "HDD", onlyCopyOf: ["PocketBook", "Anki"])
        #expect(two.body == "Бэкапов «PocketBook», «Anki» больше нигде нет — они запишутся, как только подключишь диск.")
    }

    @Test func noticeAfterThePeriodSaysCopiesAreSafeElsewhere() {
        let notice = ConnectReminder.notice(destinationName: "HDD", onlyCopyOf: [])
        #expect(notice.body == "Диск давно не подключался. Копии есть на других дисках, но и этот пора обновить.")
    }

    @Test func waitingBadgeSaysWhereElseTheBackupIs() {
        #expect(ConnectReminder.waitingLine(elsewhere: true, otherDestinations: ["Папка на ноуте"]) == "копия есть на «Папка на ноуте»")
        #expect(ConnectReminder.waitingLine(elsewhere: false, otherDestinations: ["Папка на ноуте"]) == "этого бэкапа больше нигде нет — подключи диск")
    }
}

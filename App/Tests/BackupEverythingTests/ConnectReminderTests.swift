import Foundation
import Testing
@testable import BackupEverything

struct ConnectReminderTests {
    @Test func noticeNamesBackupsThatExistNowhereElse() {
        let one = ConnectReminder.notice(destinationName: "HDD", onlyCopyOf: ["PocketBook"])
        #expect(one.title == "Connect “HDD”")
        #expect(one.body == "The backup of “PocketBook” exists nowhere else. It will be written as soon as you connect the disk.")
        let two = ConnectReminder.notice(destinationName: "HDD", onlyCopyOf: ["PocketBook", "Anki"])
        #expect(two.body == "The backups of “PocketBook”, “Anki” exist nowhere else. They will be written as soon as you connect the disk.")
    }

    @Test func noticeAfterThePeriodSaysCopiesAreSafeElsewhere() {
        let notice = ConnectReminder.notice(destinationName: "HDD", onlyCopyOf: [])
        #expect(notice.body == "The disk hasn’t been connected for a while. Copies are on other disks, but this one needs updating too.")
    }

    @Test func waitingBadgeSaysWhereElseTheBackupIs() {
        #expect(ConnectReminder.waitingLine(elsewhere: true, otherDestinations: ["Laptop folder"]) == "a copy is on “Laptop folder”")
        #expect(ConnectReminder.waitingLine(elsewhere: false, otherDestinations: ["Laptop folder"]) == "this backup exists nowhere else — connect the disk")
    }
}

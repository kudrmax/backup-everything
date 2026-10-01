import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct SpaceSavingTests {
    private let laptop = Destination(name: "Laptop", kind: .localFolder(path: "~/Backups"))
    private let hdd = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"))
    private let flash = Destination(name: "Flash", kind: .localFolder(path: "/Volumes/FLASH"))
    private let cloud = Destination(name: "Cloud", kind: .rclone(remote: "gdrive", path: "Backups"))

    @Test func macDisksSaveSpace() {
        let saving = SpaceSaving.of([laptop, hdd], sharing: [laptop.id: true, hdd.id: true])
        #expect(saving.isPossible)
        #expect(saving.note == nil)
    }

    @Test func diskNeverSeenConnectedIsGivenTheBenefitOfTheDoubt() {
        #expect(SpaceSaving.of([hdd], sharing: [:]).isPossible)
    }

    @Test func cloudAndNonMacDisksAlwaysGetFullCopies() {
        let saving = SpaceSaving.of([laptop, cloud, flash], sharing: [laptop.id: true, flash.id: false])
        #expect(saving.isPossible)
        #expect(saving.fullCopiesIn == ["Cloud", "Flash"])
        #expect(saving.note == "full copies in “Cloud”, “Flash”")
    }

    @Test func switchIsOffWhenNoChosenDestinationCanShareFiles() {
        let saving = SpaceSaving.of([cloud, flash], sharing: [flash.id: false])
        #expect(!saving.isPossible)
        #expect(saving.note == "not possible in “Cloud”, “Flash”")
    }

    @Test func switchIsOffWithoutDestinations() {
        let saving = SpaceSaving.of([], sharing: [:])
        #expect(!saving.isPossible)
        #expect(saving.note == nil)
    }
}

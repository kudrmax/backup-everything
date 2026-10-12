import BackupCore
import Foundation
import Testing
@testable import BackupEverything

struct SetupTextsTests {
    @Test func linesNameWhatIsMissing() {
        let hdd = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/HDD/Backups"))
        let config = Config(destinations: [hdd])
        #expect(SetupTexts.line(.rsyncMissing, config: config) == "rsync 3 is not installed (brew install rsync)")
        #expect(SetupTexts.line(.accountMissing, config: config) == "The backup account “_backupeverything” does not exist")
        #expect(SetupTexts.line(.receiverMissing, config: config) == "The receiver gate is not installed")
        #expect(SetupTexts.line(.sudoRuleMissing, config: config) == "The sudo rule for the receiver gate is missing or outdated")
        #expect(SetupTexts.line(.destinationNotReady(id: hdd.id, .volumeIgnoresOwners), config: config) == "“HDD”: the disk ignores file owners")
        #expect(SetupTexts.line(.destinationNotReady(id: hdd.id, .notOwnedByBackupAccount(owner: "max")), config: config) == "“HDD”: the folder belongs to “max”, not to the backup account")
    }

    @Test func commandNamesTheFolderOfEachDestinationThatIsNotReady() {
        let hdd = Destination(name: "HDD", kind: .localFolder(path: "/Volumes/Max's HDD/Backups"))
        let laptop = Destination(name: "Laptop", kind: .localFolder(path: "/Users/max/Files/Backups"))
        let config = Config(destinations: [laptop, hdd])
        #expect(SetupTexts.commands(for: [.destinationNotReady(id: hdd.id, .volumeIgnoresOwners)], config: config)
            == ["sudo scripts/setup-storage.sh '/Volumes/Max'\\''s HDD/Backups'"])
        #expect(SetupTexts.commands(for: [.accountMissing], config: config) == ["sudo scripts/setup-storage.sh '/Users/max/Files/Backups'"])
        #expect(SetupTexts.commands(for: [.accountMissing], config: Config(destinations: [])) == [])
    }
}

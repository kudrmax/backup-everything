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

    @Test func commandNamesTheScriptAndTheFolderOfEachDestinationThatIsNotReady() {
        let disk = Destination(name: "Disk", kind: .localFolder(path: "/Volumes/Test Disk's/Backups"))
        let laptop = Destination(name: "Laptop", kind: .localFolder(path: "/Users/someone/Files/Backups"))
        let config = Config(destinations: [laptop, disk])
        let script = "/Applications/Backup Everything.app/Contents/Resources/setup-storage.sh"
        #expect(SetupTexts.commands(for: [.destinationNotReady(id: disk.id, .volumeIgnoresOwners)], config: config, script: script)
            == ["sudo '/Applications/Backup Everything.app/Contents/Resources/setup-storage.sh' '/Volumes/Test Disk'\\''s/Backups'"])
        #expect(SetupTexts.commands(for: [.accountMissing], config: config, script: script)
            == ["sudo '/Applications/Backup Everything.app/Contents/Resources/setup-storage.sh' '/Users/someone/Files/Backups'"])
        #expect(SetupTexts.commands(for: [.accountMissing], config: Config(destinations: []), script: script) == [])
    }
}

import Foundation
import Testing
@testable import BackupCore

struct StorageSetupTests {
    private let temp = try! TempDirectory()

    private func setup(rsync: URL? = nil, receiver: URL? = nil, sudoExit: Int32 = 0, account: Bool = true) throws -> StorageSetup {
        let rsync = try rsync ?? temp.file("rsync", "#!/bin/sh")
        let receiver = try receiver ?? temp.file("backup-receiver", "#!/bin/sh")
        return StorageSetup(
            rsync: rsync, receiver: receiver, access: AlwaysReadyAccess(),
            runner: FakeProcessRunner(handler: { _ in ProcessResult(exitCode: sudoExit) }),
            roleAccountExists: { account }
        )
    }

    @Test func commandRunsTheGivenScriptOnTheFolder() {
        #expect(StorageSetup.command(script: "/A b.app/Contents/Resources/setup-storage.sh", folder: "/Volumes/X/it's")
            == "sudo '/A b.app/Contents/Resources/setup-storage.sh' '/Volumes/X/it'\\''s'")
    }

    @Test func everythingInPlace() async throws {
        defer { temp.remove() }
        let rsync = try temp.file("rsync", "#!/bin/sh")
        let receiver = try temp.file("backup-receiver", "#!/bin/sh")
        for file in [rsync, receiver] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let destination = Fixtures.localDestination("HDD", at: try temp.directory("hdd"))
        #expect(try await setup(rsync: rsync, receiver: receiver).check([destination]) == [])
    }

    @Test func reportsEachMissingPiece() async throws {
        defer { temp.remove() }
        let destination = Fixtures.localDestination("HDD", at: temp.path("missing"))
        let problems = try await setup(rsync: temp.path("no-rsync"), receiver: temp.path("no-receiver"), sudoExit: 1, account: false).check([destination])
        #expect(problems == [.rsyncMissing, .accountMissing, .receiverMissing, .sudoRuleMissing, .destinationNotReady(id: destination.id, .folderMissing)])
    }

    @Test func sudoRuleIsCheckedByRunningTheReceiver() async throws {
        defer { temp.remove() }
        let runner = FakeProcessRunner()
        let setup = StorageSetup(rsync: try temp.file("rsync", ""), receiver: try temp.file("backup-receiver", ""), access: AlwaysReadyAccess(), runner: runner, roleAccountExists: { true })
        _ = await setup.check([])
        #expect(runner.calls.last?.executable.path == "/usr/bin/sudo")
        #expect(runner.calls.last?.arguments == ["-n", "-u", "_backupeverything", temp.path("backup-receiver").path, "--check"])
    }
}

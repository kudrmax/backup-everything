import Foundation
import Testing
@testable import BackupCore

struct DestinationAccessTests {
    private let temp = try! TempDirectory()

    @Test func missingFolderIsReported() {
        defer { temp.remove() }
        #expect(SystemDestinationAccess(roleAccount: "root").readiness(of: temp.path("none")) == .folderMissing)
        #expect(AlwaysReadyAccess().readiness(of: temp.path("none")) == .folderMissing)
    }

    @Test func folderOwnedByAnotherAccountIsNotReady() throws {
        defer { temp.remove() }
        let root = try temp.directory("dest")
        #expect(SystemDestinationAccess(roleAccount: "root").readiness(of: root) == .notOwnedByBackupAccount(owner: NSUserName()))
    }

    @Test func unknownAccountIsReported() throws {
        defer { temp.remove() }
        let root = try temp.directory("dest")
        #expect(SystemDestinationAccess(roleAccount: "_no_such_account_be").readiness(of: root) == .accountMissing)
    }

    @Test func ownFolderOnTheSystemDiskIsReadyForTheOwner() throws {
        defer { temp.remove() }
        let root = try temp.directory("dest")
        #expect(SystemDestinationAccess(roleAccount: NSUserName()).readiness(of: root) == .ready)
        #expect(AlwaysReadyAccess().readiness(of: root) == .ready)
    }
}

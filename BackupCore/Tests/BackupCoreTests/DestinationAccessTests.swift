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

    /// The backup account writes through every folder above the root: a private one (Desktop, Documents, a 700 folder)
    /// keeps it out even when the root is its own.
    @Test func aPrivateFolderAboveTheRootKeepsTheAccountOut() throws {
        defer { temp.remove() }
        let root = try temp.directory("private/dest")
        #expect(chmod(temp.path("private").path, 0o700) == 0)
        let parent = temp.path("private").resolvingSymlinksInPath().path
        #expect(SystemDestinationAccess(roleAccount: "nobody").readiness(of: root) == .ancestorNotTraversable(path: parent))
        #expect(SystemDestinationAccess(roleAccount: NSUserName()).readiness(of: root) == .ready)
        #expect(chmod(temp.path("private").path, 0o701) == 0)
        #expect(SystemDestinationAccess(roleAccount: "nobody").readiness(of: root) != .ancestorNotTraversable(path: parent))
    }

    @Test(arguments: [
        (mode_t(0o701), uid_t(501), gid_t(20), true),
        (mode_t(0o710), uid_t(501), gid_t(20), true),
        (mode_t(0o710), uid_t(501), gid_t(80), false),
        (mode_t(0o700), uid_t(497), gid_t(80), true),
        (mode_t(0o700), uid_t(501), gid_t(20), false),
        (mode_t(0o776), uid_t(501), gid_t(80), false),
    ])
    func theAccountTraversesAFolderThroughOthersItsGroupOrOwnership(mode: mode_t, owner: uid_t, group: gid_t, traversable: Bool) {
        #expect(SystemDestinationAccess.canTraverse(mode: mode, owner: owner, group: group, uid: 497, gid: 20) == traversable)
    }
}

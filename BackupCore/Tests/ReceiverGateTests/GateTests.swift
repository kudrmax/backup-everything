import Foundation
import Testing
@testable import ReceiverGate

struct FakeEnvironment: GateEnvironment {
    var currentUID: uid_t = 497
    var owners: [String: uid_t] = [:]
    var noOwners: Set<String> = []
    var existing: Set<String> = []

    func ownerUID(ofPath path: String) -> uid_t? { owners[path] }
    func volumeHonoursOwners(atPath path: String) -> Bool { !noOwners.contains(path) }
    func fileExists(atPath path: String) -> Bool { existing.contains(path) || owners[path] != nil }
}

struct GateTests {
    private var environment: FakeEnvironment {
        FakeEnvironment(owners: ["/Volumes/HDD/Backups": 497, "/Volumes/HDD/Backups/obsidian": 497])
    }
    private let server = ["backup", "rsync", "--server", "-logDtpAXre.iLsfxCIvu", "--link-dest", "/Volumes/HDD/Backups/obsidian/2026-10-07_100000", "--inplace", "--mkpath", "."]

    @Test func passesACopyIntoAnUnfinishedFolder() {
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .success(Array(server.dropFirst(2)) + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"]))
    }

    @Test func passesTheCompletionMarker() {
        let plan = Gate.plan(
            arguments: ["backup", "rsync", "--server", "-logDtpAXre.iLsfxCIvu", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete"],
            environment: environment
        )
        #expect(plan == .success(["--server", "-logDtpAXre.iLsfxCIvu", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete"]))
    }

    @Test(arguments: ["--delete", "--delete-after", "--remove-source-files", "--sender", "--rsync-path=/bin/sh", "--files-from=/etc/passwd", "--backup-dir=/tmp"])
    func refusesAnyOptionOutsideTheList(option: String) {
        let plan = Gate.plan(arguments: server + [option, "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "refused option \(option)")))
    }

    @Test func refusesWithoutServerMode() {
        let plan = Gate.plan(arguments: ["backup", "rsync", "-a", ".", "/Volumes/HDD/Backups/x/"], environment: environment)
        #expect(plan == .failure(GateError(message: "only rsync --server is accepted")))
    }

    @Test func refusesATargetInAFinishedCopy() {
        var environment = environment
        environment.existing.insert("/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete")
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/obsidian/2026-10-08_100000 is a finished copy")))
    }

    @Test func refusesATargetOutsideAFolderOfTheRoleAccount() {
        let plan = Gate.plan(arguments: server + ["/Users/max/Documents/x/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Users/max/Documents/x is not inside a folder of the backup account")))
    }

    @Test func refusesATargetOnAVolumeIgnoringOwners() {
        var environment = environment
        environment.noOwners.insert("/Volumes/HDD/Backups/obsidian")
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "the volume of /Volumes/HDD/Backups/obsidian/2026-10-08_100000 ignores file owners")))
    }

    @Test func refusesAPathThatClimbsOut() {
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/../../x/"], environment: environment)
        #expect(plan == .failure(GateError(message: "path must be absolute without “..”")))
    }

    @Test func refusesASecondPath() {
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/a/", "/Volumes/HDD/Backups/obsidian/b/"], environment: environment)
        #expect(plan == .failure(GateError(message: "exactly one destination path is accepted")))
    }

    @Test func refusesAFinishedCopyTargetedWithoutATrailingSlash() {
        var environment = environment
        environment.existing.insert("/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete")
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/obsidian/2026-10-08_100000 is a finished copy")))
    }

    @Test func refusesASubfolderOfAFinishedCopy() {
        var environment = environment
        environment.existing.insert("/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete")
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/sub/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/obsidian/2026-10-08_100000 is a finished copy")))
    }

    @Test func refusesATargetUnderAFolderOwnedBySomeoneElse() {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/other"] = 501
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/other/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/other/2026-10-08_100000 is not inside a folder of the backup account")))
    }
}

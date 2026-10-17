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
    private let server = ["backup", "rsync", "--server", "-lDtXre.iLsfxCIvu", "--link-dest", "/Volumes/HDD/Backups/obsidian/2026-10-07_100000", "--inplace", "--mkpath", "."]

    @Test func passesACopyIntoAnUnfinishedFolder() {
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .success(Array(server.dropFirst(2)) + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"]))
    }

    @Test func passesTheCompletionMarker() {
        let plan = Gate.plan(
            arguments: ["backup", "rsync", "--server", "-lDtXre.iLsfxCIvu", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete"],
            environment: environment
        )
        #expect(plan == .success(["--server", "-lDtXre.iLsfxCIvu", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete"]))
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

    /// A dated folder is written once: an unfinished attempt may hold hard links into a finished copy, and rsync
    /// `--inplace` would write through them.
    @Test func refusesAnExistingUnfinishedFolderAsTarget() {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/obsidian/2026-10-08_100000"] = 497
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/obsidian/2026-10-08_100000 already exists")))
    }

    @Test func passesTheMarkerIntoAFolderWithoutOne() {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/obsidian/2026-10-08_100000"] = 497
        let arguments = ["backup", "rsync", "--server", "-e.LsfxCIvu", "--inplace", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete"]
        #expect(Gate.plan(arguments: arguments, environment: environment) == .success(Array(arguments.dropFirst(2))))
    }

    @Test func passesADataTransferIntoANewFolderUnderAnOwnedParent() {
        let arguments = server + ["/Volumes/HDD/Backups/obsidian/2026-10-09_100000/"]
        #expect(Gate.plan(arguments: arguments, environment: environment) == .success(Array(arguments.dropFirst(2))))
    }

    @Test(arguments: ["-K", "-b", "-T", "-f", "-y", "-B", "-E", "-O", "-J", "-W", "-lDtXrKe.iLsfxCIvu"])
    func refusesShortOptionsRsyncDoesNotSendForUs(cluster: String) {
        let plan = Gate.plan(arguments: ["backup", "rsync", "--server", cluster, ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "refused option \(cluster)")))
    }

    /// Modes, owners, groups, ACLs and hard links of the originals are never kept: the gate decides the modes.
    @Test(arguments: ["-p", "-o", "-g", "-A", "-H", "-logDtpAXre.iLsfxCIvu", "-lDtpXre.iLsfxCIvu", "-lDtXrAe.iLsfxCIvu", "-lDtXrHe.iLsfxCIvu"])
    func refusesLettersThatKeepModesOrOwners(cluster: String) {
        let plan = Gate.plan(arguments: ["backup", "rsync", "--server", cluster, ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "refused option \(cluster)")))
    }

    @Test(arguments: ["-lDtXre.iLsfxCIvu", "-lDtXrLe.iLsfxCIvu", "-e.LsfxCIvu"])
    func passesTheShortOptionsOfOurTwoTransfers(cluster: String) {
        let arguments = ["backup", "rsync", "--server", cluster, ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"]
        #expect(Gate.plan(arguments: arguments, environment: environment) == .success(Array(arguments.dropFirst(2))))
    }

    @Test func passesTheFixedChmod() {
        let arguments = ["backup", "rsync", "--server", "-lDtXre.iLsfxCIvu", "--chmod=ugo=rwX", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"]
        #expect(Gate.plan(arguments: arguments, environment: environment) == .success(Array(arguments.dropFirst(2))))
    }

    @Test(arguments: ["--chmod=Dg+rx,Fg+r", "--chmod=ugo=rwx", "--chmod=u+s", "--chmod=ugo=rwX,o+w", "--chmod=", "--chmod"])
    func refusesAnyOtherChmod(option: String) {
        let plan = Gate.plan(arguments: server + [option, "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "refused option \(option)")))
    }

    @Test func refusesATargetUnderAFolderOwnedBySomeoneElse() {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/other"] = 501
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/other/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/other/2026-10-08_100000 is not inside a folder of the backup account")))
    }
}

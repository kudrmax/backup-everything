import Foundation
import Testing
@testable import ReceiverGate

struct FakeEnvironment: GateEnvironment {
    var currentUID: uid_t = 497
    var owners: [String: uid_t] = [:]
    var noOwners: Set<String> = []
    var existing: Set<String> = []
    var realPaths: [String: String] = [:]

    func ownerUID(ofPath path: String) -> uid_t? { owners[path] }
    func volumeHonoursOwners(atPath path: String) -> Bool { !noOwners.contains(path) }
    func fileExists(atPath path: String) -> Bool { existing.contains(path) || owners[path] != nil }
    func realPath(ofPath path: String) -> String? { fileExists(atPath: path) ? realPaths[path] ?? path : nil }
}

struct GateTests {
    private var environment: FakeEnvironment {
        FakeEnvironment(owners: ["/Volumes/HDD/Backups": 497, "/Volumes/HDD/Backups/obsidian": 497])
    }
    private let server = ["backup", "rsync", "--server", "-lDtXre.iLsfxCIvu", "--link-dest", "/Volumes/HDD/Backups/obsidian/2026-10-07_100000", "--mkpath", "."]

    @Test func passesACopyIntoAnUnfinishedFolder() {
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .success(GatePlan(
            argv: Array(server.dropFirst(2)) + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"],
            claim: .folder("/Volumes/HDD/Backups/obsidian/2026-10-08_100000")
        )))
    }

    @Test func passesTheCompletionMarker() {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/obsidian/2026-10-08_100000"] = 497
        let plan = Gate.plan(
            arguments: ["backup", "rsync", "--server", "-e.LsfxCIvu", "--inplace", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete"],
            environment: environment
        )
        #expect(plan == .success(GatePlan(
            argv: ["--server", "-e.LsfxCIvu", "--inplace", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete"],
            claim: .marker("/Volumes/HDD/Backups/obsidian/2026-10-08_100000/.complete")
        )))
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
        let plan = Gate.plan(arguments: server + ["/Users/max/Documents/x/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Users/max/Documents/x/2026-10-08_100000 is not inside a folder of the backup account")))
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

    @Test func refusesATargetThatIsNeitherACopyFolderNorItsMarker() {
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/notes.md"], environment: environment)
        #expect(plan == .failure(GateError(message: "the destination must be a new copy folder or its completion marker")))
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

    @Test(arguments: ["-lDtXre.iLsfxCIvu", "-lDtrXe.iLsfxCIvu", "-e.LsfxCIvu"])
    func passesTheShortOptionsOfOurTwoTransfers(cluster: String) {
        let arguments = ["backup", "rsync", "--server", cluster, ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"]
        #expect(Gate.plan(arguments: arguments, environment: environment).map(\.argv) == .success(Array(arguments.dropFirst(2))))
    }

    /// `s` (secluded args) would make rsync read a second argv from the protocol, past the gate. Letters rsync sends
    /// for us before `e` are only `l D t r X`.
    @Test(arguments: ["-slDtXre.iLsfxCIvu", "-lDtXrLe.iLsfxCIvu", "-ilDtXre.iLsfxCIvu", "-xlDtXre.iLsfxCIvu", "-lDtXrCe.iLsfxCIvu", "-lDtXrIe.iLsfxCIvu", "-vlDtXre.iLsfxCIvu", "-ulDtXre.iLsfxCIvu", "-s", "-.e.LsfxCIvu"])
    func refusesLettersRsyncDoesNotSendBeforeE(cluster: String) {
        let plan = Gate.plan(arguments: ["backup", "rsync", "--server", cluster, ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "refused option \(cluster)")))
    }

    /// rsync escapes paths for a remote shell; `sudo` runs the gate without one, so the gate removes the escapes.
    @Test func unescapesTheTargetAndTheLinkDestsBeforeCheckingAndPassing() {
        let environment = FakeEnvironment(owners: ["/Volumes/My Disk/B it's": 497, "/Volumes/My Disk/B it's/old": 497])
        let plan = Gate.plan(
            arguments: ["backup", "rsync", "--server", "-lDtXre.iLsfxCIvu", "--link-dest", "/Volumes/My\\ Disk/B\\ it\\'s/old", "--mkpath", ".", "/Volumes/My\\ Disk/B\\ it\\'s/new\\ notes/2026-10-08_100000/"],
            environment: environment
        )
        #expect(plan == .success(GatePlan(
            argv: ["--server", "-lDtXre.iLsfxCIvu", "--link-dest", "/Volumes/My Disk/B it's/old", "--mkpath", ".", "/Volumes/My Disk/B it's/new notes/2026-10-08_100000/"],
            claim: .folder("/Volumes/My Disk/B it's/new notes/2026-10-08_100000")
        )))
    }

    @Test(arguments: [("a\\\\b", "a\\b"), ("\\$x\\\"\\*", "$x\"*"), ("plain", "plain"), ("end\\", "end\\")])
    func unescapingDropsOneBackslashBeforeAnyCharacter(escaped: String, plain: String) {
        #expect(Gate.unescape(escaped) == plain)
    }

    @Test(arguments: ["/Users/max/Documents", "/Volumes/HDD/Backups/obsidian/../../../Users/max", "Backups/obsidian/2026-10-07_100000", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000"])
    func refusesALinkDestOutsideTheFoldersOfTheBackupAccount(linkDest: String) {
        var environment = environment
        environment.owners["/Users/max/Documents"] = 501
        let plan = Gate.plan(
            arguments: ["backup", "rsync", "--server", "-lDtXre.iLsfxCIvu", "--link-dest", linkDest, "--mkpath", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"],
            environment: environment
        )
        #expect(plan == .failure(GateError(message: "refused link-dest \(linkDest)")))
    }

    @Test func refusesALinkDestOnAVolumeIgnoringOwners() {
        var environment = environment
        environment.owners["/Volumes/Other/Backups"] = 497
        environment.noOwners.insert("/Volumes/Other/Backups")
        let plan = Gate.plan(
            arguments: ["backup", "rsync", "--server", "-lDtXre.iLsfxCIvu", "--link-dest", "/Volumes/Other/Backups/x", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"],
            environment: environment
        )
        #expect(plan == .failure(GateError(message: "refused link-dest /Volumes/Other/Backups/x")))
    }

    @Test func refusesATargetThroughASymlink() {
        var environment = environment
        environment.realPaths["/Volumes/HDD/Backups/obsidian"] = "/Users/max/Documents"
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/obsidian/2026-10-08_100000 is not the real path (symlink or letter case)")))
    }

    @Test func refusesALinkDestThroughASymlink() {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/obsidian/2026-10-07_100000"] = 497
        environment.realPaths["/Volumes/HDD/Backups/obsidian/2026-10-07_100000"] = "/Users/max/Documents"
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "refused link-dest /Volumes/HDD/Backups/obsidian/2026-10-07_100000")))
    }

    @Test func claimsAFolderUnderAMissingParent() {
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/photos/2026-10-08_100000/"], environment: environment)
        #expect(plan.map(\.claim) == .success(.folder("/Volumes/HDD/Backups/photos/2026-10-08_100000")))
    }

    /// A dated folder and its marker are written once: an unfinished attempt may hold hard links into a finished copy,
    /// and a write into the attempt could reach them. The claim creates them, so two gates cannot both get one.
    @Test func aFolderIsClaimedOnceWithItsMissingParents() throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let folder = temp.path + "/obsidian/2026-10-08_100000"
        #expect(Claimer.claim(.folder(folder)) == nil)
        #expect(Claimer.claim(.folder(folder)) == GateError(message: "\(folder) already exists"))
        var info = stat()
        #expect(lstat(folder, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR)
        #expect(info.st_mode & 0o7777 == 0o750 & ~currentUmask())
    }

    @Test func aMarkerIsClaimedOnce() throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let marker = temp.path + "/.complete"
        #expect(Claimer.claim(.marker(marker)) == nil)
        #expect(Claimer.claim(.marker(marker)) == GateError(message: "\(marker) is a finished copy"))
        var info = stat()
        #expect(lstat(marker, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size == 0)
        #expect(info.st_mode & 0o7777 == 0o640 & ~currentUmask())
    }

    @Test func aMarkerIsNotClaimedThroughASymlink() throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        #expect(symlink(temp.path + "/elsewhere", temp.path + "/.complete") == 0)
        #expect(Claimer.claim(.marker(temp.path + "/.complete")) == GateError(message: "\(temp.path)/.complete is a finished copy"))
        #expect(!FileManager.default.fileExists(atPath: temp.path + "/elsewhere"))
    }

    /// rsync applies `--chmod` on the client and never sends it to the receiver.
    @Test(arguments: ["--chmod=ugo=rwX", "--chmod=Dg+rx,Fg+r", "--chmod=u+s", "--chmod"])
    func refusesChmod(option: String) {
        let plan = Gate.plan(arguments: server + [option, "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "refused option \(option)")))
    }

    /// popt takes the argument after a bare `e` as its value: the gate would have checked it as something else.
    @Test(arguments: ["-e", "-lDtre", "-lDtXre"])
    func refusesAnEWithoutCapabilities(cluster: String) {
        let plan = Gate.plan(arguments: ["backup", "rsync", "--server", cluster, ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "refused option \(cluster)")))
    }

    @Test(arguments: [
        [".", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"],
        ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/", "."],
        [".", "--inplace", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"],
        ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"],
        ["."],
    ])
    func acceptsOnlyADotAndTheDestinationAsTheLastTwoArguments(tail: [String]) {
        let plan = Gate.plan(arguments: ["backup", "rsync", "--server", "-lDtXre.iLsfxCIvu"] + tail, environment: environment)
        #expect(plan == .failure(GateError(message: "exactly one destination path is accepted")))
    }

    @Test func acceptsADotThenTheDestination() {
        let arguments = ["backup", "rsync", "--server", "-lDtXre.iLsfxCIvu", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"]
        #expect(Gate.plan(arguments: arguments, environment: environment).map(\.argv) == .success(Array(arguments.dropFirst(2))))
    }

    @Test(arguments: ["/Volumes/HDD/Backups/.complete", "/Volumes/HDD/Backups/obsidian/.complete", "/Volumes/HDD/Backups/obsidian/latest/.complete"])
    func refusesAMarkerOutsideACopyFolder(marker: String) {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/obsidian/latest"] = 497
        let plan = Gate.plan(arguments: ["backup", "rsync", "--server", "-e.LsfxCIvu", "--inplace", ".", marker], environment: environment)
        #expect(plan == .failure(GateError(message: "marker must be inside a copy folder")))
    }

    @Test func passesAMarkerInACopyFolderNamedWithAnOffset() {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/obsidian/2026-10-25_023000+0200"] = 497
        let marker = "/Volumes/HDD/Backups/obsidian/2026-10-25_023000+0200/.complete"
        let plan = Gate.plan(arguments: ["backup", "rsync", "--server", "-e.LsfxCIvu", "--inplace", ".", marker], environment: environment)
        #expect(plan.map(\.claim) == .success(.marker(marker)))
    }

    @Test func refusesATargetUnderAFolderOwnedBySomeoneElse() {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/other"] = 501
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/other/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/other/2026-10-08_100000 is not inside a folder of the backup account")))
    }

    /// A file written in place into a copy folder could be a hard link just made from a finished copy (a name that
    /// differs only in letter case or Unicode form): only the marker, a new empty file, is written in place.
    @Test func refusesInplaceForACopyFolder() {
        let plan = Gate.plan(arguments: server.dropLast() + ["--inplace", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "refused option --inplace for a copy folder")))
    }

    @Test func passesACopyFolderWithoutInplaceAndAMarkerWithIt() {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/obsidian/2026-10-07_100000"] = 497
        let folder = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000/"], environment: environment)
        let marker = Gate.plan(arguments: ["backup", "rsync", "--server", "-e.LsfxCIvu", "--inplace", ".", "/Volumes/HDD/Backups/obsidian/2026-10-07_100000/.complete"], environment: environment)
        #expect(folder.map(\.claim) == .success(.folder("/Volumes/HDD/Backups/obsidian/2026-10-08_100000")))
        #expect(marker.map(\.claim) == .success(.marker("/Volumes/HDD/Backups/obsidian/2026-10-07_100000/.complete")))
    }

    /// A folder claim is `<account folder>/<slug>/<copy name>/`: anything else would be a folder the app never reads,
    /// or a `.complete` folder that would pass for a marker.
    @Test(arguments: [
        "/Volumes/HDD/Backups/obsidian/2026-10-08_110000/extra/",
        "/Volumes/HDD/Backups/obsidian/2026-10-08_110000/.complete/",
        "/Volumes/HDD/Backups/junk/",
        "/Volumes/HDD/Backups/obsidian/.complete/",
        "/Volumes/HDD/Backups/obsidian/2026-10-08_110000x/",
    ])
    func refusesAFolderNotNamedLikeACopy(target: String) {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/obsidian/2026-10-08_110000"] = 497
        let plan = Gate.plan(arguments: server + [target], environment: environment)
        #expect(plan == .failure(GateError(message: "copy folder name required")))
    }

    @Test(arguments: [
        "/Volumes/HDD/Backups/obsidian/2026-10-08_110000/2026-10-08_120000",
        "/Volumes/HDD/Backups/2026-10-08_110000/obsidian/2026-10-08_120000",
        "/Volumes/HDD/Backups/.complete/obsidian/2026-10-08_120000",
    ])
    func refusesACopyFolderInsideACopyFolder(folder: String) {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/obsidian/2026-10-08_110000"] = 497
        let plan = Gate.plan(arguments: server + [folder + "/"], environment: environment)
        #expect(plan == .failure(GateError(message: "\(folder) lies inside a copy folder")))
    }

    @Test func refusesAMarkerOfACopyFolderInsideACopyFolder() {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/obsidian/2026-10-08_110000"] = 497
        environment.owners["/Volumes/HDD/Backups/obsidian/2026-10-08_110000/2026-10-08_120000"] = 497
        let plan = Gate.plan(arguments: ["backup", "rsync", "--server", "-e.LsfxCIvu", "--inplace", ".", "/Volumes/HDD/Backups/obsidian/2026-10-08_110000/2026-10-08_120000/.complete"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/obsidian/2026-10-08_110000/2026-10-08_120000 lies inside a copy folder")))
    }

    /// `--mkpath` may create the slug folder, and nothing more above the copy folder.
    @Test func refusesACopyFolderWithMoreThanTheSlugFolderMissing() {
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/new/photos/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/new/photos/2026-10-08_100000 is not inside a folder of the backup account")))
    }

    @Test func refusesACopyFolderWhoseSlugFolderIsInAFolderOfSomeoneElse() {
        var environment = environment
        environment.owners["/Volumes/HDD/Backups/other"] = 501
        let plan = Gate.plan(arguments: server + ["/Volumes/HDD/Backups/other/photos/2026-10-08_100000/"], environment: environment)
        #expect(plan == .failure(GateError(message: "/Volumes/HDD/Backups/other/photos/2026-10-08_100000 is not inside a folder of the backup account")))
    }

    @Test(arguments: ["/Volumes/HDD/Backups/obsidian/2026-10-08_100000", "/Volumes/HDD/Backups/photos/2026-10-08_100000", "/Volumes/HDD/Backups/obsidian/2026-10-25_023000+0200"])
    func passesACopyFolderWithOrWithoutItsSlugFolder(folder: String) {
        let plan = Gate.plan(arguments: server + [folder + "/"], environment: environment)
        #expect(plan.map(\.claim) == .success(.folder(folder)))
    }

}

private func currentUmask() -> mode_t {
    let mask = umask(0)
    umask(mask)
    return mask
}

private struct TemporaryFolder {
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.resolvingSymlinksInPath().path
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

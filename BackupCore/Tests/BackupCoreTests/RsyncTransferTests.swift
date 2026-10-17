import Darwin
import Foundation
import Testing
@testable import BackupCore

struct RsyncTransferTests {
    private let temp = try! TempDirectory()
    private var transfer: RsyncTransfer {
        RsyncTransfer(rsync: RsyncTransfer.homebrewRsync, receiver: nil, runner: SystemProcessRunner(), scratch: temp.path("scratch"))
    }

    @Test func rsyncFromHomebrewIsInstalled() {
        #expect(FileManager.default.isExecutableFile(atPath: RsyncTransfer.homebrewRsync.path), "brew install rsync")
    }

    @Test func writesAFolderWithExclusionsAndMarksItComplete() async throws {
        defer { temp.remove() }
        try temp.file("src/a.md", "alpha")
        try temp.file("src/cache/b.tmp", "beta")
        try temp.file("src/.DS_Store", "x")
        let copy = temp.path("dst/obsidian/2026-10-08_100000")
        let payload = Payload(root: temp.path("src"), excludes: ["cache", ".DS_Store"], collectedAt: Date())
        _ = try await transfer.write(payload, into: copy, linkDests: [])
        #expect(temp.names(in: "dst/obsidian/2026-10-08_100000") == ["a.md"])
        try await transfer.markComplete(copy)
        try await transfer.markComplete(copy)
        #expect(temp.names(in: "dst/obsidian/2026-10-08_100000") == [".complete", "a.md"])
        #expect(temp.names(in: "scratch") == ["complete"])
    }

    @Test func unchangedFilesBecomeHardLinksOfThePreviousCopy() async throws {
        defer { temp.remove() }
        try temp.file("src/a.md", "alpha")
        try temp.file("src/b.md", "beta")
        let first = temp.path("dst/obsidian/2026-10-07_100000")
        let second = temp.path("dst/obsidian/2026-10-08_100000")
        _ = try await transfer.write(Payload(root: temp.path("src"), collectedAt: Date()), into: first, linkDests: [])
        try await transfer.markComplete(first)
        try Data("beta2".utf8).write(to: temp.path("src/b.md"))
        _ = try await transfer.write(Payload(root: temp.path("src"), collectedAt: Date()), into: second, linkDests: [first])
        let inode = { (relative: String) in try FileManager.default.attributesOfItem(atPath: temp.path(relative).path)[.systemFileNumber] as? UInt64 }
        #expect(try inode("dst/obsidian/2026-10-07_100000/a.md") == inode("dst/obsidian/2026-10-08_100000/a.md"))
        #expect(try inode("dst/obsidian/2026-10-07_100000/b.md") != inode("dst/obsidian/2026-10-08_100000/b.md"))
        #expect(try String(contentsOf: temp.path("dst/obsidian/2026-10-07_100000/b.md"), encoding: .utf8) == "beta")
    }

    @Test func writesASingleFileIntoTheCopyFolder() async throws {
        defer { temp.remove() }
        try temp.file("export.csv", "a,b")
        let copy = temp.path("dst/finance/2026-10-08_100000")
        _ = try await transfer.write(Payload(root: temp.path("export.csv"), collectedAt: Date()), into: copy, linkDests: [])
        #expect(temp.names(in: "dst/finance/2026-10-08_100000") == ["export.csv"])
    }

    @Test func aSymlinkToAFileIsCopiedAsTheFileUnderTheLinkName() async throws {
        defer { temp.remove() }
        try temp.file("src/real.csv", "a,b")
        try FileManager.default.createSymbolicLink(at: temp.path("src/link.csv"), withDestinationURL: temp.path("src/real.csv"))
        let copy = temp.path("dst/finance/2026-10-08_100000")
        _ = try await transfer.write(Payload(root: temp.path("src/link.csv"), collectedAt: Date()), into: copy, linkDests: [])
        #expect(temp.names(in: "dst/finance/2026-10-08_100000") == ["link.csv"])
        let attributes = try FileManager.default.attributesOfItem(atPath: copy.appendingPathComponent("link.csv").path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(try String(contentsOf: copy.appendingPathComponent("link.csv"), encoding: .utf8) == "a,b")
    }

    @Test func missingSourceFailsWithRsyncError() async throws {
        defer { temp.remove() }
        let copy = temp.path("dst/x/2026-10-08_100000")
        await #expect(throws: DestinationError.self) {
            _ = try await transfer.write(Payload(root: temp.path("gone"), collectedAt: Date()), into: copy, linkDests: [])
        }
        #expect(!temp.exists("dst/x/2026-10-08_100000/.complete"))
    }

    @Test func missingRsyncIsToldAsSuch() async throws {
        defer { temp.remove() }
        let transfer = RsyncTransfer(rsync: temp.path("no-rsync"), receiver: nil, runner: SystemProcessRunner(), scratch: temp.path("scratch"))
        await #expect(throws: DestinationError.rsyncMissing) {
            try await transfer.markComplete(temp.path("dst/x/2026-10-08_100000"))
        }
    }

    @Test func receiverCommandBecomesTheRshOption() async throws {
        defer { temp.remove() }
        let runner = FakeProcessRunner()
        let transfer = RsyncTransfer(rsync: RsyncTransfer.homebrewRsync, receiver: .standard, runner: runner, scratch: temp.path("scratch"))
        _ = try await transfer.write(Payload(root: temp.path("src"), collectedAt: Date()), into: temp.path("dst/obsidian/2026-10-08_100000"), linkDests: [temp.path("dst/obsidian/2026-10-07_100000"), temp.path("dst/obsidian/2026-10-08_090000")])
        let arguments = runner.calls.last?.arguments ?? []
        #expect(arguments.contains("--rsh=/usr/bin/sudo -n -u _backupeverything /usr/local/libexec/backup-everything/backup-receiver"))
        #expect(arguments.filter { $0.hasPrefix("--link-dest=") } == [
            "--link-dest=\(temp.path("dst/obsidian/2026-10-07_100000").path)",
            "--link-dest=\(temp.path("dst/obsidian/2026-10-08_090000").path)",
        ])
        #expect(arguments.last == "backup:\(temp.path("dst/obsidian/2026-10-08_100000").path)/")
        #expect(arguments.contains("--inplace") && arguments.contains("--mkpath") && arguments.contains("-rltDX"))
        #expect(arguments.contains("--chmod=ugo=rwX"))
        #expect(!arguments.contains { $0.hasPrefix("-a") || $0.hasPrefix("-p") || $0.hasPrefix("--perms") })
        #expect(!arguments.contains { $0.hasPrefix("--delete") })
    }

    /// With secluded args (`-s`, which RSYNC_PROTECT_ARGS in the app's environment would switch on) rsync sends the
    /// arguments past the gate; RSYNC_OLD_ARGS=0 rules that out and keeps the escaping the gate removes.
    @Test func everyRsyncCallFixesTheArgumentMode() async throws {
        defer { temp.remove() }
        let runner = FakeProcessRunner()
        let transfer = RsyncTransfer(rsync: RsyncTransfer.homebrewRsync, receiver: .standard, runner: runner, scratch: temp.path("scratch"))
        let copy = temp.path("dst/obsidian/2026-10-08_100000")
        _ = try await transfer.write(Payload(root: temp.path("src"), collectedAt: Date()), into: copy, linkDests: [])
        try await transfer.markComplete(copy)
        #expect(runner.calls.count == 2)
        #expect(runner.calls.allSatisfy { $0.environment == ["RSYNC_OLD_ARGS": "0"] })
    }

    /// Modes of the originals are not kept: the receiver's umask decides them (the gate sets 027, here the default 022).
    @Test func copyModesComeFromTheReceiverUmaskNotFromTheOriginals() async throws {
        defer { temp.remove() }
        try temp.file("src/secret.md", "alpha")
        try temp.file("src/run.sh", "echo")
        #expect(chmod(temp.path("src").path, 0o700) == 0)
        #expect(chmod(temp.path("src/secret.md").path, 0o600) == 0)
        #expect(chmod(temp.path("src/run.sh").path, 0o755) == 0)
        let copy = temp.path("dst/notes/2026-10-08_100000")
        _ = try await transfer.write(Payload(root: temp.path("src"), collectedAt: Date()), into: copy, linkDests: [])
        let mode = { (relative: String) in try (FileManager.default.attributesOfItem(atPath: temp.path(relative).path)[.posixPermissions] as? Int ?? 0) }
        #expect(try mode("dst/notes/2026-10-08_100000") == 0o755)
        #expect(try mode("dst/notes/2026-10-08_100000/secret.md") == 0o644)
        #expect(try mode("dst/notes/2026-10-08_100000/run.sh") == 0o755)
    }

    /// Code 24: files vanished during the transfer (a live folder). Everything else is in the copy; it is a warning.
    @Test func vanishedFilesAreAWarningAndOtherFailuresAnError() async throws {
        defer { temp.remove() }
        let vanished = RsyncTransfer(rsync: RsyncTransfer.homebrewRsync, receiver: nil, runner: FakeProcessRunner { _ in
            ProcessResult(exitCode: 24, stderr: "file has vanished: \"/src/tmp.lock\"")
        }, scratch: temp.path("scratch"))
        let warning = try await vanished.write(Payload(root: temp.path("src"), collectedAt: Date()), into: temp.path("dst/x/2026-10-08_100000"), linkDests: [])
        #expect(warning == "file has vanished: \"/src/tmp.lock\"")

        let broken = RsyncTransfer(rsync: RsyncTransfer.homebrewRsync, receiver: nil, runner: FakeProcessRunner { _ in
            ProcessResult(exitCode: 23, stderr: "some files could not be transferred")
        }, scratch: temp.path("scratch"))
        await #expect(throws: DestinationError.commandFailed("some files could not be transferred")) {
            try await broken.write(Payload(root: temp.path("src"), collectedAt: Date()), into: temp.path("dst/x/2026-10-08_100000"), linkDests: [])
        }
    }

    /// The walker reads exclusions the way rsync does; this pins rsync's side of the `*` and `**` rule.
    @Test(arguments: [("build/*.o", ["sub", "y.o"]), ("build/**.o", ["sub"])])
    func rsyncKeepsSingleStarInsideOneName(pattern: String, kept: [String]) async throws {
        defer { temp.remove() }
        try temp.file("src/build/x.o", "x")
        try temp.file("src/build/sub/y.o", "y")
        let copy = temp.path("dst/code/2026-10-08_100000")
        _ = try await transfer.write(Payload(root: temp.path("src"), excludes: [pattern], collectedAt: Date()), into: copy, linkDests: [])
        #expect(temp.names(in: "dst/code/2026-10-08_100000/build") == ["sub"])
        #expect(temp.names(in: "dst/code/2026-10-08_100000/build/sub") == Array(kept.dropFirst()))
    }
}

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
        try await transfer.write(payload, into: copy, linkDest: nil)
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
        try await transfer.write(Payload(root: temp.path("src"), collectedAt: Date()), into: first, linkDest: nil)
        try await transfer.markComplete(first)
        try Data("beta2".utf8).write(to: temp.path("src/b.md"))
        try await transfer.write(Payload(root: temp.path("src"), collectedAt: Date()), into: second, linkDest: first)
        let inode = { (relative: String) in try FileManager.default.attributesOfItem(atPath: temp.path(relative).path)[.systemFileNumber] as? UInt64 }
        #expect(try inode("dst/obsidian/2026-10-07_100000/a.md") == inode("dst/obsidian/2026-10-08_100000/a.md"))
        #expect(try inode("dst/obsidian/2026-10-07_100000/b.md") != inode("dst/obsidian/2026-10-08_100000/b.md"))
        #expect(try String(contentsOf: temp.path("dst/obsidian/2026-10-07_100000/b.md"), encoding: .utf8) == "beta")
    }

    @Test func writesASingleFileIntoTheCopyFolder() async throws {
        defer { temp.remove() }
        try temp.file("export.csv", "a,b")
        let copy = temp.path("dst/finance/2026-10-08_100000")
        try await transfer.write(Payload(root: temp.path("export.csv"), collectedAt: Date()), into: copy, linkDest: nil)
        #expect(temp.names(in: "dst/finance/2026-10-08_100000") == ["export.csv"])
    }

    @Test func aSymlinkToAFileIsCopiedAsTheFileUnderTheLinkName() async throws {
        defer { temp.remove() }
        try temp.file("src/real.csv", "a,b")
        try FileManager.default.createSymbolicLink(at: temp.path("src/link.csv"), withDestinationURL: temp.path("src/real.csv"))
        let copy = temp.path("dst/finance/2026-10-08_100000")
        try await transfer.write(Payload(root: temp.path("src/link.csv"), collectedAt: Date()), into: copy, linkDest: nil)
        #expect(temp.names(in: "dst/finance/2026-10-08_100000") == ["link.csv"])
        let attributes = try FileManager.default.attributesOfItem(atPath: copy.appendingPathComponent("link.csv").path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(try String(contentsOf: copy.appendingPathComponent("link.csv"), encoding: .utf8) == "a,b")
    }

    @Test func missingSourceFailsWithRsyncError() async throws {
        defer { temp.remove() }
        let copy = temp.path("dst/x/2026-10-08_100000")
        await #expect(throws: DestinationError.self) {
            try await transfer.write(Payload(root: temp.path("gone"), collectedAt: Date()), into: copy, linkDest: nil)
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
        try await transfer.write(Payload(root: temp.path("src"), collectedAt: Date()), into: temp.path("dst/obsidian/2026-10-08_100000"), linkDest: temp.path("dst/obsidian/2026-10-07_100000"))
        let arguments = runner.calls.last?.arguments ?? []
        #expect(arguments.contains("--rsh=/usr/bin/sudo -n -u _backupeverything /usr/local/libexec/backup-everything/backup-receiver"))
        #expect(arguments.contains("--link-dest=\(temp.path("dst/obsidian/2026-10-07_100000").path)"))
        #expect(arguments.last == "backup:\(temp.path("dst/obsidian/2026-10-08_100000").path)/")
        #expect(arguments.contains("--inplace") && arguments.contains("--mkpath") && arguments.contains("-aAX"))
        #expect(!arguments.contains { $0.hasPrefix("--delete") })
    }
}

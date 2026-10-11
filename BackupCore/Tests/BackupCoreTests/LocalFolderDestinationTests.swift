import Darwin
import Foundation
import Testing
@testable import BackupCore

struct LocalFolderDestinationTests {
    private let temp = try! TempDirectory()
    private var destination: LocalFolderDestination {
        LocalFolderDestination(
            root: temp.path("dest"),
            naming: Fixtures.naming,
            access: AlwaysReadyAccess(),
            transfer: RsyncTransfer(rsync: RsyncTransfer.homebrewRsync, receiver: nil, runner: SystemProcessRunner(), scratch: temp.path("scratch"))
        )
    }

    @Test func writesACompleteCopyAndListsIt() async throws {
        defer { temp.remove() }
        try temp.directory("dest")
        try temp.file("src/a.md", "alpha")
        let payload = Payload(root: temp.path("src"), collectedAt: Fixtures.date("2026-10-08 10:00:00"))
        try await destination.write(payload, sourceSlug: "obsidian", snapshotName: "2026-10-08_100000")
        #expect(temp.names(in: "dest/obsidian/2026-10-08_100000") == [".complete", "a.md"])
        #expect(try await destination.copies(of: "obsidian") == [Fixtures.snapshot("2026-10-08 10:00:00")])
    }

    @Test func secondCopyLinksUnchangedFilesToTheFirst() async throws {
        defer { temp.remove() }
        try temp.directory("dest")
        try temp.file("src/a.md", "alpha")
        try await destination.write(Payload(root: temp.path("src"), collectedAt: Fixtures.date("2026-10-07 10:00:00")), sourceSlug: "obsidian", snapshotName: "2026-10-07_100000")
        try await destination.write(Payload(root: temp.path("src"), collectedAt: Fixtures.date("2026-10-08 10:00:00")), sourceSlug: "obsidian", snapshotName: "2026-10-08_100000")
        let links = try FileManager.default.attributesOfItem(atPath: temp.path("dest/obsidian/2026-10-08_100000/a.md").path)[.referenceCount] as? Int
        #expect(links == 2)
    }

    @Test func interruptedCopyStaysUnfinishedAndIsResumed() async throws {
        defer { temp.remove() }
        try temp.directory("dest")
        try temp.file("src/a.md", "alpha")
        try temp.file("dest/obsidian/2026-10-08_100000/stale.md", "left by a crash")
        #expect(try await destination.unfinishedCopies(of: "obsidian") == [Fixtures.snapshot("2026-10-08 10:00:00")])
        #expect(try await destination.copies(of: "obsidian") == [])
        try await destination.write(Payload(root: temp.path("src"), collectedAt: Fixtures.date("2026-10-08 10:00:00")), sourceSlug: "obsidian", snapshotName: "2026-10-08_100000")
        #expect(temp.names(in: "dest/obsidian/2026-10-08_100000") == [".complete", "a.md", "stale.md"])
    }

    @Test func failedCopyLeavesNoMarkerAndTouchesNoOtherCopy() async throws {
        defer { temp.remove() }
        try temp.directory("dest")
        try temp.file("dest/obsidian/2026-10-07_100000/.complete", "")
        try temp.file("dest/obsidian/2026-10-07_100000/a.md", "old")
        await #expect(throws: DestinationError.self) {
            try await destination.write(Payload(root: temp.path("gone"), collectedAt: Fixtures.date("2026-10-08 10:00:00")), sourceSlug: "obsidian", snapshotName: "2026-10-08_100000")
        }
        #expect(!temp.exists("dest/obsidian/2026-10-08_100000/.complete"))
        #expect(try String(contentsOf: temp.path("dest/obsidian/2026-10-07_100000/a.md"), encoding: .utf8) == "old")
    }

    @Test func notReadyFolderRefusesToWrite() async throws {
        defer { temp.remove() }
        try temp.file("src/a.md", "alpha")
        await #expect(throws: DestinationError.notReady(.folderMissing)) {
            try await destination.write(Payload(root: temp.path("src"), collectedAt: Date()), sourceSlug: "obsidian", snapshotName: "2026-10-08_100000")
        }
        #expect(!temp.exists("dest"))
    }

    @Test func usedBytesSumsEverythingUnderRoot() async throws {
        defer { temp.remove() }
        try temp.file("dest/obsidian/2026-10-08_100000/a.md", "alpha")
        try temp.file("dest/obsidian/2026-10-08_100000/sub/b.md", "abc")
        try temp.file("dest/obsidian/2026-10-08_100000/sub/._c.md", String(repeating: "c", count: 10_000))
        let files = ["a.md", "sub/b.md", "sub/._c.md"].map { "dest/obsidian/2026-10-08_100000/" + $0 }
        #expect(try await destination.usedBytes() == temp.allocatedBytes(files[0], files[1], files[2]))
    }

    @Test func usedBytesCountsAHardLinkedFileOnce() async throws {
        defer { temp.remove() }
        let original = try temp.file("dest/obsidian/2026-10-07_100000/a.md", String(repeating: "a", count: 10_000))
        try temp.directory("dest/obsidian/2026-10-08_100000")
        #expect(link(original.path, temp.path("dest/obsidian/2026-10-08_100000/a.md").path) == 0)
        #expect(try await destination.usedBytes() == temp.allocatedBytes("dest/obsidian/2026-10-07_100000/a.md"))
    }

    /// The size is an estimate for showing: a folder that cannot be read is left out, not the whole measurement.
    @Test func usedBytesLeavesOutFoldersThatCannotBeRead() async throws {
        defer {
            Permissions.unlockTree(temp.url)
            temp.remove()
        }
        try temp.file("dest/obsidian/2026-10-08_100000/a.md", "alpha")
        try temp.file("dest/obsidian/closed/b.md", "beta")
        #expect(chmod(temp.path("dest/obsidian/closed").path, 0o000) == 0)
        #expect(try await destination.usedBytes() == temp.allocatedBytes("dest/obsidian/2026-10-08_100000/a.md"))
    }

    @Test func notReadyFolderIsNotMeasured() async throws {
        defer { temp.remove() }
        await #expect(throws: DestinationError.notReady(.folderMissing)) { try await destination.usedBytes() }
    }

    @Test(arguments: ["", "/", "a/b", ".", "..", "../dest"])
    func folderNameThatIsNotOneFolderIsRefused(slug: String) async throws {
        defer { temp.remove() }
        try temp.directory("dest")
        try temp.file("src/a.md", "alpha")
        let refused = DestinationError.invalidFolderName(slug)
        await #expect(throws: refused) { try await destination.copies(of: slug) }
        await #expect(throws: refused) { try await destination.unfinishedCopies(of: slug) }
        await #expect(throws: refused) {
            try await destination.write(Payload(root: temp.path("src"), collectedAt: Date()), sourceSlug: slug, snapshotName: "2026-10-08_100000")
        }
        #expect(temp.names(in: "dest").isEmpty)
    }
}

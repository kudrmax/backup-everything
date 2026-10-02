import Foundation
import Testing
@testable import BackupCore

struct ManualExportInboxTests {
    private let temp: TempDirectory
    private let inbox: ManualExportInbox
    private let created = Fixtures.date("2026-09-01 00:00:00")
    private let now = Fixtures.date("2026-09-28 14:30:00")
    private let sourceId = UUID()

    init() throws {
        let temp = try TempDirectory()
        self.temp = temp
        try temp.directory("Downloads")
        try temp.directory("trash")
        inbox = ManualExportInbox(pendingRoot: temp.path("pending"), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)"))
        }
    }

    private func scan(_ pattern: String = "takeout-*.zip", since: Date? = nil) -> InboxScan {
        inbox.scan(watchPath: temp.path("Downloads").path, filePattern: pattern, since: since ?? created, now: now)
    }

    @Test func findsNewMatchingFilesCaseInsensitively() throws {
        defer { temp.remove() }
        try temp.file("Downloads/takeout-001.zip", "12345", modified: now.addingTimeInterval(-600))
        try temp.file("Downloads/Takeout-002.ZIP", "123", modified: now.addingTimeInterval(-300))
        try temp.file("Downloads/other.pdf", "x", modified: now.addingTimeInterval(-300))

        let result = scan()
        #expect(result.files.map(\.lastPathComponent) == ["Takeout-002.ZIP", "takeout-001.zip"])
        #expect(result.totalBytes == 8)
        #expect(result.isReady)
    }

    @Test func ignoresFilesOlderThanLastPickupAndEmptyPlaceholders() throws {
        defer { temp.remove() }
        try temp.file("Downloads/takeout-old.zip", "old", modified: created.addingTimeInterval(-86_400))
        try temp.file("Downloads/takeout-empty.zip", "", modified: now.addingTimeInterval(-600))
        #expect(scan() == .empty)
    }

    @Test(arguments: ["Unconfirmed 1234.crdownload", "takeout-002.zip.part", "takeout-002.zip.download"])
    func unfinishedDownloadBlocksPickup(name: String) throws {
        defer { temp.remove() }
        try temp.file("Downloads/takeout-001.zip", "12345", modified: now.addingTimeInterval(-600))
        try temp.file("Downloads/\(name)", "partial", modified: now.addingTimeInterval(-1))
        let result = scan()
        #expect(result.files.count == 1)
        #expect(result.downloadInProgress)
        #expect(!result.isReady)
    }

    @Test func freshlyWrittenFileIsNotSettledYet() throws {
        defer { temp.remove() }
        try temp.file("Downloads/takeout-001.zip", "12345", modified: now.addingTimeInterval(-2))
        let result = scan()
        #expect(result.files.isEmpty)
        #expect(result.downloadInProgress)
    }

    @Test func missingWatchFolderIsEmptyScan() {
        defer { temp.remove() }
        #expect(inbox.scan(watchPath: temp.path("nope").path, filePattern: "*", since: created, now: now) == .empty)
    }

    @Test func pendingSourceCollectsThePackageAndKeepsItUntilDeliveredEverywhere() async throws {
        defer { temp.remove() }
        let source = PendingSource(sourceId: sourceId, trashAfterDelivery: true, inbox: inbox)
        await #expect(throws: SourceError.nothingToCollect) { try await source.collect(at: now) }

        try temp.file("run/takeout-001.zip", "12345")
        let package = try inbox.adopt(sourceId: sourceId, directory: temp.path("run"), at: now)
        let payload = try await source.collect(at: now.addingTimeInterval(3600))
        #expect(payload == Payload(root: package.directory, collectedAt: now, madeEarlier: true))

        source.finish(payload, deliveredEverywhere: false)
        #expect(inbox.pendingPackage(for: sourceId) != nil)
        source.finish(payload, deliveredEverywhere: true)
        #expect(inbox.pendingPackage(for: sourceId) == nil)
        #expect(temp.names(in: "trash") == ["takeout-001.zip"])
    }

    @Test func packageBuiltFromCopiesIsRemovedWithoutTheTrash() async throws {
        defer { temp.remove() }
        let source = PendingSource(sourceId: sourceId, trashAfterDelivery: false, inbox: inbox)
        try temp.file("run/book.epub", "epub")
        _ = try inbox.adopt(sourceId: sourceId, directory: temp.path("run"), at: now)
        source.finish(try await source.collect(at: now), deliveredEverywhere: true)
        #expect(inbox.pendingPackage(for: sourceId) == nil)
        #expect(temp.names(in: "trash").isEmpty)
    }

    @Test func adoptedFolderBecomesThePendingPackageAndReplacesTheOldOne() throws {
        defer { temp.remove() }
        let first = Fixtures.date("2026-09-28 10:00:00")
        let second = Fixtures.date("2026-09-29 10:00:00")

        try temp.file("chain/output/old.zip", "old")
        let oldPackage = try inbox.adopt(sourceId: sourceId, directory: temp.path("chain/output"), at: first)
        #expect(oldPackage.collectedAt == first)
        #expect(!temp.exists("chain/output"))

        try temp.file("chain/output/new.zip", "new")
        let package = try inbox.adopt(sourceId: sourceId, directory: temp.path("chain/output"), at: second)

        #expect(inbox.pendingPackage(for: sourceId) == package)
        #expect(package.collectedAt == second)
        #expect(temp.names(in: "pending/\(sourceId.uuidString)") == ["2026-09-29_100000"])
        #expect(temp.names(in: "pending/\(sourceId.uuidString)/2026-09-29_100000") == ["new.zip"])
        #expect(temp.names(in: "trash") == ["old.zip"])
    }

    @Test func newestOfSeveralPendingPackagesIsTheOneDelivered() throws {
        defer { temp.remove() }
        let base = "pending/\(sourceId.uuidString)"
        try temp.file("\(base)/2026-09-20_100000/old.zip", "old")
        try temp.file("\(base)/2026-09-27_100000/new.zip", "new")
        try temp.file("\(base)/2026-09-25_100000/middle.zip", "middle")
        try temp.directory("\(base)/not a package")

        let package = try #require(inbox.pendingPackage(for: sourceId))
        #expect(package.collectedAt == Fixtures.date("2026-09-27 10:00:00"))
        #expect(package.directory.lastPathComponent == "2026-09-27_100000")
    }

    @Test func removingAPackageTrashesOnlyItsFilesWhenAsked() throws {
        defer { temp.remove() }
        let base = "pending/\(sourceId.uuidString)"
        try temp.file("\(base)/2026-09-27_100000/takeout.zip", "zip")
        try inbox.removePackage(for: sourceId, toTrash: false)
        #expect(temp.names(in: "trash").isEmpty)
        #expect(!temp.exists(base))

        try temp.file("\(base)/2026-09-27_100000/takeout.zip", "zip")
        try inbox.removePackage(for: sourceId, toTrash: true)
        #expect(temp.names(in: "trash") == ["takeout.zip"])
        #expect(inbox.sourceIds().isEmpty)
    }
}

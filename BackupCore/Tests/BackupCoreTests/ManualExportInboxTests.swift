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

    @Test func pickUpMovesFilesAndTrashesThemAfterDelivery() throws {
        defer { temp.remove() }
        let file = try temp.file("Downloads/takeout-001.zip", "12345", modified: now.addingTimeInterval(-600))
        let package = try inbox.pickUp(sourceId: sourceId, files: [file], removeOriginal: true, at: now)

        #expect(!temp.exists("Downloads/takeout-001.zip"))
        #expect(package.collectedAt == now)
        #expect(inbox.pendingPackage(for: sourceId) == package)
        #expect(FileManager.default.fileExists(atPath: package.directory.appendingPathComponent("takeout-001.zip").path))

        try inbox.removePackage(for: sourceId, toTrash: true)
        #expect(inbox.pendingPackage(for: sourceId) == nil)
        #expect(temp.names(in: "trash") == ["takeout-001.zip"])
    }

    @Test func pickUpCopiesWhenOriginalMustStay() throws {
        defer { temp.remove() }
        let file = try temp.file("Downloads/Passwords.csv", "secret", modified: now.addingTimeInterval(-600))
        _ = try inbox.pickUp(sourceId: sourceId, files: [file], removeOriginal: false, at: now)
        #expect(temp.exists("Downloads/Passwords.csv"))

        try inbox.removePackage(for: sourceId, toTrash: false)
        #expect(temp.names(in: "trash").isEmpty)
        #expect(temp.exists("Downloads/Passwords.csv"))
        #expect(scan("Passwords*.csv", since: now) == .empty)
    }

    @Test func newerPackageReplacesUndeliveredOne() throws {
        defer { temp.remove() }
        let first = try temp.file("Downloads/takeout-a.zip", "first", modified: now.addingTimeInterval(-600))
        _ = try inbox.pickUp(sourceId: sourceId, files: [first], removeOriginal: true, at: now)
        let later = now.addingTimeInterval(86_400)
        let second = try temp.file("Downloads/takeout-b.zip", "second", modified: later.addingTimeInterval(-600))
        let package = try inbox.pickUp(sourceId: sourceId, files: [second], removeOriginal: true, at: later)

        #expect(inbox.pendingPackage(for: sourceId) == package)
        #expect(temp.names(in: "pending/\(sourceId.uuidString)") == [Fixtures.naming.name(for: later)])
        #expect(temp.names(in: "trash") == ["takeout-a.zip"])
    }

    @Test func manualSourceCollectsPendingPackageAndKeepsItUntilDeliveredEverywhere() async throws {
        defer { temp.remove() }
        let source = ManualExportSource(sourceId: sourceId, removeOriginal: true, inbox: inbox)
        await #expect(throws: SourceError.nothingToCollect) { try await source.collect(at: now) }

        let file = try temp.file("Downloads/takeout-001.zip", "12345", modified: now.addingTimeInterval(-600))
        let package = try inbox.pickUp(sourceId: sourceId, files: [file], removeOriginal: true, at: now)
        let payload = try await source.collect(at: now.addingTimeInterval(3600))
        #expect(payload == Payload(root: package.directory, collectedAt: now))

        source.finish(payload, deliveredEverywhere: false)
        #expect(inbox.pendingPackage(for: sourceId) != nil)
        source.finish(payload, deliveredEverywhere: true)
        #expect(inbox.pendingPackage(for: sourceId) == nil)
    }

    @Test func failedPickUpRestoresOriginalsAndKeepsPreviousPackage() throws {
        defer { temp.remove() }
        let old = try temp.file("Downloads/takeout-old.zip", "old", modified: now.addingTimeInterval(-900))
        let previous = try inbox.pickUp(sourceId: sourceId, files: [old], removeOriginal: true, at: now.addingTimeInterval(-800))
        let first = try temp.file("Downloads/takeout-001.zip", "12345", modified: now.addingTimeInterval(-600))
        let vanished = temp.path("Downloads/takeout-002.zip")

        #expect(throws: (any Error).self) {
            try inbox.pickUp(sourceId: sourceId, files: [first, vanished], removeOriginal: true, at: now)
        }
        #expect(temp.names(in: "Downloads") == ["takeout-001.zip"])
        #expect(inbox.pendingPackage(for: sourceId) == previous)
        #expect(temp.names(in: "pending") == [sourceId.uuidString])
        #expect(temp.names(in: "trash").isEmpty)
    }

    @Test func emptyPatternMatchesNothing() throws {
        defer { temp.remove() }
        try temp.file("Downloads/Passwords.csv", "secret", modified: now.addingTimeInterval(-600))
        #expect(scan("") == .empty)
    }
}

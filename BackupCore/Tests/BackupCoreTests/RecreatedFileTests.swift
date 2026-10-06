import Darwin
import Foundation
import Testing
@testable import BackupCore

/// Live folders delete files and create them again under the same names while they are copied: database journals, lock
/// files, collections of an open app. An item whose original was not there when the copy engine reached it is legitimately
/// absent from the copy, even when it is back by the time the copy is checked; the check goes by what the engine reported.
struct RecreatedFileTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"
    private let sourceId = UUID()

    init() throws {
        temp = try TempDirectory()
    }

    private func listing() throws -> PayloadListing {
        try PayloadWalker().listing(of: Payload(root: temp.path("vault"), collectedAt: date))
    }

    private func manifest() -> SnapshotManifest {
        SnapshotManifest(sourceId: sourceId, sourceName: "Anki", collectedAt: date, fileCount: 0, totalBytes: 0)
    }

    private func content(_ relative: String) -> String? {
        (try? Data(contentsOf: temp.path(relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func fileGoneWhenTheEngineReachedItAndBackBeforeTheCheckIsLeftOut() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/c.md-journal", "journal")
        try temp.file("vault/sub/b.md", "beta")
        try temp.file("vault/sub/lock", "lock")
        let listing = try listing()
        try FileManager.default.removeItem(at: temp.path("vault/c.md-journal"))
        try FileManager.default.removeItem(at: temp.path("vault/sub/lock"))
        let writer = SnapshotWriter(cloning: APFSCloning(), beforeReadingBack: { [temp] in
            _ = try? temp.file("vault/c.md-journal", "a new journal")
            _ = try? temp.file("vault/sub/lock", "lock")
        })

        let written = try writer.write(listing, into: try temp.directory("copy"), sharingWith: nil)

        #expect(written.files.map(\.path) == ["a.md", "sub/b.md"])
        #expect(temp.names(in: "copy") == ["a.md", "sub"])
        #expect(temp.names(in: "copy/sub") == ["b.md"])
    }

    /// The engine had already read the folder when the files went; it found them missing when it came to copy them.
    @Test func fileGoneAfterItsFolderWasReadAndBackBeforeTheCheckIsLeftOut() throws {
        defer { temp.remove() }
        for index in 0..<5 { try temp.file("vault/live/f\(index).tmp", "file \(index)") }
        let listing = try listing()
        let copy = try temp.directory("copy")
        var removed: [String] = []
        let written = try PayloadCopier().copy(listing, into: copy.path) { [temp] _ in
            guard removed.isEmpty else { return }
            for index in 0..<5 where !temp.exists("copy/live/f\(index).tmp") {
                try? FileManager.default.removeItem(at: temp.path("vault/live/f\(index).tmp"))
                removed.append("live/f\(index).tmp")
            }
        }
        for path in removed { try temp.file("vault/" + path, "back again") }

        let vanished = try written.check(in: copy.path)

        #expect(!removed.isEmpty)
        #expect(Set(vanished.map(\.relativePath)) == Set(removed))
        #expect(temp.names(in: "copy/live").count == 5 - removed.count)
    }

    @Test func copiedFileWhoseOriginalWasRecreatedBeforeTheCheckKeepsWhatWasRead() throws {
        defer { temp.remove() }
        try temp.file("vault/same-size", "alpha")
        try temp.file("vault/other-size", "beta")
        let writer = SnapshotWriter(cloning: APFSCloning(), beforeReadingBack: { [temp] in
            try? FileManager.default.removeItem(at: temp.path("vault/same-size"))
            try? FileManager.default.removeItem(at: temp.path("vault/other-size"))
            _ = try? temp.file("vault/same-size", "omega")
            _ = try? temp.file("vault/other-size", "a longer one")
        })

        let written = try writer.write(try listing(), into: try temp.directory("copy"), sharingWith: nil)

        #expect(written.files.map(\.path) == ["other-size", "same-size"])
        #expect(content("copy/same-size") == "alpha")
        #expect(content("copy/other-size") == "beta")
    }

    /// The engine read another version of the file than was listed, and the listed size is back once it is done: what was
    /// seen right after copying counts, so the copy holds what was read.
    @Test func fileRecreatedWithAnotherSizeWhileItWasCopiedKeepsWhatWasRead() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/b.md", "beta")
        let listing = try listing()
        try FileManager.default.removeItem(at: temp.path("vault/b.md"))
        try temp.file("vault/b.md", "beta, recreated longer")
        let copy = try temp.directory("copy")
        let written = try PayloadCopier().copy(listing, into: copy.path) { [temp] path in
            guard path.hasSuffix("/b.md") else { return }
            try? FileManager.default.removeItem(at: temp.path("vault/b.md"))
            _ = try? temp.file("vault/b.md", "beta")
        }

        #expect(try written.check(in: copy.path).isEmpty)
        #expect(content("copy/b.md") == "beta, recreated longer")
    }

    /// What the engine wrote must be in the copy whatever the original does meanwhile.
    @Test func writtenFileGoneFromTheCopyIsAnErrorEvenIfItsOriginalWasRecreated() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/b.md", "beta")
        let listing = try listing()
        let copy = try temp.directory("copy")
        let written = try PayloadCopier().copy(listing, into: copy.path)
        unlink(copy.path + "/a.md")
        try FileManager.default.removeItem(at: temp.path("vault/a.md"))
        try temp.file("vault/a.md", "alpha")

        #expect(throws: DestinationError.missingFromCopy(copy.path + "/a.md")) { try written.check(in: copy.path) }
    }

    /// The file goes once the source is listed, before anything is copied, and is back before the copy is checked.
    @Test func destinationFinishesTheCopyWithoutAFileRecreatedDuringIt() async throws {
        defer { temp.remove() }
        for index in 0..<5 { try temp.file("vault/d\(index)/f\(index).txt", "file \(index)") }
        let journal = temp.path("vault/d1/f1.txt")
        var destination = LocalFolderDestination(root: try temp.directory("disk"), naming: Fixtures.naming)
        destination.afterWritingItem = { path in
            if path.hasSuffix("/" + SnapshotManifest.unfinishedMarker) { try? FileManager.default.removeItem(at: journal) }
            if path.hasSuffix("/d4/f4.txt") { try? Data("file 1".utf8).write(to: journal) }
        }

        let written = try await destination.write(
            Payload(root: temp.path("vault"), collectedAt: date),
            manifest: manifest(),
            sourceSlug: "anki",
            snapshotName: name,
            reusingStoredFiles: true
        )

        #expect(written == PayloadStats(fileCount: 4, totalBytes: 24))
        #expect(temp.exists("vault/d1/f1.txt"))
        #expect(!temp.exists("disk/anki/\(name)/d1/f1.txt"))
        #expect(try await destination.listSnapshots(sourceSlug: "anki").map(\.name) == [name])
    }

    /// A real live folder: files keep vanishing and coming back under the same names while copies are written — created
    /// anew (journals, lock files) or moved away and back (the same file returns, grown), at random sizes. Every copy is finished.
    @Test(arguments: [Churn.Style.recreate, .moveAway])
    func copiesOfAFolderThatKeepsRecreatingItsFilesAreFinished(_ style: Churn.Style) async throws {
        defer { temp.remove() }
        for index in 0..<200 { try temp.file("vault/notes/n\(index).md", String(repeating: "n", count: index * 37)) }
        for index in 0..<10 { try temp.file("vault/live/tmp-\(index).tmp", "x") }
        let destination = LocalFolderDestination(root: try temp.directory("disk"), naming: Fixtures.naming)
        let churn = Churn(style, folder: temp.path("vault/live"), aside: try temp.directory("aside"))
        churn.start()
        defer { churn.stop() }

        for attempt in 0..<12 {
            try await destination.write(
                Payload(root: temp.path("vault"), collectedAt: date),
                manifest: manifest(),
                sourceSlug: "anki",
                snapshotName: String(format: "2026-09-28_1430%02d", attempt),
                reusingStoredFiles: attempt.isMultiple(of: 2)
            )
        }

        churn.stop()
        #expect(churn.cycles > 100)
        #expect(try await destination.listSnapshots(sourceSlug: "anki").count == 12)
    }
}

/// Makes the files of a folder vanish and come back under the same names, each growing to a random size in random pieces.
final class Churn: @unchecked Sendable {
    enum Style: Sendable {
        /// Deleted and created anew.
        case recreate
        /// Moved to a folder outside the source and back, growing while it is in the source.
        case moveAway
    }

    private let style: Style
    private let folder: URL
    private let aside: URL
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var running = false
    private var count = 0

    init(_ style: Style, folder: URL, aside: URL) {
        self.style = style
        self.folder = folder
        self.aside = aside
    }

    var cycles: Int {
        lock.withLock { count }
    }

    func start() {
        lock.withLock { running = true }
        Thread.detachNewThread { [self] in
            var index = 0
            while lock.withLock({ running }) {
                let name = "tmp-\(index % 10).tmp"
                cycle(folder.appendingPathComponent(name).path, aside: aside.appendingPathComponent(name).path)
                index += 1
                lock.withLock { count += 1 }
            }
            finished.signal()
        }
    }

    func stop() {
        let wasRunning = lock.withLock {
            defer { running = false }
            return running
        }
        if wasRunning { finished.wait() }
    }

    private func cycle(_ file: String, aside: String) {
        switch style {
        case .recreate:
            unlink(file)
            let descriptor = open(file, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard descriptor >= 0 else { return }
            grow(descriptor)
            close(descriptor)
        case .moveAway:
            if access(aside, F_OK) != 0 { close(open(aside, O_WRONLY | O_CREAT, 0o644)) }
            guard rename(aside, file) == 0 else { return }
            let descriptor = open(file, O_WRONLY | O_APPEND)
            if descriptor >= 0 {
                grow(descriptor)
                close(descriptor)
            }
            rename(file, aside)
        }
    }

    private func grow(_ descriptor: Int32) {
        var left = Int.random(in: 1...200_000)
        while left > 0 {
            let piece = min(left, Int.random(in: 1...65_536))
            let bytes = [UInt8](repeating: UInt8.random(in: 0...255), count: piece)
            _ = write(descriptor, bytes, piece)
            left -= piece
        }
    }
}

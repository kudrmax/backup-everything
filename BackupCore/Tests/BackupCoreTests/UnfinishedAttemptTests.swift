import Darwin
import Foundation
import Testing
@testable import BackupCore

/// Unfinished attempts are the app's scratch data, never a backup: before a new copy of the source is written, its earlier
/// attempts there are removed for good, so a small or full disk gets its space back instead of filling up with attempts.
struct UnfinishedAttemptTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"
    private let sourceId = UUID()

    init() throws {
        temp = try TempDirectory()
    }

    private func manifest() -> SnapshotManifest {
        SnapshotManifest(sourceId: sourceId, sourceName: "Photos", collectedAt: date, fileCount: 0, totalBytes: 0)
    }

    private func attempt(_ folder: URL, mark: String?, bytes: Int = 5) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try randomData(bytes).write(to: folder.appendingPathComponent("photo.raw"))
        try Data((mark ?? "Backup Everything was writing this copy and did not finish.\n").utf8)
            .write(to: folder.appendingPathComponent(SnapshotManifest.unfinishedMarker))
    }

    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private func freeBytes(_ url: URL) throws -> Int64 {
        var volume = statfs()
        guard statfs(url.path, &volume) == 0 else { throw POSIXError(.EIO) }
        return Int64(volume.f_bavail) * Int64(volume.f_bsize)
    }

    /// APFS frees the blocks of removed files a moment later.
    private func spaceComesBack(on root: URL, toMoreThan bytes: Int64) async throws -> Bool {
        for _ in 0..<100 {
            if try freeBytes(root) > bytes { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func markNamesTheSourceWhoseCopyIsWritten() throws {
        let note = Data(SnapshotManifest.unfinishedNote(sourceId: sourceId).utf8)
        #expect(SnapshotManifest.unfinishedOwner(of: note) == sourceId)
        #expect(SnapshotManifest.unfinishedOwner(of: Data("Backup Everything was writing this copy.\n".utf8)) == nil)
        #expect(SnapshotManifest.unfinishedAttempt(withMark: note, belongsTo: sourceId))
        #expect(!SnapshotManifest.unfinishedAttempt(withMark: note, belongsTo: UUID()))
        #expect(SnapshotManifest.unfinishedAttempt(withMark: Data("old mark\n".utf8), belongsTo: UUID()))
    }

    @Test func onlyTheSourcesOwnAttemptsAreRemoved() async throws {
        defer { temp.remove() }
        let disk = try temp.directory("disk")
        let destination = LocalFolderDestination(root: disk, naming: Fixtures.naming)
        try attempt(temp.path("disk/photos/2026-09-25_100000"), mark: SnapshotManifest.unfinishedNote(sourceId: sourceId))
        try attempt(temp.path("disk/photos/2026-09-26_100000"), mark: nil)
        try attempt(temp.path("disk/photos/2026-09-27_100000"), mark: SnapshotManifest.unfinishedNote(sourceId: UUID()))
        try temp.file("disk/photos/2026-09-24_100000/photo.raw")

        try await destination.removeIncomplete(sourceSlug: "photos", sourceId: sourceId)

        #expect(temp.names(in: "disk/photos") == ["2026-09-24_100000", "2026-09-27_100000"])
    }

    /// A second running instance may be writing a copy of the same source there: its attempt is not abandoned.
    @Test func attemptBeingWrittenIsLeftAlone() async throws {
        defer { temp.remove() }
        let destination = LocalFolderDestination(root: try temp.directory("disk"), naming: Fixtures.naming)
        let folder = try temp.directory("disk/photos/\(name)")
        var writing: UnfinishedMark? = try UnfinishedMark.create(in: folder, sourceId: sourceId)
        try temp.file("vault/photo.raw", "raw")

        try await destination.removeIncomplete(sourceSlug: "photos", sourceId: sourceId)
        #expect(temp.exists("disk/photos/\(name)/_unfinished"))
        await #expect(throws: DestinationError.copyInProgress(folder.path)) {
            try await destination.write(Payload(root: temp.path("vault"), collectedAt: date), manifest: manifest(), sourceSlug: "photos", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(temp.exists("disk/photos/\(name)/_unfinished"))

        writing = nil
        #expect(writing == nil)
        try await destination.removeIncomplete(sourceSlug: "photos", sourceId: sourceId)
        #expect(!temp.exists("disk/photos/\(name)"))
    }

    @Test func writeHoldsItsMarkUntilTheCopyIsFinished() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.raw", "alpha")
        try temp.file("vault/b.raw", "beta")
        let folder = temp.path("disk/photos/\(name)")
        let claimed = Claims()
        var destination = LocalFolderDestination(root: try temp.directory("disk"), naming: Fixtures.naming)
        destination.afterWritingItem = { _ in claimed.add((try? UnfinishedMark.claim(in: folder)) != nil) }

        try await destination.write(Payload(root: temp.path("vault"), collectedAt: date), manifest: manifest(), sourceSlug: "photos", snapshotName: name, reusingStoredFiles: true)

        #expect(claimed.all == [false, false, false])
        #expect(temp.names(in: "disk/photos/\(name)") == ["_snapshot.json", "a.raw", "b.raw"])
    }

    /// Moving to the Trash would keep the space taken on an external disk (its Trash is on the disk itself).
    @Test func removedAttemptsFreeTheirSpaceOnTheDisk() async throws {
        defer { temp.remove() }
        let disk = try DiskImage(.apfs)
        let destination = LocalFolderDestination(root: disk.root, naming: Fixtures.naming)
        let size = 12_000_000
        try attempt(disk.root.appendingPathComponent("photos/2026-09-27_100000"), mark: nil, bytes: size)
        let before = try freeBytes(disk.root)

        try await destination.removeIncomplete(sourceSlug: "photos", sourceId: sourceId)

        #expect(try DirectoryNames.of(disk.root.appendingPathComponent("photos").path).isEmpty)
        #expect(try await spaceComesBack(on: disk.root, toMoreThan: before + Int64(size) * 9 / 10))
    }

    /// The loop seen on a small disk: each attempt that ran out of space stayed and left even less space for the next one.
    @Test func attemptThatRanOutOfSpaceIsRemovedAndTellsHowMuchIsNeeded() async throws {
        defer { temp.remove() }
        let disk = try DiskImage(.apfs)
        let destination = LocalFolderDestination(root: disk.root, naming: Fixtures.naming)
        let size = Int(try freeBytes(disk.root)) * 6 / 10
        try randomData(size).write(to: try temp.directory("vault").appendingPathComponent("photo.raw"))
        let first = "2026-09-27_100000"
        try await destination.write(Payload(root: temp.path("vault"), collectedAt: date), manifest: manifest(), sourceSlug: "photos", snapshotName: first, reusingStoredFiles: true)
        try randomData(size).write(to: temp.path("vault/photo.raw"))
        let free = try freeBytes(disk.root)

        let error = await #expect(throws: DestinationError.self) {
            try await destination.write(Payload(root: temp.path("vault"), collectedAt: date), manifest: manifest(), sourceSlug: "photos", snapshotName: name, reusingStoredFiles: true)
        }

        guard case let .outOfSpace(needed, freeAfter) = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
        #expect(needed == Int64(size))
        #expect(freeAfter != nil)
        #expect(try await spaceComesBack(on: disk.root, toMoreThan: free * 9 / 10))
        #expect(try DirectoryNames.of(disk.root.appendingPathComponent("photos").path) == [first])
        #expect(error?.localizedDescription.hasPrefix("The destination is out of space: this copy needs about ") == true)
    }

    @Test func leftoverAttemptsNoLongerKeepTheNextCopyOut() async throws {
        defer { temp.remove() }
        let disk = try DiskImage(.apfs)
        let destination = LocalFolderDestination(root: disk.root, naming: Fixtures.naming)
        let size = Int(try freeBytes(disk.root)) * 6 / 10
        try attempt(disk.root.appendingPathComponent("photos/2026-09-27_100000"), mark: SnapshotManifest.unfinishedNote(sourceId: sourceId), bytes: size)
        try randomData(size).write(to: try temp.directory("vault").appendingPathComponent("photo.raw"))

        try await destination.removeIncomplete(sourceSlug: "photos", sourceId: sourceId)
        try await destination.write(Payload(root: temp.path("vault"), collectedAt: date), manifest: manifest(), sourceSlug: "photos", snapshotName: name, reusingStoredFiles: true)

        #expect(try await destination.listSnapshots(sourceSlug: "photos").map(\.name) == [name])
        #expect(try DirectoryNames.of(disk.root.appendingPathComponent("photos").path) == [name])
    }
}

private final class Claims: @unchecked Sendable {
    private let lock = NSLock()
    private var claims: [Bool] = []

    var all: [Bool] {
        lock.withLock { claims }
    }

    func add(_ claimed: Bool) {
        lock.withLock { claims.append(claimed) }
    }
}

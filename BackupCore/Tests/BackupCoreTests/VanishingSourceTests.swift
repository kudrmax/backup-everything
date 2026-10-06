import Darwin
import Foundation
import Testing
@testable import BackupCore

/// A file may vanish from a live source while it is copied; the source itself may not: a copy of a disk that was ejected
/// halfway, or of a folder renamed halfway, would look finished and let old complete copies be pruned.
struct VanishingSourceTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"

    init() throws {
        temp = try TempDirectory()
    }

    private func vault(in root: URL) throws -> Payload {
        for index in 0..<5 {
            let file = root.appendingPathComponent("vault/d\(index)/f\(index).txt")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("file \(index)".utf8).write(to: file)
        }
        return Payload(root: root.appendingPathComponent("vault"), collectedAt: date)
    }

    /// Copies the listing, doing `interrupt` once the first file is in place.
    private func copy(_ payload: Payload, interrupt: @escaping () throws -> Void) throws -> [PayloadEntry] {
        let listing = try PayloadWalker().listing(of: payload)
        let copy = try temp.directory("copy").path
        var placed = 0
        try PayloadCopier().copy(listing, into: copy) { _ in
            placed += 1
            if placed == 1 { try? interrupt() }
        }
        return try WrittenCopy(listing: listing).check(in: copy)
    }

    private func copiedFiles() -> [String] {
        (FileManager.default.enumerator(atPath: temp.path("copy").path)?.compactMap { $0 as? String } ?? []).filter { $0.hasSuffix(".txt") }
    }

    @Test func payloadFolderRenamedHalfwayStopsTheCopy() throws {
        defer { temp.remove() }
        let payload = try vault(in: temp.url)
        #expect(throws: SourceError.sourceDisappeared(temp.path("vault").path)) {
            try copy(payload) { try FileManager.default.moveItem(at: temp.path("vault"), to: temp.path("renamed")) }
        }
        #expect(copiedFiles().count == 1)
    }

    @Test func payloadFolderReplacedHalfwayStopsTheCopy() throws {
        defer { temp.remove() }
        let payload = try vault(in: temp.url)
        #expect(throws: SourceError.sourceDisappeared(temp.path("vault").path)) {
            try copy(payload) {
                try FileManager.default.moveItem(at: temp.path("vault"), to: temp.path("renamed"))
                try temp.directory("vault")
            }
        }
    }

    @Test func sourceDiskEjectedHalfwayStopsTheCopy() throws {
        defer { temp.remove() }
        let disk = try DiskImage(.apfs)
        let payload = try vault(in: disk.root)
        #expect(throws: SourceError.sourceDisappeared(disk.root.appendingPathComponent("vault").path)) {
            try copy(payload) { disk.detach() }
        }
        #expect(copiedFiles().count == 1)
    }

    /// The folder a disk was mounted at stays behind, empty, on the disk of the source: its files did not vanish.
    @Test func diskMountedInsideTheSourceEjectedHalfwayStopsTheCopy() throws {
        defer { temp.remove() }
        try temp.file("vault/top.txt", "top")
        let disk = try DiskImage(.apfs, at: try temp.directory("vault/inner"))
        for index in 0..<3 {
            try Data("inner \(index)".utf8).write(to: disk.root.appendingPathComponent("f\(index).txt"))
        }
        #expect(throws: SourceError.diskDisappeared(temp.path("vault/inner").path)) {
            try copy(Payload(root: temp.path("vault"), collectedAt: date)) { disk.detach() }
        }
    }

    @Test func itemsThatVanishedFromADiskMountedInsideTheSourceAreLeftOut() throws {
        defer { temp.remove() }
        try temp.file("vault/top.txt", "top")
        let disk = try DiskImage(.apfs, at: try temp.directory("vault/inner"))
        for index in 0..<3 {
            try FileManager.default.createDirectory(at: disk.root.appendingPathComponent("d\(index)"), withIntermediateDirectories: true)
            try Data("inner \(index)".utf8).write(to: disk.root.appendingPathComponent("d\(index)/f.txt"))
        }
        let vanished = try copy(Payload(root: temp.path("vault"), collectedAt: date)) {
            try? FileManager.default.removeItem(at: disk.root.appendingPathComponent("d1"))
        }
        #expect(Set(vanished.map(\.relativePath)).isSubset(of: ["inner/d1/f.txt", "inner/d1"]))
        #expect(!temp.exists("copy/inner/d1/f.txt"))
    }

    @Test func fileThatVanishedFromAnIntactSourceIsReported() throws {
        defer { temp.remove() }
        let payload = try vault(in: temp.url)
        var removed: [String] = []
        let vanished = try copy(payload) { [temp] in
            for file in ["d2/f2.txt", "d3/f3.txt"] where !temp.exists("copy/" + file) {
                try FileManager.default.removeItem(at: temp.path("vault/" + file))
                removed.append(file)
            }
        }
        #expect(!removed.isEmpty)
        #expect(Set(vanished.map(\.relativePath)) == Set(removed))
        #expect(copiedFiles().count == 5 - removed.count)
    }

    @Test func listingStopsWhenThePayloadFolderIsGone() throws {
        defer { temp.remove() }
        try temp.file("vault/sub/a.md")
        let origin = try PayloadOrigin(temp.path("vault"))
        try FileManager.default.moveItem(at: temp.path("vault"), to: temp.path("renamed"))
        #expect(throws: SourceError.sourceDisappeared(temp.path("vault").path)) {
            try PayloadWalker().names(in: temp.path("vault/sub"), origin: origin)
        }
        #expect(throws: SourceError.sourceDisappeared(temp.path("vault").path)) {
            try PayloadWalker().entry(at: temp.path("vault/sub/a.md"), relativePath: "sub/a.md", origin: origin)
        }
    }

    @Test func lossOfTheSourceIsToldInPlainWords() {
        #expect(SourceError.sourceDisappeared("/Volumes/Card/DCIM").localizedDescription
            == "The source “/Volumes/Card/DCIM” disappeared during the backup (disk disconnected?). The copy was not finished.")
        #expect(SourceError.diskDisappeared("/Users/max/Photos/Card").localizedDescription
            == "The disk mounted at “/Users/max/Photos/Card” inside the source disappeared during the backup (disk disconnected?). The copy was not finished.")
        #expect(SourceError.vanishedWhileCopied.localizedDescription
            == "Every file of the source disappeared while it was being copied. An empty copy is not created.")
    }

    @Test func listingOfAMissingSourceIsAnError() {
        defer { temp.remove() }
        #expect(throws: SourceError.pathMissing(temp.path("vault").path)) {
            try PayloadOrigin(temp.path("vault"))
        }
    }

    // MARK: The copy in the destination

    /// The destination does `interrupt` once the payload is listed, before anything of it is copied.
    private func destination(_ interrupt: @escaping @Sendable () -> Void) throws -> LocalFolderDestination {
        var destination = LocalFolderDestination(root: try temp.directory("disk"), naming: Fixtures.naming)
        destination.afterWritingItem = { path in
            if path.hasSuffix("/" + SnapshotManifest.unfinishedMarker) { interrupt() }
        }
        return destination
    }

    private func manifest() -> SnapshotManifest {
        SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 5, totalBytes: 30)
    }

    @Test func manifestCountsWhatWasActuallyWritten() async throws {
        defer { temp.remove() }
        let payload = try vault(in: temp.url)
        let gone = temp.path("vault/d1/f1.txt")
        let destination = try destination { try? FileManager.default.removeItem(at: gone) }

        let written = try await destination.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)

        #expect(written == PayloadStats(fileCount: 4, totalBytes: 24))
        let stored = try JSONCoding.decoder().decode(
            SnapshotManifest.self,
            from: Data(contentsOf: temp.path("disk/obsidian/\(name)/\(SnapshotManifest.fileName)"))
        )
        #expect(stored.fileCount == 4)
        #expect(stored.totalBytes == 24)
        #expect(stored.files?.map(\.path) == ["d0/f0.txt", "d2/f2.txt", "d3/f3.txt", "d4/f4.txt"])
    }

    @Test func copyOfASourceWhoseFilesAllVanishedIsNotFinished() async throws {
        defer { temp.remove() }
        let payload = try vault(in: temp.url)
        let destination = try destination { [temp] in
            for index in 0..<5 { try? FileManager.default.removeItem(at: temp.path("vault/d\(index)")) }
        }

        await #expect(throws: SourceError.vanishedWhileCopied) {
            try await destination.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }

        #expect(temp.exists("disk/obsidian/\(name)/\(SnapshotManifest.unfinishedMarker)"))
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
    }

    @Test func copyOfASourceEjectedHalfwayStaysUnfinished() async throws {
        defer { temp.remove() }
        let disk = try DiskImage(.apfs)
        let payload = try vault(in: disk.root)
        let destination = try destination { disk.detach() }

        await #expect(throws: (any Error).self) {
            try await destination.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }

        #expect(temp.exists("disk/obsidian/\(name)/\(SnapshotManifest.unfinishedMarker)"))
        #expect(!temp.exists("disk/obsidian/\(name)/\(SnapshotManifest.fileName)"))
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
    }
}

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
    private func copy(_ payload: Payload, interrupt: () throws -> Void) throws -> [PayloadEntry] {
        let listing = try PayloadWalker().listing(of: payload)
        var placed = 0
        return try PayloadCopier().copy(listing, into: try temp.directory("copy").path) { entry, target in
            if placed == 1 { try interrupt() }
            try ExactNameFiles().copy(entry.url.path, to: target)
            placed += 1
        }
    }

    private func copiedFiles() -> [String] {
        (FileManager.default.enumerator(atPath: temp.path("copy").path)?.compactMap { $0 as? String } ?? []).filter { $0.hasSuffix(".txt") }
    }

    @Test func payloadFolderRenamedHalfwayStopsTheCopy() throws {
        defer { temp.remove() }
        let payload = try vault(in: temp.url)
        #expect(throws: POSIXError(.ENOENT)) {
            try copy(payload) { try FileManager.default.moveItem(at: temp.path("vault"), to: temp.path("renamed")) }
        }
        #expect(copiedFiles().count == 1)
    }

    @Test func payloadFolderReplacedHalfwayStopsTheCopy() throws {
        defer { temp.remove() }
        let payload = try vault(in: temp.url)
        #expect(throws: POSIXError(.ENOENT)) {
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
        #expect(throws: (any Error).self) {
            try copy(payload) { disk.detach() }
        }
        #expect(copiedFiles().count == 1)
    }

    @Test func fileThatVanishedFromAnIntactSourceIsReported() throws {
        defer { temp.remove() }
        let payload = try vault(in: temp.url)
        let vanished = try copy(payload) {
            try FileManager.default.removeItem(at: temp.path("vault/d2/f2.txt"))
            try FileManager.default.removeItem(at: temp.path("vault/d3"))
        }
        #expect(vanished.map(\.relativePath) == ["d2/f2.txt", "d3/f3.txt", "d3"])
        #expect(copiedFiles().count == 3)
    }

    @Test func listingStopsWhenThePayloadFolderIsGone() throws {
        defer { temp.remove() }
        try temp.file("vault/sub/a.md")
        let origin = try PayloadOrigin(temp.path("vault"))
        try FileManager.default.moveItem(at: temp.path("vault"), to: temp.path("renamed"))
        #expect(throws: SourceError.unreadable(temp.path("vault/sub").path)) {
            try PayloadWalker().names(in: temp.path("vault/sub"), origin: origin)
        }
        #expect(throws: SourceError.unreadable(temp.path("vault/sub/a.md").path)) {
            try PayloadWalker().entry(at: temp.path("vault/sub/a.md"), relativePath: "sub/a.md", origin: origin)
        }
    }

    @Test func listingOfAMissingSourceIsAnError() {
        defer { temp.remove() }
        #expect(throws: SourceError.pathMissing(temp.path("vault").path)) {
            try PayloadOrigin(temp.path("vault"))
        }
    }

    // MARK: The copy in the destination

    private func destination(_ interrupt: @escaping @Sendable () -> Void) throws -> LocalFolderDestination {
        LocalFolderDestination(root: try temp.directory("disk"), naming: Fixtures.naming, cloning: InterruptingCloning(interrupt))
    }

    private func manifest() -> SnapshotManifest {
        SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 5, totalBytes: 30)
    }

    @Test func manifestCountsWhatWasActuallyWritten() async throws {
        defer { temp.remove() }
        let payload = try vault(in: temp.url)
        let gone = temp.path("vault/d1/f1.txt")
        let destination = try destination { try? FileManager.default.removeItem(at: gone) }

        try await destination.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)

        let stored = try JSONCoding.decoder().decode(
            SnapshotManifest.self,
            from: Data(contentsOf: temp.path("disk/obsidian/\(name)/\(SnapshotManifest.fileName)"))
        )
        #expect(stored.fileCount == 4)
        #expect(stored.totalBytes == 24)
        #expect(stored.files?.map(\.path) == ["d0/f0.txt", "d2/f2.txt", "d3/f3.txt", "d4/f4.txt"])
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

/// Real clones, with `interrupt` done when the destination asks whether it can clone: after the payload was listed,
/// before anything is copied.
private final class InterruptingCloning: FileCloning, @unchecked Sendable {
    private let interrupt: @Sendable () -> Void

    init(_ interrupt: @escaping @Sendable () -> Void) {
        self.interrupt = interrupt
    }

    func isSupported(at folder: URL) -> Bool {
        interrupt()
        return APFSCloning().isSupported(at: folder)
    }

    func clone(_ original: URL, to targetPath: String) throws {
        try APFSCloning().clone(original, to: targetPath)
    }
}

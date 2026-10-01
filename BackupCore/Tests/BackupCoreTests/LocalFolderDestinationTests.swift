import Foundation
import Testing
@testable import BackupCore

struct LocalFolderDestinationTests {
    private let temp: TempDirectory
    private let destination: LocalFolderDestination
    private let date = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"

    init() throws {
        temp = try TempDirectory()
        try temp.directory("disk")
        destination = LocalFolderDestination(root: temp.path("disk"), naming: Fixtures.naming)
    }

    private func manifest() -> SnapshotManifest {
        SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 2, totalBytes: 10)
    }

    private func vaultPayload() throws -> Payload {
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/sub/b.md", "beta")
        try temp.directory("vault/empty")
        return Payload(root: temp.path("vault"), collectedAt: date)
    }

    @Test func writesFilesAsIsWithManifestLast() async throws {
        defer { temp.remove() }
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)

        #expect(try String(contentsOf: temp.path("disk/obsidian/\(name)/sub/b.md"), encoding: .utf8) == "beta")
        #expect(temp.exists("disk/obsidian/\(name)/empty"))
        let stored = try JSONCoding.decoder().decode(
            SnapshotManifest.self,
            from: Data(contentsOf: temp.path("disk/obsidian/\(name)/_snapshot.json"))
        )
        #expect(stored.fileCount == 2)
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian") == [Snapshot(name: name, date: date)])
    }

    @Test func writesSingleFilePayload() async throws {
        defer { temp.remove() }
        let file = try temp.file("export.csv", "1;2")
        try await destination.write(Payload(root: file, collectedAt: date), manifest: manifest(), sourceSlug: "finance", snapshotName: name, reusingStoredFiles: true)
        #expect(temp.names(in: "disk/finance/\(name)") == ["_snapshot.json", "export.csv"])
    }

    @Test func snapshotWithoutManifestIsIncomplete() async throws {
        defer { temp.remove() }
        try temp.file("disk/obsidian/2026-09-27_100000/a.md")
        try temp.file("disk/obsidian/Мои заметки/keep.md")
        try temp.file("disk/obsidian/notes.txt")

        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(temp.names(in: "disk/obsidian") == ["notes.txt", "Мои заметки"])
    }

    @Test func missingRootIsUnavailableAndNeverCreated() async throws {
        defer { temp.remove() }
        let unplugged = LocalFolderDestination(root: temp.path("Volumes/HDD/Backups"), naming: Fixtures.naming)
        #expect(await unplugged.isAvailable() == false)
        let payload = try vaultPayload()
        await #expect(throws: DestinationError.unavailable) {
            try await unplugged.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(!temp.exists("Volumes"))
        #expect(try await unplugged.listSnapshots(sourceSlug: "obsidian").isEmpty)
    }

    @Test func deletesOnlySnapshotDirectories() async throws {
        defer { temp.remove() }
        try await destination.write(try vaultPayload(), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        try temp.file("disk/obsidian/Photos/keep.jpg")

        try await destination.delete(Snapshot(name: "Photos", date: date), sourceSlug: "obsidian")
        #expect(temp.exists("disk/obsidian/Photos/keep.jpg"))

        try await destination.delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")
        #expect(temp.names(in: "disk/obsidian") == ["Photos"])
    }

    @Test func failedWriteLeavesNoManifest() async throws {
        defer { temp.remove() }
        let payload = Payload(root: temp.path("missing-source"), collectedAt: date)
        await #expect(throws: SourceError.pathMissing(temp.path("missing-source").path)) {
            try await destination.write(payload, manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(temp.names(in: "disk/obsidian").isEmpty)
    }

    @Test func usedBytesSumsEverythingUnderRoot() async throws {
        defer { temp.remove() }
        try temp.file("disk/obsidian/\(name)/a.md", "alpha")
        try temp.file("disk/obsidian/\(name)/sub/b.md", "abc")
        #expect(try await destination.usedBytes() == 8)
    }
}

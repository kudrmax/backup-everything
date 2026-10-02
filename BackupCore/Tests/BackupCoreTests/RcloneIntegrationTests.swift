import Foundation
import Testing
@testable import BackupCore

struct RcloneIntegrationTests {
    @Test func roundTripsThroughRealRcloneLocalBackend() async throws {
        let executable = try #require(RcloneLocator().find(), "rclone is required: brew install rclone")
        let temp = try TempDirectory()
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        try temp.file("vault/sub/b.md", "beta")
        try temp.file("vault/.trash/old.md", "old")
        try temp.directory("remote")
        let destination = RcloneDestination(
            executable: executable,
            remote: ":local",
            path: temp.path("remote").path,
            runner: SystemProcessRunner(),
            naming: Fixtures.naming
        )
        let date = Fixtures.date("2026-09-28 14:30:00")
        let name = "2026-09-28_143000"
        let payload = Payload(root: temp.path("vault"), excludes: [".trash"], collectedAt: date)
        let manifest = SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 2, totalBytes: 9)

        #expect(await destination.isAvailable())
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)

        try temp.file("remote/obsidian/2026-09-26_100000/partial.md")
        try temp.file("remote/obsidian/2026-09-26_100000/_unfinished")
        try temp.file("remote/obsidian/2026-09-27_100000/mine.md")
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(!temp.exists("remote/obsidian/2026-09-26_100000"))
        #expect(temp.exists("remote/obsidian/2026-09-27_100000/mine.md"))

        try await destination.write(payload, manifest: manifest, sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        #expect(try String(contentsOf: temp.path("remote/obsidian/\(name)/sub/b.md"), encoding: .utf8) == "beta")
        #expect(!temp.exists("remote/obsidian/\(name)/_unfinished"))
        #expect(!temp.exists("remote/obsidian/\(name)/.trash"))
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian") == [Snapshot(name: name, date: date)])
        #expect(try await destination.usedBytes() > 9)

        try await destination.delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
    }

    @Test func singleFileGivenAsALinkIsStoredWithItsData() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let destination = try cloud(in: temp)
        try temp.file("dotfiles/zshrc", "export A=1")
        try FileManager.default.createSymbolicLink(at: temp.path(".zshrc"), withDestinationURL: temp.path("dotfiles/zshrc"))
        let date = Fixtures.date("2026-09-28 14:30:00")
        let manifest = SnapshotManifest(sourceId: UUID(), sourceName: "Shell", collectedAt: date, fileCount: 1, totalBytes: 10)

        try await destination.write(Payload(root: temp.path(".zshrc"), collectedAt: date), manifest: manifest, sourceSlug: "shell", snapshotName: "2026-09-28_143000", reusingStoredFiles: true)

        #expect(try String(contentsOf: temp.path("remote/shell/2026-09-28_143000/.zshrc"), encoding: .utf8) == "export A=1")
    }

    @Test func folderGivenAsALinkIsStoredWithItsContents() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let destination = try cloud(in: temp)
        try temp.file("real/vault/a.md", "alpha")
        try FileManager.default.createSymbolicLink(at: temp.path("vault"), withDestinationURL: temp.path("real/vault"))

        try await writeVault(to: destination, in: temp)

        #expect(try String(contentsOf: temp.path("remote/obsidian/2026-09-28_143000/a.md"), encoding: .utf8) == "alpha")
    }

    private func cloud(in temp: TempDirectory) throws -> RcloneDestination {
        let executable = try #require(RcloneLocator().find(), "rclone is required: brew install rclone")
        try temp.directory("remote")
        return RcloneDestination(executable: executable, remote: ":local", path: temp.path("remote").path, runner: SystemProcessRunner(), naming: Fixtures.naming)
    }

    private func writeVault(to destination: RcloneDestination, in temp: TempDirectory) async throws {
        let date = Fixtures.date("2026-09-28 14:30:00")
        let manifest = SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 1, totalBytes: 5)
        try await destination.write(Payload(root: temp.path("vault"), collectedAt: date), manifest: manifest, sourceSlug: "obsidian", snapshotName: "2026-09-28_143000", reusingStoredFiles: true)
    }

    /// Spec 4.3: a folder without the mark under the new copy's name stops the write and is never touched.
    @Test func writeDoesNotTakeOverAForeignFolderWithTheSameName() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let destination = try cloud(in: temp)
        try temp.file("vault/a.md", "alpha")
        try temp.file("remote/obsidian/2026-09-28_143000/mine.md", "not a backup")

        await #expect(throws: DestinationError.self) {
            try await writeVault(to: destination, in: temp)
        }
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        #expect(temp.names(in: "remote/obsidian/2026-09-28_143000") == ["mine.md"])
    }

    /// Spec 4.3: an unfinished folder under the same name (a retry of the same copy) is replaced, the copy is written anew.
    @Test func retryReplacesTheUnfinishedAttemptUnderTheSameName() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let destination = try cloud(in: temp)
        try temp.file("vault/a.md", "alpha")
        try temp.file("remote/obsidian/2026-09-28_143000/_unfinished")
        try temp.file("remote/obsidian/2026-09-28_143000/deleted-since.md", "stale")

        try await writeVault(to: destination, in: temp)

        #expect(temp.names(in: "remote/obsidian/2026-09-28_143000") == ["_snapshot.json", "a.md"])
    }
}

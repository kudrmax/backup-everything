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

        try temp.file("remote/obsidian/2026-09-27_100000/partial.md")
        try await destination.removeIncomplete(sourceSlug: "obsidian")
        #expect(!temp.exists("remote/obsidian/2026-09-27_100000"))

        try await destination.write(payload, manifest: manifest, sourceSlug: "obsidian", snapshotName: name)
        #expect(try String(contentsOf: temp.path("remote/obsidian/\(name)/sub/b.md"), encoding: .utf8) == "beta")
        #expect(!temp.exists("remote/obsidian/\(name)/.trash"))
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian") == [Snapshot(name: name, date: date)])
        #expect(try await destination.usedBytes() > 9)

        try await destination.delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
    }
}

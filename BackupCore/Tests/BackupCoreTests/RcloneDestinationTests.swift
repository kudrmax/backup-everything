import Foundation
import Testing
@testable import BackupCore

struct RcloneDestinationTests {
    private let executable = URL(fileURLWithPath: "/opt/homebrew/bin/rclone")
    private let date = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"

    private func destination(_ runner: FakeProcessRunner, path: String = "backups/") -> RcloneDestination {
        RcloneDestination(executable: executable, remote: "gdrive:", path: path, runner: runner, naming: Fixtures.naming)
    }

    @Test func listsOnlySnapshotsThatHaveManifest() async throws {
        let runner = FakeProcessRunner { _ in
            ProcessResult(exitCode: 0, stdout: "2026-09-27_100000/_snapshot.json\n\(name)/_snapshot.json\nPhotos/_snapshot.json\n")
        }
        let snapshots = try await destination(runner).listSnapshots(sourceSlug: "obsidian")
        #expect(snapshots.map(\.name) == ["2026-09-27_100000", name])
        #expect(runner.calls.map(\.arguments) == [[
            "lsf", "gdrive:backups/obsidian", "--files-only", "--recursive", "--max-depth", "2", "--include", "/*/_snapshot.json",
        ]])
    }

    @Test func materializeDownloadsTheSnapshotIntoScratch() async throws {
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 0) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = try await destination(runner).materialize(Snapshot(name: name, date: date), sourceSlug: "obsidian", scratch: scratch)
        #expect(folder == scratch.appendingPathComponent(name, isDirectory: true))
        #expect(runner.calls.map(\.arguments) == [["copy", "gdrive:backups/obsidian/\(name)", folder.path]])
    }

    @Test func missingSourceDirectoryMeansNoSnapshots() async throws {
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 3, stderr: "directory not found") }
        #expect(try await destination(runner).listSnapshots(sourceSlug: "obsidian").isEmpty)
        try await destination(runner).removeIncomplete(sourceSlug: "obsidian")
        #expect(!runner.calls.contains { $0.arguments.first == "purge" })
    }

    @Test func purgesOnlyUnfinishedSnapshotDirectories() async throws {
        let runner = FakeProcessRunner { call in
            if call.arguments.contains("--dirs-only") {
                return ProcessResult(exitCode: 0, stdout: "2026-09-25_100000/\n2026-09-26_100000/\n2026-09-27_100000/\nPhotos/\n")
            }
            if call.arguments.contains("/*/_snapshot.json") {
                return ProcessResult(exitCode: 0, stdout: "2026-09-27_100000/_snapshot.json\n")
            }
            if call.arguments.contains("/*/_unfinished") {
                return ProcessResult(exitCode: 0, stdout: "2026-09-26_100000/_unfinished\n")
            }
            return ProcessResult(exitCode: 0)
        }
        try await destination(runner).removeIncomplete(sourceSlug: "obsidian")
        #expect(runner.calls.filter { $0.arguments.first == "purge" }.map(\.arguments) == [
            ["purge", "gdrive:backups/obsidian/2026-09-26_100000"],
        ])
    }

    @Test func copiesListedFilesThenManifest() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        try temp.file("vault/a.md")
        try temp.file("vault/sub/b.md")
        try temp.file("vault/.trash/old.md")
        let listedFiles = LockedBox<String>("")
        let runner = FakeProcessRunner { call in
            if let index = call.arguments.firstIndex(of: "--files-from-raw") {
                listedFiles.set((try? String(contentsOfFile: call.arguments[index + 1], encoding: .utf8)) ?? "")
            }
            return ProcessResult(exitCode: 0)
        }
        let payload = Payload(root: temp.path("vault"), excludes: [".trash"], collectedAt: date)
        let manifest = SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 2, totalBytes: 14)

        try await destination(runner).write(payload, manifest: manifest, sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)

        #expect(listedFiles.get() == "a.md\nsub/b.md")
        #expect(runner.calls.count == 4)
        #expect(runner.calls[0].arguments.first == "copyto")
        #expect(runner.calls[0].arguments.last == "gdrive:backups/obsidian/\(name)/_unfinished")
        #expect(Array(runner.calls[1].arguments.prefix(4)) == ["copy", temp.path("vault").path, "gdrive:backups/obsidian/\(name)", "--files-from-raw"])
        #expect(runner.calls[2].arguments.first == "copyto")
        #expect(runner.calls[2].arguments.last == "gdrive:backups/obsidian/\(name)/_snapshot.json")
        #expect(runner.calls[3].arguments == ["deletefile", "gdrive:backups/obsidian/\(name)/_unfinished"])
    }

    @Test func manifestIsNotUploadedWhenCopyFails() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let file = try temp.file("export.csv")
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 1, stderr: "quota exceeded") }
        let manifest = SnapshotManifest(sourceId: UUID(), sourceName: "Finance", collectedAt: date, fileCount: 1, totalBytes: 7)
        await #expect(throws: DestinationError.commandFailed("quota exceeded")) {
            try await destination(runner).write(Payload(root: file, collectedAt: date), manifest: manifest, sourceSlug: "finance", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].arguments.last == "gdrive:backups/finance/\(name)/_unfinished")
    }

    @Test func deleteRefusesForeignNames() async throws {
        let runner = FakeProcessRunner()
        try await destination(runner).delete(Snapshot(name: "Photos", date: date), sourceSlug: "obsidian")
        try await destination(runner, path: "").delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")
        #expect(runner.calls.map(\.arguments) == [["purge", "gdrive:obsidian/\(name)"]])
    }

    @Test func availabilityFollowsRcloneExitCode() async {
        #expect(await destination(FakeProcessRunner()).isAvailable())
        #expect(await destination(FakeProcessRunner { _ in ProcessResult(exitCode: 1) }).isAvailable() == false)
        #expect(await destination(FakeProcessRunner { _ in ProcessResult(exitCode: 0, timedOut: true) }).isAvailable() == false)
    }

    @Test func missingRcloneIsUnavailableAndExplained() async {
        let runner = FakeProcessRunner()
        let orphan = RcloneDestination(executable: nil, remote: "gdrive", path: "backups", runner: runner, naming: Fixtures.naming)
        #expect(await orphan.isAvailable() == false)
        await #expect(throws: DestinationError.rcloneMissing) {
            try await orphan.listSnapshots(sourceSlug: "obsidian")
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func usedBytesComesFromRcloneSize() async throws {
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 0, stdout: #"{"count":3,"bytes":1234,"sizeless":0}"#) }
        #expect(try await destination(runner).usedBytes() == 1234)
        #expect(runner.calls.map(\.arguments) == [["size", "gdrive:backups", "--json"]])
    }

    @Test func usedBytesOfMissingFolderIsZero() async throws {
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 3, stderr: "directory not found") }
        #expect(try await destination(runner).usedBytes() == 0)
    }
}

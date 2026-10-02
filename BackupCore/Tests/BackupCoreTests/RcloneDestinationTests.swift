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
        #expect(runner.calls.count == 5)
        #expect(runner.calls[0].arguments == ["lsf", "gdrive:backups/obsidian/\(name)"])
        #expect(runner.calls[1].arguments.first == "copyto")
        #expect(runner.calls[1].arguments.last == "gdrive:backups/obsidian/\(name)/_unfinished")
        #expect(Array(runner.calls[2].arguments.prefix(4)) == ["copy", temp.path("vault").path, "gdrive:backups/obsidian/\(name)", "--files-from-raw"])
        #expect(runner.calls[3].arguments.first == "copyto")
        #expect(runner.calls[3].arguments.last == "gdrive:backups/obsidian/\(name)/_snapshot.json")
        #expect(runner.calls[4].arguments == ["deletefile", "gdrive:backups/obsidian/\(name)/_unfinished"])
    }

    @Test func manifestIsNotUploadedWhenCopyFails() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let file = try temp.file("export.csv")
        let runner = FakeProcessRunner { call in
            call.arguments.contains(file.path) ? ProcessResult(exitCode: 1, stderr: "quota exceeded") : ProcessResult(exitCode: 0)
        }
        let manifest = SnapshotManifest(sourceId: UUID(), sourceName: "Finance", collectedAt: date, fileCount: 1, totalBytes: 7)
        await #expect(throws: DestinationError.commandFailed("quota exceeded")) {
            try await destination(runner).write(Payload(root: file, collectedAt: date), manifest: manifest, sourceSlug: "finance", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(runner.calls.map { $0.arguments.first } == ["lsf", "copyto", "copyto"])
        #expect(runner.calls[1].arguments.last == "gdrive:backups/finance/\(name)/_unfinished")
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

    private func manifest(_ source: String = "Obsidian") -> SnapshotManifest {
        SnapshotManifest(sourceId: UUID(), sourceName: source, collectedAt: date, fileCount: 1, totalBytes: 5)
    }

    @Test func purgesOnlyMarkedFoldersWithoutManifestWhateverTheListingLooksLike() async throws {
        let runner = FakeProcessRunner { call in
            if call.arguments.contains("--dirs-only") {
                return ProcessResult(exitCode: 0, stdout: "2026-09-24_100000\n2026-09-25_100000/\n\n2026-09-26_100000\nnotes\n")
            }
            if call.arguments.contains("/*/_snapshot.json") {
                return ProcessResult(exitCode: 0, stdout: "2026-09-25_100000/_snapshot.json\n")
            }
            if call.arguments.contains("/*/_unfinished") {
                return ProcessResult(exitCode: 0, stdout: "2026-09-24_100000/_unfinished\n2026-09-25_100000/_unfinished\nnotes/_unfinished\n")
            }
            return ProcessResult(exitCode: 0)
        }
        try await destination(runner).removeIncomplete(sourceSlug: "obsidian")
        #expect(runner.calls.filter { $0.arguments.first == "purge" }.map(\.arguments) == [
            ["purge", "gdrive:backups/obsidian/2026-09-24_100000"],
        ])
    }

    @Test func listingFailureStopsTheCleanupBeforeAnythingIsPurged() async throws {
        for failing in ["--dirs-only", "/*/_snapshot.json", "/*/_unfinished"] {
            let runner = FakeProcessRunner { call in
                if call.arguments.contains(failing) { return ProcessResult(exitCode: 1, stderr: "rate limited") }
                if call.arguments.contains("--dirs-only") { return ProcessResult(exitCode: 0, stdout: "2026-09-24_100000/\n") }
                if call.arguments.contains("/*/_unfinished") { return ProcessResult(exitCode: 0, stdout: "2026-09-24_100000/_unfinished\n") }
                return ProcessResult(exitCode: 0)
            }
            await #expect(throws: DestinationError.commandFailed("rate limited")) {
                try await destination(runner).removeIncomplete(sourceSlug: "obsidian")
            }
            #expect(!runner.calls.contains { $0.arguments.first == "purge" })
        }
    }

    @Test func failedPurgeIsReported() async throws {
        let runner = FakeProcessRunner { call in
            if call.arguments.contains("--dirs-only") { return ProcessResult(exitCode: 0, stdout: "2026-09-24_100000/\n") }
            if call.arguments.contains("/*/_unfinished") { return ProcessResult(exitCode: 0, stdout: "2026-09-24_100000/_unfinished\n") }
            if call.arguments.first == "purge" { return ProcessResult(exitCode: 1, stderr: "permission denied") }
            return ProcessResult(exitCode: 0)
        }
        await #expect(throws: DestinationError.commandFailed("permission denied")) {
            try await destination(runner).removeIncomplete(sourceSlug: "obsidian")
        }
    }

    @Test func listingErrorIsNotTakenForAnEmptyFolder() async throws {
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 1, stderr: "token expired") }
        await #expect(throws: DestinationError.commandFailed("token expired")) {
            try await destination(runner).listSnapshots(sourceSlug: "obsidian")
        }
        await #expect(throws: DestinationError.commandFailed("token expired")) {
            try await destination(runner).usedBytes()
        }
    }

    @Test func failedManifestUploadLeavesTheCopyMarkedUnfinished() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let file = try temp.file("export.csv", "1;2;3")
        let runner = FakeProcessRunner { call in
            call.arguments.last?.hasSuffix("/_snapshot.json") == true ? ProcessResult(exitCode: 1, stderr: "connection reset") : ProcessResult(exitCode: 0)
        }
        await #expect(throws: DestinationError.commandFailed("connection reset")) {
            try await destination(runner).write(Payload(root: file, collectedAt: date), manifest: manifest(), sourceSlug: "finance", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(runner.calls.map { $0.arguments.first } == ["lsf", "copyto", "copyto", "copyto"])
        #expect(!runner.calls.contains { $0.arguments.first == "deletefile" })
    }

    @Test func failedMarkRemovalIsReportedAfterTheManifestIsUp() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let file = try temp.file("export.csv", "1;2;3")
        let uploadedManifest = LockedBox<SnapshotManifest?>(nil)
        let runner = FakeProcessRunner { call in
            if call.arguments.last?.hasSuffix("/_snapshot.json") == true {
                let data = try Data(contentsOf: URL(fileURLWithPath: call.arguments[1]))
                uploadedManifest.set(try JSONCoding.decoder().decode(SnapshotManifest.self, from: data))
            }
            return call.arguments.first == "deletefile" ? ProcessResult(exitCode: 1, stderr: "busy") : ProcessResult(exitCode: 0)
        }
        let expected = manifest("Finance")
        await #expect(throws: DestinationError.commandFailed("busy")) {
            try await destination(runner).write(Payload(root: file, collectedAt: date), manifest: expected, sourceSlug: "finance", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(uploadedManifest.get() == expected)
        #expect(runner.calls[2].arguments == ["copyto", file.path, "gdrive:backups/finance/\(name)/export.csv"])
    }

    @Test func onlyRegularFilesAreSentToTheCloud() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        try temp.file("vault/Мои заметки/план на год.md", "plan")
        try temp.file("vault/with space.md", "space")
        try temp.directory("vault/empty")
        try FileManager.default.createSymbolicLink(atPath: temp.path("vault/link.md").path, withDestinationPath: "with space.md")
        let listedFiles = LockedBox<String>("")
        let runner = FakeProcessRunner { call in
            if let index = call.arguments.firstIndex(of: "--files-from-raw") {
                listedFiles.set((try? String(contentsOfFile: call.arguments[index + 1], encoding: .utf8)) ?? "")
            }
            return ProcessResult(exitCode: 0)
        }
        try await destination(runner).write(Payload(root: temp.path("vault"), collectedAt: date), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        #expect(listedFiles.get() == "with space.md\nМои заметки/план на год.md")
    }

    @Test func cloudCopiesNeverShareData() async {
        #expect(await destination(FakeProcessRunner()).canShareUnchangedFiles() == false)
    }

    @Test func unreadableSizeIsAnError() async {
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 0, stdout: "Total size: 1.2 KiB") }
        await #expect(throws: DestinationError.commandFailed("Could not parse the output of rclone size.")) {
            try await destination(runner).usedBytes()
        }
    }

    @Test func errorKeepsOnlyTheTailOfLongOutput() async {
        let noise = String(repeating: "x", count: 5000) + "the real reason"
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 1, stderr: noise) }
        await #expect(throws: DestinationError.commandFailed(String(noise.suffix(2000)))) {
            try await destination(runner).delete(Snapshot(name: name, date: date), sourceSlug: "obsidian")
        }
    }

    @Test func runnerFailureMeansUnavailable() async {
        let runner = FakeProcessRunner { _ in throw POSIXError(.ENOENT) }
        #expect(await destination(runner).isAvailable() == false)
    }

    @Test func remoteAndPathAreJoinedWithoutDoubleSlashes() async throws {
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 0, stdout: #"{"bytes":1}"#) }
        _ = try await RcloneDestination(executable: executable, remote: "gdrive", path: "a/b///", runner: runner, naming: Fixtures.naming).usedBytes()
        _ = try await RcloneDestination(executable: executable, remote: "gdrive:", path: "", runner: runner, naming: Fixtures.naming).usedBytes()
        #expect(runner.calls.map { $0.arguments[1] } == ["gdrive:a/b", "gdrive:"])
        #expect(runner.calls.allSatisfy { $0.executable == executable && $0.timeout == nil })
    }

    @Test func availabilityChecksTheRemoteRootWithATimeout() async {
        let runner = FakeProcessRunner()
        _ = await destination(runner, path: "not/created/yet").isAvailable()
        #expect(runner.calls.map(\.arguments) == [["lsf", "gdrive:", "--max-depth", "1", "--contimeout", "10s", "--retries", "1"]])
        #expect(runner.calls.first?.timeout == 15)
    }

    // MARK: Folder under the name of the new copy (spec 4.3)

    private func writeExport(_ runner: FakeProcessRunner) async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let file = try temp.file("export.csv", "1;2")
        try await destination(runner).write(Payload(root: file, collectedAt: date), manifest: manifest("Finance"), sourceSlug: "finance", snapshotName: name, reusingStoredFiles: false)
    }

    private func listing(_ entries: String, exitCode: Int32 = 0) -> FakeProcessRunner {
        FakeProcessRunner { call in
            call.arguments == ["lsf", "gdrive:backups/finance/\(name)"] ? ProcessResult(exitCode: exitCode, stdout: entries, stderr: "listing failed") : ProcessResult(exitCode: 0)
        }
    }

    @Test(arguments: ["2026-09-28_143000/\nold-export.csv\n", "_snapshot.json\n_unfinished\n", "_snapshot.json\nexport.csv\n"])
    func folderThatIsNotAnUnfinishedAttemptStopsTheWrite(entries: String) async throws {
        let runner = listing(entries)
        await #expect(throws: DestinationError.folderInTheWay("gdrive:backups/finance/\(name)")) {
            try await writeExport(runner)
        }
        #expect(runner.calls.map { $0.arguments.first } == ["lsf"])
    }

    @Test func unfinishedAttemptUnderTheSameNameIsPurgedBeforeWriting() async throws {
        let runner = listing("_unfinished\nstale.csv\n")
        try await writeExport(runner)
        #expect(runner.calls.map { $0.arguments.first } == ["lsf", "purge", "copyto", "copyto", "copyto", "deletefile"])
        #expect(runner.calls[1].arguments == ["purge", "gdrive:backups/finance/\(name)"])
    }

    @Test func missingOrEmptyFolderIsWrittenStraightAway() async throws {
        for runner in [listing("", exitCode: 3), listing("\n")] {
            try await writeExport(runner)
            #expect(runner.calls.map { $0.arguments.first } == ["lsf", "copyto", "copyto", "copyto", "deletefile"])
        }
    }

    @Test func unreadableFolderStopsTheWrite() async throws {
        let runner = listing("", exitCode: 1)
        await #expect(throws: DestinationError.commandFailed("listing failed")) {
            try await writeExport(runner)
        }
        #expect(runner.calls.count == 1)
    }

    @Test func failedPurgeOfTheUnfinishedAttemptStopsTheWrite() async throws {
        let runner = FakeProcessRunner { call in
            if call.arguments.first == "lsf" { return ProcessResult(exitCode: 0, stdout: "_unfinished\n") }
            return call.arguments.first == "purge" ? ProcessResult(exitCode: 1, stderr: "busy") : ProcessResult(exitCode: 0)
        }
        await #expect(throws: DestinationError.commandFailed("busy")) {
            try await writeExport(runner)
        }
        #expect(runner.calls.map { $0.arguments.first } == ["lsf", "purge"])
    }

    /// A hand-edited `config.json` can leave a source without a usable folder name: the destination root is never touched then.
    @Test(arguments: ["", "/", "a/b", ".", "..", "../photos"])
    func folderNameThatIsNotOneFolderIsRefused(slug: String) async throws {
        let runner = FakeProcessRunner { _ in ProcessResult(exitCode: 0) }
        let destination = destination(runner)
        let snapshot = Snapshot(name: name, date: date)
        let refused = DestinationError.invalidFolderName(slug)
        await #expect(throws: refused) { try await destination.listSnapshots(sourceSlug: slug) }
        await #expect(throws: refused) { try await destination.owners(sourceSlug: slug) }
        await #expect(throws: refused) { try await destination.removeIncomplete(sourceSlug: slug) }
        await #expect(throws: refused) { try await destination.delete(snapshot, sourceSlug: slug) }
        await #expect(throws: refused) {
            try await destination.materialize(snapshot, sourceSlug: slug, scratch: FileManager.default.temporaryDirectory)
        }
        await #expect(throws: refused) {
            try await destination.write(
                Payload(root: FileManager.default.temporaryDirectory, collectedAt: date),
                manifest: SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 1, totalBytes: 1),
                sourceSlug: slug,
                snapshotName: name,
                reusingStoredFiles: false
            )
        }
        #expect(runner.calls.isEmpty)
    }
}

import Darwin
import Foundation
import Testing
@testable import BackupCore

struct CoreSupportTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")

    init() throws {
        temp = try TempDirectory()
    }

    @Test func destinationErrorsExplainThemselves() {
        defer { temp.remove() }
        #expect(DestinationError.unavailable.localizedDescription == "The destination is unavailable.")
        #expect(DestinationError.outOfSpace.localizedDescription == "The destination is out of space.")
        #expect(DestinationError.rcloneMissing.localizedDescription == "rclone is not installed. Install it with “brew install rclone”.")
        #expect(DestinationError.commandFailed("quota exceeded").localizedDescription == "rclone failed: quota exceeded")
        #expect(DestinationError.folderInTheWay("/Volumes/HDD/obsidian/2026-09-28_143000").localizedDescription
            == "A folder that is not a finished copy is in the way: /Volumes/HDD/obsidian/2026-09-28_143000. It was left as is; move it away and retry.")
    }

    @Test func sourceErrorsExplainThemselves() {
        defer { temp.remove() }
        #expect(SourceError.commandTimedOut(seconds: 60, output: "still downloading").localizedDescription
            == "Command did not finish within 60 s and was stopped. still downloading")
        #expect(SourceError.nothingToCollect.localizedDescription == "No picked-up files for this source.")
        #expect(SourceError.pickupFailed("disk full").localizedDescription == "Could not pick up the files: disk full")
    }

    @Test func systemClockIsTheCurrentTime() {
        defer { temp.remove() }
        let before = Date()
        let now = SystemTimeSource().now
        #expect(now >= before)
        #expect(now <= Date())
    }

    @Test func statusesAreOrderedBySeverity() {
        defer { temp.remove() }
        #expect(OverallStatus.ok < .attention)
        #expect(OverallStatus.attention < .error)
        #expect([OverallStatus.attention, .error, .ok].max() == .error)
    }

    @Test func destinationKindPicksItsStore() async {
        defer { temp.remove() }
        let runner = FakeProcessRunner()
        let factory = DefaultDestinationStoreFactory(runner: runner, rclone: RcloneLocator(candidates: []), naming: Fixtures.naming)
        let cloud = factory.store(for: Destination(name: "Cloud", kind: .rclone(remote: "gdrive", path: "backups")))
        let disk = factory.store(for: Fixtures.localDestination("HDD", at: temp.url))
        #expect(cloud is RcloneDestination)
        #expect(disk is LocalFolderDestination)
        #expect(await cloud.isAvailable() == false)
        #expect(await disk.isAvailable())
        #expect(runner.calls.isEmpty)
    }

    @Test func sourceStepsPickTheirProvider() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        let inbox = ManualExportInbox(pendingRoot: temp.path("pending"), naming: Fixtures.naming)
        let factory = DefaultSourceProviderFactory(runner: FakeProcessRunner(), stagingRoot: temp.path("staging"), inbox: inbox)
        let folder = Fixtures.source(steps: [.folder(temp.path("vault").path)])
        let steps = Fixtures.source(steps: [.folder(temp.path("vault").path), .command("true", timeoutSeconds: 30)])
        let manual = Fixtures.source(steps: [.file("export-*.csv", in: temp.path("Downloads").path)])

        #expect(factory.provider(for: folder) is FolderSource)
        #expect(factory.provider(for: manual) is PendingSource)
        let stepsProvider = factory.provider(for: steps)
        #expect(stepsProvider is StepsSource)
        let payload = try await stepsProvider.collect(at: date) { _ in }
        #expect(try FileManager.default.contentsOfDirectory(atPath: payload.root.path) == ["a.md"])
        stepsProvider.finish(payload, deliveredEverywhere: true)
        #expect(temp.names(in: "staging").isEmpty)
    }

    private func collect(_ steps: [SourceStep]) async throws -> Payload {
        try await StepsSource(sourceId: UUID(), steps: steps, stagingRoot: temp.path("staging"), runner: FakeProcessRunner()).collect(at: date)
    }

    @Test func folderStepOfASingleFileCopiesThatFile() async throws {
        defer { temp.remove() }
        try temp.file("exports/finance.csv", "1;2")
        let payload = try await collect([.folder(temp.path("exports/finance.csv").path), .command("true", timeoutSeconds: 30)])
        #expect(try String(contentsOf: payload.root.appendingPathComponent("finance.csv"), encoding: .utf8) == "1;2")
    }

    @Test func folderStepKeepsEmptyFoldersAndLinks() async throws {
        defer { temp.remove() }
        try temp.file("vault/notes/a.md", "alpha")
        try temp.directory("vault/attachments/empty")
        try FileManager.default.createSymbolicLink(atPath: temp.path("vault/latest.md").path, withDestinationPath: "notes/a.md")
        let payload = try await collect([.folder(temp.path("vault").path), .command("true", timeoutSeconds: 30)])
        let fileManager = FileManager.default
        #expect(try fileManager.contentsOfDirectory(atPath: payload.root.appendingPathComponent("attachments/empty").path).isEmpty)
        #expect(try fileManager.destinationOfSymbolicLink(atPath: payload.root.appendingPathComponent("latest.md").path) == "notes/a.md")
        #expect(try String(contentsOf: payload.root.appendingPathComponent("notes/a.md"), encoding: .utf8) == "alpha")
    }

    @Test func specialFilesAreNotPartOfTheCopy() throws {
        defer { temp.remove() }
        try temp.file("vault/a.md", "alpha")
        #expect(mkfifo(temp.path("vault/pipe").path, 0o644) == 0)
        let entries = try PayloadWalker().entries(of: Payload(root: temp.path("vault"), collectedAt: date))
        #expect(entries.map(\.relativePath) == ["a.md"])
    }

    @Test func excludedFolderIsNotEnteredAndEmptySourceHasNoFiles() throws {
        defer { temp.remove() }
        try temp.file("vault/.trash/deep/old.md")
        try temp.directory("vault/empty")
        let walker = PayloadWalker()
        let entries = try walker.entries(of: Payload(root: temp.path("vault"), excludes: [".trash"], collectedAt: date))
        #expect(entries.map(\.relativePath) == ["empty"])
        #expect(walker.stats(of: entries) == PayloadStats(fileCount: 0, totalBytes: 0))
    }
}

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
        #expect(DestinationError.rsyncMissing.localizedDescription == "rsync 3 is not installed. Install it with “brew install rsync”.")
        #expect(DestinationError.commandFailed("No space left on device").localizedDescription == "rsync failed: No space left on device")
        #expect(DestinationError.invalidFolderName("../photos").localizedDescription
            == "The folder for copies of this source is named “../photos”, which is not a single folder name. Nothing was read or written. Fix “slug” of the source in config.json.")
        #expect(DestinationError.notReady(.folderMissing).localizedDescription == "The destination folder is not there (disk not connected?).")
        #expect(DestinationError.notReady(.notOwnedByBackupAccount(owner: "max")).localizedDescription
            == "The destination folder belongs to “max”, not to the backup account. Run the setup script.")
        #expect(DestinationError.notReady(.volumeIgnoresOwners).localizedDescription
            == "The disk ignores file owners, so copies there cannot be protected. Run the setup script: it enables ownership on the disk.")
        #expect(DestinationError.notReady(.ancestorNotTraversable(path: "/Users/max/Documents")).localizedDescription
            == "“/Users/max/Documents” does not let the backup account in (it is private, 700); choose a destination folder outside Desktop, Documents, Downloads and other private folders, or open that folder to others (chmod o+x)")
        #expect(DestinationError.notReady(.accountMissing).localizedDescription
            == "The backup account “_backupeverything” does not exist. Run the setup script.")
    }

    @Test func sourceErrorsExplainThemselves() {
        defer { temp.remove() }
        #expect(SourceError.commandTimedOut(seconds: 60, output: "still downloading").localizedDescription
            == "Command did not finish within 60 s and was stopped. still downloading")
        #expect(SourceError.nothingToCollect.localizedDescription == "No picked-up files for this source.")
        #expect(SourceError.pickupFailed("disk full").localizedDescription == "Could not pick up the files: disk full")
        #expect(SourceError.unreadable("/Users/max/Library/Mail").localizedDescription
            == "Could not read “/Users/max/Library/Mail”, so the copy would miss it. Give Backup Everything access (System Settings → Privacy & Security → Full Disk Access) or add it to the exclusions.")
        #expect(SourceError.reservedName("_snapshot.json").localizedDescription
            == "“_snapshot.json” at the top of the source has the name Backup Everything gives its own file in every copy. Rename it, move it into a subfolder or add it to the exclusions.")
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

    @Test func destinationKindPicksItsStore() async throws {
        defer { temp.remove() }
        let runner = FakeProcessRunner()
        let transfer = RsyncTransfer(rsync: RsyncTransfer.homebrewRsync, receiver: nil, runner: runner, scratch: temp.path("scratch"))
        let factory = DefaultDestinationStoreFactory(naming: Fixtures.naming, access: AlwaysReadyAccess(), transfer: transfer)
        let disk = factory.store(for: Fixtures.localDestination("HDD", at: try temp.directory("hdd")))
        let unplugged = factory.store(for: Fixtures.localDestination("SSD", at: temp.path("ssd")))
        #expect(disk is LocalFolderDestination)
        #expect(await disk.readiness() == .ready)
        #expect(await unplugged.readiness() == .folderMissing)
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
        try stepsProvider.finish(payload, delivered: .everywhere)
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

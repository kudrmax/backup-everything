import Foundation
import Testing
@testable import BackupCore

/// Reproductions of bugs found while raising coverage. Each test describes the behaviour the spec asks for and fails until the bug is fixed.
struct FoundBugsCoreCoverageTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")
    private let name = "2026-09-28_143000"

    init() throws {
        temp = try TempDirectory()
    }

    private func cloud() throws -> RcloneDestination {
        let executable = try #require(RcloneLocator().find(), "rclone is required: brew install rclone")
        try temp.directory("remote")
        return RcloneDestination(executable: executable, remote: ":local", path: temp.path("remote").path, runner: SystemProcessRunner(), naming: Fixtures.naming)
    }

    private func manifest() -> SnapshotManifest {
        SnapshotManifest(sourceId: UUID(), sourceName: "Obsidian", collectedAt: date, fileCount: 1, totalBytes: 5)
    }

    /// Spec 4.3: a folder without the mark under the new copy's name stops the write; it is never touched. The cloud writes into it,
    /// so the foreign folder becomes a “copy” and is later purged by retention together with the files that were there.
    @Test func cloudWriteDoesNotTakeOverAForeignFolderWithTheSameName() async throws {
        defer { temp.remove() }
        let destination = try cloud()
        try temp.file("vault/a.md", "alpha")
        try temp.file("remote/obsidian/\(name)/mine.md", "not a backup")

        await #expect(throws: DestinationError.self) {
            try await destination.write(Payload(root: temp.path("vault"), collectedAt: date), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)
        }
        #expect(try await destination.listSnapshots(sourceSlug: "obsidian").isEmpty)
        #expect(temp.names(in: "remote/obsidian/\(name)") == ["mine.md"])
    }

    /// Spec 4.3: an unfinished folder under the same name (a retry of the same copy) is replaced, the copy is written anew.
    /// The cloud copies over it, so files of the failed attempt that are no longer in the source stay in the finished copy.
    @Test func cloudRetryReplacesTheUnfinishedAttemptUnderTheSameName() async throws {
        defer { temp.remove() }
        let destination = try cloud()
        try temp.file("vault/a.md", "alpha")
        try temp.file("remote/obsidian/\(name)/_unfinished")
        try temp.file("remote/obsidian/\(name)/deleted-since.md", "stale")

        try await destination.write(Payload(root: temp.path("vault"), collectedAt: date), manifest: manifest(), sourceSlug: "obsidian", snapshotName: name, reusingStoredFiles: true)

        #expect(temp.names(in: "remote/obsidian/\(name)") == ["_snapshot.json", "a.md"])
    }

    /// Spec 4.3: names inside a local copy match the original byte for byte. A source of several steps copies its folder
    /// through FileManager and URL, which store “й” as “и” plus a combining breve.
    @Test func folderStepKeepsNamesByteForByte() async throws {
        defer { temp.remove() }
        let composed = "Мой план".precomposedStringWithCanonicalMapping
        try temp.directory("vault")
        #expect(FileManager.default.createFile(atPath: temp.path("vault").path + "/" + composed + ".md", contents: Data("plan".utf8)))
        let source = StepsSource(
            sourceId: UUID(),
            steps: [.folder(temp.path("vault").path), .command("true", timeoutSeconds: 30)],
            stagingRoot: temp.path("staging"),
            runner: FakeProcessRunner()
        )

        let payload = try await source.collect(at: date)

        let names = try FileManager.default.contentsOfDirectory(atPath: payload.root.path)
        #expect(names.map { Array($0.utf8) } == [Array("\(composed).md".utf8)])
    }

    /// When clocks go back, the hour repeats and two backups an hour apart get the same name (local time without offset).
    /// The second one is then taken for “already delivered”: it reports success and its content is never stored.
    @Test func backupInTheRepeatedHourIsNotLost() async throws {
        defer { temp.remove() }
        let berlinZone = TimeZone(identifier: "Europe/Berlin")!
        let berlin = SnapshotNaming(timeZone: berlinZone)
        let first = Fixtures.date("2026-10-25 00:30:00")
        let second = Fixtures.date("2026-10-25 01:30:00")
        try temp.file("vault/a.md", "alpha")
        let provider = FakeSourceProvider(result: .success(Payload(root: temp.path("vault"), collectedAt: first)))
        let disk = Destination(name: "HDD", kind: .localFolder(path: "/unused"))
        let store = FakeDestinationStore()
        let factories = FakeFactories(sourceProvider: provider, destinationStores: [disk.id: store])
        let source = Fixtures.source(destinations: [disk])
        func engine(at now: Date) -> BackupEngine {
            BackupEngine(providers: factories, stores: factories, retention: RetentionPolicy(timeZone: berlinZone), naming: berlin, time: FakeTimeSource(now))
        }

        _ = await engine(at: first).run(source: source, destinations: [disk], trigger: .manual)
        try temp.file("vault/a.md", "alpha, an hour later")
        provider.result = .success(Payload(root: temp.path("vault"), collectedAt: second))
        _ = await engine(at: second).run(source: source, destinations: [disk], trigger: .manual)

        #expect(store.log.filter { $0.hasPrefix("write:") }.count == 2)
    }

    /// A catch-up copy is the same snapshot transferred as is. Files the person keeps under the names of the app's service files
    /// in subfolders are dropped from it, because the service files are excluded by name at any depth.
    @Test func catchUpCopyKeepsNestedFilesNamedLikeServiceFiles() async throws {
        defer { temp.remove() }
        try temp.directory("hdd")
        try temp.directory("ssd")
        try temp.file("vault/notes/_unfinished", "a note called _unfinished")
        try temp.file("vault/a.md", "alpha")
        let hdd = Fixtures.localDestination("HDD", at: temp.path("hdd"))
        let ssd = Fixtures.localDestination("SSD", at: temp.path("ssd"))
        let source = Fixtures.source(steps: [.folder(temp.path("vault").path)], destinations: [hdd, ssd])
        let stores = DefaultDestinationStoreFactory(runner: FakeProcessRunner(), rclone: RcloneLocator(candidates: []), naming: Fixtures.naming)
        let engine = BackupEngine(
            providers: DefaultSourceProviderFactory(runner: FakeProcessRunner(), stagingRoot: temp.path("staging"), inbox: ManualExportInbox(pendingRoot: temp.path("pending"), naming: Fixtures.naming)),
            stores: stores,
            retention: RetentionPolicy(timeZone: Fixtures.utc),
            naming: Fixtures.naming,
            time: FakeTimeSource(date)
        )
        let original = await engine.run(source: source, destinations: [hdd], trigger: .scheduled)
        let snapshot = Snapshot(name: try #require(original.snapshotName), date: date)

        _ = await engine.copy(snapshot, of: source, from: hdd, to: [ssd])

        #expect(temp.exists("ssd/obsidian/\(snapshot.name)/notes/_unfinished"))
    }
}


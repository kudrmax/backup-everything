import Foundation
import Testing
@testable import BackupCore

/// A source owns its folder in a destination and only the copies whose manifest names it: a new source never takes over
/// the folder of a removed one, and copies of another source in its folder are never pruned, counted as its own or overwritten.
struct SourceIdentityTests {
    private let editor = ConfigEditor()
    private let temp: TempDirectory
    private let first = Fixtures.date("2026-09-01 10:00:00")
    private let second = Fixtures.date("2026-09-08 10:00:00")

    init() throws {
        temp = try TempDirectory()
        try temp.directory("disk")
        try temp.directory("Trash")
    }

    private func disk() -> LocalFolderDestination {
        let trash = temp.path("Trash")
        return LocalFolderDestination(root: temp.path("disk"), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
    }

    private func backUp(_ folder: String, to destination: any DestinationStore, at date: Date, slug: String, sourceId: UUID) async throws {
        let payload = Payload(root: temp.path(folder), collectedAt: date)
        let manifest = SnapshotManifest(sourceId: sourceId, sourceName: "Photos", collectedAt: date, fileCount: 1, totalBytes: 1)
        try await destination.write(payload, manifest: manifest, sourceSlug: slug, snapshotName: Fixtures.naming.name(for: date), reusingStoredFiles: false)
    }

    private func engine(at now: Date, payload folder: String) -> BackupEngine {
        let stores = LocalDisk(trash: temp.path("Trash"), provider: FakeSourceProvider(result: .success(Payload(root: temp.path(folder), collectedAt: now))))
        return BackupEngine(providers: stores, stores: stores, retention: RetentionPolicy(timeZone: Fixtures.utc), naming: Fixtures.naming, time: FakeTimeSource(now))
    }

    // MARK: Folder names of removed sources

    @Test func newSourceWithTheNameOfADeletedOneDoesNotTakeOverAndPruneItsCopies() async throws {
        defer { temp.remove() }
        let store = Store(dataDirectory: temp.path("data"))
        let time = FakeTimeSource(first)
        try temp.file("notes/old.txt", "old notes")
        try temp.file("photos/new.jpg", "new photos")
        let destination = Fixtures.localDestination("Disk", at: temp.path("disk"))
        let onlyNewest = RetentionRules(daily: 0, weekly: 0, monthly: 0, yearly: 0)
        let coordinator = CoreAssembly.makeCoordinator(dataDirectory: temp.path("data"), workDirectory: temp.path("work"), timeZone: Fixtures.utc, time: time)

        var config = Config(destinations: [destination])
        var old = editor.makeSource(name: "Archive", steps: [.folder(temp.path("notes").path)], retention: onlyNewest, now: time.now, in: config)
        old.destinationIds = [destination.id]
        editor.save(old, in: &config)
        try store.saveConfig(config)
        _ = try await coordinator.tick()

        editor.removeSource(old.id, from: &config)
        time.advance(86_400)
        var replacement = editor.makeSource(name: "Archive", steps: [.folder(temp.path("photos").path)], retention: onlyNewest, now: time.now, in: config)
        replacement.destinationIds = [destination.id]
        editor.save(replacement, in: &config)
        try store.saveConfig(config)
        _ = try await coordinator.tick()

        #expect(temp.exists("disk/archive/2026-09-01_100000/old.txt"))
        #expect(config.sources.map(\.slug) == ["archive-2"])
        #expect(temp.exists("disk/archive-2/2026-09-02_100000/new.jpg"))
        #expect(try store.loadConfig().retiredSlugs == ["archive"])
    }

    @Test func removedSourceRetiresItsFolderNameOnce() {
        defer { temp.remove() }
        var config = Config()
        let photos = editor.makeSource(name: "Photos", steps: [.folder("/a")], now: first, in: config)
        editor.save(photos, in: &config)
        editor.removeSource(photos.id, from: &config)
        editor.removeSource(photos.id, from: &config)
        editor.removeSource(UUID(), from: &config)

        #expect(config.retiredSlugs == ["photos"])
        #expect(editor.makeSource(name: "Photos", steps: [.folder("/b")], now: second, in: config).slug == "photos-2")
        editor.save(Fixtures.source(name: "Photos"), in: &config)
        #expect(config.sources.map(\.slug) == ["photos-2"])
    }

    @Test func configWrittenBeforeFolderNamesWereRetiredStillLoads() throws {
        defer { temp.remove() }
        let json = #"{"schemaVersion":2,"sources":[],"destinations":[]}"#
        #expect(try JSONCoding.decoder().decode(Config.self, from: Data(json.utf8)).retiredSlugs == [])

        let config = Config(retiredSlugs: ["photos"])
        #expect(try JSONCoding.decoder().decode(Config.self, from: JSONCoding.encoder().encode(config)) == config)
    }

    // MARK: Copies of another source in the same folder (configurations made before folder names were retired)

    @Test func newSourceWithTheNameOfARemovedOneDoesNotPruneTheOldSourcesCopies() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.jpg", "old photo")
        try temp.file("new/b.jpg", "new photo")
        let removedId = UUID()
        let oldDays = ["2026-09-01 10:00:00", "2026-09-02 10:00:00", "2026-09-03 10:00:00"].map(Fixtures.date)
        for day in oldDays {
            try await backUp("vault", to: disk(), at: day, slug: "photos", sourceId: removedId)
        }
        let destination = Fixtures.localDestination("HDD", at: temp.path("disk"))
        var fresh = Fixtures.source(name: "Photos", destinations: [destination])
        fresh.retention = RetentionRules(daily: 1, weekly: 0, monthly: 0, yearly: 0)

        let record = await engine(at: second, payload: "new").run(source: fresh, destinations: [destination], trigger: .scheduled)

        #expect(record.deliveries.map(\.outcome) == [.delivered(pruned: 0, warning: nil)])
        for day in oldDays {
            #expect(temp.exists("disk/photos/\(Fixtures.naming.name(for: day))/a.jpg"))
        }
        #expect(try await disk().copies(of: fresh).map(\.date) == [second])
    }

    @Test func copyOfAnotherSourceUnderTheSameNameIsNotTakenForDelivered() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.jpg", "someone else's photo")
        try temp.file("new/b.jpg", "new photo")
        try await backUp("vault", to: disk(), at: second, slug: "photos", sourceId: UUID())
        let destination = Fixtures.localDestination("HDD", at: temp.path("disk"))
        let photos = Fixtures.source(name: "Photos", destinations: [destination])

        let record = await engine(at: second, payload: "new").run(source: photos, destinations: [destination], trigger: .scheduled)

        #expect(record.deliveries.first?.outcome.isDelivered == false)
        #expect(temp.names(in: "disk/photos/\(Fixtures.naming.name(for: second))") == ["_snapshot.json", "a.jpg"])
    }

    @Test func copyWhoseManifestCannotBeReadIsKeptAmongTheSourcesCopies() async throws {
        defer { temp.remove() }
        try temp.file("vault/a.jpg", "photo")
        let photos = Fixtures.source(name: "Photos")
        try await backUp("vault", to: disk(), at: first, slug: "photos", sourceId: photos.id)
        try await backUp("vault", to: disk(), at: second, slug: "photos", sourceId: photos.id)
        try temp.file("disk/photos/\(Fixtures.naming.name(for: first))/_snapshot.json", "{damaged")

        #expect(try await disk().owners(sourceSlug: "photos") == [Fixtures.naming.name(for: second): photos.id])
        #expect(Set(try await disk().copies(of: photos).map(\.date)) == [first, second])
    }

    // MARK: Cloud

    @Test func cloudTellsWhoseCopiesAreInTheFolder() async throws {
        defer { temp.remove() }
        let executable = try #require(RcloneLocator().find(), "rclone is required: brew install rclone")
        try temp.directory("remote")
        let cloud = RcloneDestination(executable: executable, remote: ":local", path: temp.path("remote").path, runner: SystemProcessRunner(), naming: Fixtures.naming)
        try temp.file("vault/a.jpg", "photo")
        let photos = Fixtures.source(name: "Photos")
        let removedId = UUID()
        try await backUp("vault", to: cloud, at: first, slug: "photos", sourceId: removedId)
        try await backUp("vault", to: cloud, at: second, slug: "photos", sourceId: photos.id)

        #expect(try await cloud.owners(sourceSlug: "photos") == [
            Fixtures.naming.name(for: first): removedId,
            Fixtures.naming.name(for: second): photos.id,
        ])
        #expect(try await cloud.copies(of: photos).map(\.date) == [second])
        #expect(try await cloud.owners(sourceSlug: "missing").isEmpty)
    }

    @Test func cloudThatCannotTellWhoseCopiesTheyAreIsAnError() async {
        defer { temp.remove() }
        let runner = FakeProcessRunner { call in
            call.arguments.first == "copy" ? ProcessResult(exitCode: 1, stderr: "token expired") : ProcessResult(exitCode: 0)
        }
        let cloud = RcloneDestination(executable: URL(fileURLWithPath: "/opt/homebrew/bin/rclone"), remote: "gdrive", path: "backups", runner: runner, naming: Fixtures.naming)
        await #expect(throws: DestinationError.commandFailed("token expired")) {
            try await cloud.copies(of: Fixtures.source(name: "Photos"))
        }
        #expect(runner.calls.last?.arguments.prefix(2) == ["copy", "gdrive:backups/photos"])
    }
}

private struct LocalDisk: SourceProviderFactory, DestinationStoreFactory {
    let trash: URL
    let provider: FakeSourceProvider

    func provider(for source: Source) -> any SourceProvider { provider }

    func store(for destination: Destination) -> any DestinationStore {
        guard case let .localFolder(path) = destination.kind else { fatalError("local folders only") }
        let trash = self.trash
        return LocalFolderDestination(root: URL(fileURLWithPath: path), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
    }
}

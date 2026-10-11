import Foundation
import Testing
@testable import BackupCore

/// A source owns its folder in a destination: a new source never takes over the folder of a removed one.
struct SourceIdentityTests {
    private let editor = ConfigEditor()
    private let temp: TempDirectory
    private let first = Fixtures.date("2026-09-01 10:00:00")
    private let second = Fixtures.date("2026-09-08 10:00:00")

    init() throws {
        temp = try TempDirectory()
        try temp.directory("disk")
    }

    // MARK: Folder names of removed sources

    @Test func newSourceWithTheNameOfADeletedOneDoesNotTakeOverItsFolder() async throws {
        defer { temp.remove() }
        let store = Store(dataDirectory: temp.path("data"))
        let time = FakeTimeSource(first)
        try temp.file("notes/old.txt", "old notes")
        try temp.file("photos/new.jpg", "new photos")
        let destination = Fixtures.localDestination("Disk", at: temp.path("disk"))
        let onlyNewest = RetentionRules(daily: 0, weekly: 0, monthly: 0, yearly: 0)
        let coordinator = CoreAssembly.makeCoordinator(
            dataDirectory: temp.path("data"), workDirectory: temp.path("work"), timeZone: Fixtures.utc, time: time, receiver: nil, access: AlwaysReadyAccess()
        )

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
}

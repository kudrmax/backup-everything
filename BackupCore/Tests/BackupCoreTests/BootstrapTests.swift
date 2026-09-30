import Foundation
import Testing
@testable import BackupCore

struct BootstrapTests {
    @Test func firstLaunchCreatesSelfBackupSourceAndTemplates() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let store = Store(dataDirectory: temp.path("data"))
        let bootstrap = Bootstrap(store: store, workDirectory: temp.path("work"))
        let now = Fixtures.date("2026-09-28 10:00:00")
        try temp.file("work/staging/leftover/output/file.txt")

        try bootstrap.prepare(now: now)

        let config = try store.loadConfig()
        #expect(config.sources.map(\.name) == [Bootstrap.selfSourceName])
        #expect(config.sources[0].kind == .folder(path: temp.path("data").path, excludes: []))
        #expect(config.sources[0].slug == "настройки-backup-everything")
        #expect(store.loadTemplates().count == 8)
        #expect(!temp.exists("work/staging"))
    }

    @Test func laterLaunchesKeepUserConfig() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let store = Store(dataDirectory: temp.path("data"))
        let bootstrap = Bootstrap(store: store, workDirectory: temp.path("work"))
        try bootstrap.prepare(now: Fixtures.date("2026-09-28 10:00:00"))
        try store.saveConfig(Config())

        try bootstrap.prepare(now: Fixtures.date("2026-09-29 10:00:00"))
        #expect(try store.loadConfig().sources.isEmpty)
    }

    @Test func assembledCoordinatorBacksUpItsOwnSettings() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let store = Store(dataDirectory: temp.path("data"))
        let time = FakeTimeSource(Fixtures.date("2026-09-28 10:00:00"))
        try Bootstrap(store: store, workDirectory: temp.path("work")).prepare(now: time.now)
        try temp.directory("backups")
        let destination = Fixtures.localDestination("Disk", at: temp.path("backups"))
        var config = try store.loadConfig()
        config.destinations = [destination]
        config.sources[0].destinationIds = [destination.id]
        try store.saveConfig(config)

        let coordinator = CoreAssembly.makeCoordinator(
            dataDirectory: temp.path("data"),
            workDirectory: temp.path("work"),
            timeZone: Fixtures.utc,
            time: time
        )
        let result = try await coordinator.tick()

        #expect(result.runs.count == 1)
        #expect(temp.exists("backups/настройки-backup-everything/2026-09-28_100000/config.json"))
        #expect(temp.exists("backups/настройки-backup-everything/2026-09-28_100000/templates/github.json"))
    }
}

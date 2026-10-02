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
        #expect(config.sources[0].singleFolder?.path == temp.path("data").path)
        #expect(config.sources[0].slug == "backup-everything-settings")
        #expect(store.loadTemplates().count == BundledTemplates.all.count)
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
        #expect(temp.exists("backups/backup-everything-settings/2026-09-28_100000/config.json"))
        #expect(temp.exists("backups/backup-everything-settings/2026-09-28_100000/templates/github.json"))
    }

    /// A command of a source without manual steps runs in `staging`. If the app was killed while it ran, the next launch
    /// stops it before the folder it works in is deleted.
    @Test func launchStopsACommandLeftRunningInStaging() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let spawned = LockedBox<ProcessIdentity?>(nil)
        let finished = Task {
            try await SystemProcessRunner(groups: ProcessGroups()).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 30"],
                environment: [:],
                timeout: 60,
                onOutput: nil,
                onSpawn: { spawned.set($0) }
            )
        }
        while spawned.get() == nil { try await Task.sleep(for: .milliseconds(20)) }
        let orphan = try #require(spawned.get())
        try temp.directory("work/staging/run/output")
        try JSONEncoder().encode(orphan).write(to: temp.path("work/staging/run/process.json"))

        try Bootstrap(store: Store(dataDirectory: temp.path("data")), workDirectory: temp.path("work")).prepare(now: Fixtures.date("2026-09-28 10:00:00"))

        #expect(!orphan.isRunning)
        _ = try await finished.value
        #expect(!temp.exists("work/staging"))
    }

    @Test func commandOfASourceWithoutManualStepsIsRecordedWhileItRuns() async throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        let source = StepsSource(
            sourceId: UUID(),
            steps: [.command(#"cat "$BACKUP_OUTPUT_DIR/../process.json" > "$BACKUP_OUTPUT_DIR/seen.json""#, timeoutSeconds: 20)],
            stagingRoot: temp.path("staging"),
            runner: SystemProcessRunner(groups: ProcessGroups())
        )

        let payload = try await source.collect(at: Fixtures.date("2026-09-28 10:00:00"))

        let seen = try JSONDecoder().decode(ProcessIdentity.self, from: Data(contentsOf: payload.root.appendingPathComponent("seen.json")))
        #expect(seen.pid > 1)
        #expect(!FileManager.default.fileExists(atPath: payload.root.deletingLastPathComponent().appendingPathComponent("process.json").path))
    }
}

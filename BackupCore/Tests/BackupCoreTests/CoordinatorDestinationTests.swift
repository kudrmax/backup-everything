import Foundation
import Testing
@testable import BackupCore

/// How the coordinator treats several destinations: which copy a destination that missed backups receives (5.3) and how copies are verified (5.3.1).
struct CoordinatorDestinationTests {
    private let temp: TempDirectory
    private let time: FakeTimeSource
    private let store: Store
    private let coordinator: BackupCoordinator
    private let hdd: Destination
    private let start = Fixtures.date("2026-09-28 10:00:00")

    init() throws {
        let temp = try TempDirectory()
        self.temp = temp
        time = FakeTimeSource(start)
        store = Store(dataDirectory: temp.path("data"))
        try temp.file("vault/a.md", "alpha")
        try temp.directory("trash")
        hdd = Fixtures.localDestination("HDD", at: temp.path("hdd"))

        let trash: ManualExportInbox.Trash = { url in try FileManager.default.moveItem(at: url, to: temp.path("trash/\(UUID().uuidString)")) }
        let inbox = ManualExportInbox(pendingRoot: temp.path("work/pending"), naming: Fixtures.naming, trash: trash)
        let runner = SystemProcessRunner()
        let stores = DefaultDestinationStoreFactory(runner: runner, rclone: RcloneLocator(), naming: Fixtures.naming)
        coordinator = BackupCoordinator(
            store: store,
            engine: BackupEngine(
                providers: DefaultSourceProviderFactory(runner: runner, stagingRoot: temp.path("work/staging"), inbox: inbox),
                stores: stores,
                retention: RetentionPolicy(timeZone: Fixtures.utc),
                naming: Fixtures.naming,
                time: time
            ),
            inbox: inbox,
            chains: StepChainRunner(chainsRoot: temp.path("work/chains"), inbox: inbox, runner: runner, time: time, trash: trash),
            stores: stores,
            time: time,
            calendar: Fixtures.calendar
        )
    }

    private func local(_ name: String) throws -> Destination {
        try temp.directory(name.lowercased())
        return Fixtures.localDestination(name, at: temp.path(name.lowercased()))
    }

    private func vault(_ destinations: [Destination]) -> Source {
        Fixtures.source(steps: [.folder(temp.path("vault").path, excludes: [])], destinations: destinations, createdAt: Fixtures.date("2026-09-27 00:00:00"))
    }

    @Test(arguments: [true, false])
    func onATieTheLocalCopyIsTakenInsteadOfDownloading(cloudFirst: Bool) async throws {
        defer { temp.remove() }
        _ = try #require(RcloneLocator().find(), "rclone is required: brew install rclone")
        try temp.directory("remote")
        let cloud = Destination(name: "Cloud", kind: .rclone(remote: ":local", path: temp.path("remote").path))
        let ssd = try local("SSD")
        let origins = cloudFirst ? [cloud, ssd] : [ssd, cloud]
        try store.saveConfig(Config(sources: [vault(origins + [hdd])], destinations: origins + [hdd]))
        _ = try await coordinator.tick()
        #expect(temp.names(in: "remote/obsidian") == ["2026-09-28_100000"])
        #expect(temp.names(in: "ssd/obsidian") == ["2026-09-28_100000"])

        try temp.directory("hdd")
        time.advance(600)
        let result = try await coordinator.tick()

        #expect(result.runs.map(\.copiedFrom) == ["SSD"])
        #expect(temp.names(in: "hdd/obsidian") == ["2026-09-28_100000"])
        #expect(try store.loadState().debts.isEmpty)
    }

    @Test func theNewestCopyAmongSeveralDisksIsTaken() async throws {
        defer { temp.remove() }
        let first = try local("First")
        let second = try local("Second")
        let third = try local("Third")
        try store.saveConfig(Config(sources: [vault([first, second, third, hdd])], destinations: [first, second, third, hdd]))
        _ = try await coordinator.tick()
        try temp.file("second/obsidian/2026-09-28_100500/a.md", "newer")
        try temp.file("second/obsidian/2026-09-28_100500/_snapshot.json", "{}")

        try temp.directory("hdd")
        time.advance(600)
        let result = try await coordinator.tick()

        #expect(result.runs.map(\.copiedFrom) == ["Second"])
        #expect(temp.names(in: "hdd/obsidian") == ["2026-09-28_100500"])
        #expect(try String(contentsOf: temp.path("hdd/obsidian/2026-09-28_100500/a.md"), encoding: .utf8) == "newer")
    }

    @Test func unfinishedCopyOnAnotherDiskIsNeverUsedForCatchUp() async throws {
        defer { temp.remove() }
        let first = try local("First")
        try store.saveConfig(Config(sources: [vault([first, hdd])], destinations: [first, hdd]))
        _ = try await coordinator.tick()
        try temp.file("first/obsidian/2026-09-28_100500/a.md", "half")
        try temp.file("first/obsidian/2026-09-28_100500/_unfinished")

        try temp.directory("hdd")
        time.advance(600)
        let result = try await coordinator.tick()

        #expect(result.runs.map(\.snapshotName) == ["2026-09-28_100000"])
        #expect(temp.names(in: "hdd/obsidian") == ["2026-09-28_100000"])
        #expect(try String(contentsOf: temp.path("hdd/obsidian/2026-09-28_100000/a.md"), encoding: .utf8) == "alpha")
    }

    @Test func runningARemovedSourceOrConfirmingAnAutomaticOneDoesNothing() async throws {
        defer { temp.remove() }
        let first = try local("First")
        let source = vault([first])
        try store.saveConfig(Config(sources: [source], destinations: [first]))
        #expect(try await coordinator.runNow(sourceId: UUID()) == TickResult())
        #expect(try await coordinator.confirmPickup(sourceId: source.id) == TickResult())
        #expect(temp.names(in: "first").isEmpty)
        #expect(store.loadRuns().isEmpty)
    }

    private func weekly(_ destinations: [Destination]) -> Source {
        Fixtures.source(
            steps: [.folder(temp.path("vault").path, excludes: [])],
            schedule: .weekly,
            destinations: destinations,
            createdAt: Fixtures.date("2026-09-27 00:00:00")
        )
    }

    @Test func unpluggedDiskIsNotTakenForLostCopies() async throws {
        defer { temp.remove() }
        let first = try local("First")
        try temp.directory("hdd")
        try store.saveConfig(Config(sources: [weekly([first, hdd])], destinations: [first, hdd]))
        _ = try await coordinator.tick()
        #expect(temp.names(in: "hdd/obsidian") == ["2026-09-28_100000"])

        try FileManager.default.moveItem(at: temp.path("hdd"), to: temp.path("hdd-unplugged"))
        time.advance(2 * 86_400)
        let result = try await coordinator.tick()

        #expect(result == TickResult())
        #expect(try store.loadState().debts.isEmpty)
        #expect(try store.loadState().lastDeliveredSnapshot(sourceId: store.loadConfig().sources[0].id, destinationId: hdd.id) == "2026-09-28_100000")
    }

    @Test func cloudThatCannotBeListedIsNotTakenForLostCopies() async throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path("remote/obsidian").path)
            temp.remove()
        }
        _ = try #require(RcloneLocator().find(), "rclone is required: brew install rclone")
        try temp.directory("remote")
        let cloud = Destination(name: "Cloud", kind: .rclone(remote: ":local", path: temp.path("remote").path))
        try store.saveConfig(Config(sources: [weekly([cloud])], destinations: [cloud]))
        _ = try await coordinator.tick()
        #expect(temp.names(in: "remote/obsidian") == ["2026-09-28_100000"])

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: temp.path("remote/obsidian").path)
        time.advance(2 * 86_400)
        let result = try await coordinator.tick()

        #expect(result.notices.isEmpty)
        #expect(try store.loadState().debts.isEmpty)
    }

    @Test func cloudCopiesAreVerifiedAtMostOnceADay() async throws {
        defer { temp.remove() }
        _ = try #require(RcloneLocator().find(), "rclone is required: brew install rclone")
        try temp.directory("remote")
        let cloud = Destination(name: "Cloud", kind: .rclone(remote: ":local", path: temp.path("remote").path))
        let source = weekly([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        _ = try await coordinator.tick()
        time.advance(600)
        #expect(try await coordinator.tick() == TickResult())
        try FileManager.default.moveItem(at: temp.path("remote/obsidian"), to: temp.path("moved-away"))

        time.advance(3600)
        #expect(try await coordinator.tick() == TickResult())

        time.advance(86_400 - 3600)
        let result = try await coordinator.tick()
        #expect(result.notices == [.copiesMissing(sourceId: source.id, sourceName: "Obsidian", destinationName: "Cloud")])
        #expect(result.runs.map(\.trigger) == [.catchUp])
        #expect(temp.names(in: "remote/obsidian").count == 1)
    }
}

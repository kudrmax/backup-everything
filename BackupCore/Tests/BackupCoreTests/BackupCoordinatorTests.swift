import Foundation
import Testing
@testable import BackupCore

struct BackupCoordinatorTests {
    private let temp: TempDirectory
    private let time: FakeTimeSource
    private let store: Store
    private let coordinator: BackupCoordinator
    private let cloud: Destination
    private let disk: Destination
    private let events = LockedBox<[RunProgress]>([])
    private let start = Fixtures.date("2026-09-28 10:00:00")
    private let created = Fixtures.date("2026-09-27 00:00:00")

    init() throws {
        let temp = try TempDirectory()
        self.temp = temp
        time = FakeTimeSource(start)
        store = Store(dataDirectory: temp.path("data"))
        try temp.directory("cloud")
        try temp.directory("Downloads")
        try temp.directory("trash")
        try temp.file("vault/a.md", "alpha")
        cloud = Fixtures.localDestination("Cloud", at: temp.path("cloud"))
        disk = Fixtures.localDestination("HDD", at: temp.path("hdd"), expectedEvery: .days(30))

        let inbox = ManualExportInbox(pendingRoot: temp.path("work/pending"), naming: Fixtures.naming) { url in
            try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)"))
        }
        let runner = SystemProcessRunner()
        let stores = DefaultDestinationStoreFactory(runner: runner, rclone: RcloneLocator(candidates: []), naming: Fixtures.naming)
        let engine = BackupEngine(
            providers: DefaultSourceProviderFactory(runner: runner, stagingRoot: temp.path("work/staging"), inbox: inbox),
            stores: stores,
            retention: RetentionPolicy(timeZone: Fixtures.utc),
            naming: Fixtures.naming,
            time: time,
            progress: { [events] event in events.set(events.get() + [event]) }
        )
        coordinator = BackupCoordinator(
            store: store,
            engine: engine,
            inbox: inbox,
            stores: stores,
            time: time,
            calendar: Fixtures.calendar,
            progress: { [events] event in events.set(events.get() + [event]) }
        )
    }

    private func vault(_ destinations: [Destination]) -> Source {
        Fixtures.source(kind: .folder(path: temp.path("vault").path, excludes: []), destinations: destinations, createdAt: created)
    }

    private func photos(_ mode: FileMode, _ destinations: [Destination]) -> Source {
        Fixtures.source(
            name: "Photos",
            kind: .manualExport(watchPath: temp.path("Downloads").path, filePattern: "takeout-*.zip", fileMode: mode, removeOriginal: true),
            schedule: .monthly,
            destinations: destinations,
            createdAt: created
        )
    }

    @Test func dueSourceIsBackedUpOncePerInterval() async throws {
        defer { temp.remove() }
        try store.saveConfig(Config(sources: [vault([cloud])], destinations: [cloud]))

        let first = try await coordinator.tick()
        #expect(first.runs.map(\.trigger) == [.scheduled])
        #expect(first.notices.isEmpty)
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_100000"])
        #expect(store.loadRuns().count == 1)
        #expect(try await coordinator.statusReport().overall == .ok)
        #expect(try await coordinator.nextWake() == Fixtures.date("2026-09-29 10:00:00"))

        time.advance(3600)
        #expect(try await coordinator.tick() == TickResult())

        time.advance(23 * 3600)
        #expect(try await coordinator.tick().runs.count == 1)
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_100000", "2026-09-29_100000"])
    }

    @Test func overlappingTicksRunTheSourceOnlyOnce() async throws {
        defer { temp.remove() }
        try store.saveConfig(Config(sources: [vault([cloud])], destinations: [cloud]))
        async let wake = coordinator.tick()
        async let mount = coordinator.tick()
        let results = try await [wake, mount]
        #expect(results.flatMap(\.runs).count == 1)
        #expect(temp.names(in: "cloud/obsidian").count == 1)
    }

    @Test func unpluggedDiskIsCaughtUpWithOneSnapshotWhenItReturns() async throws {
        defer { temp.remove() }
        try store.saveConfig(Config(sources: [vault([cloud, disk])], destinations: [cloud, disk]))

        for _ in 0..<3 {
            _ = try await coordinator.tick()
            time.advance(86_400)
        }
        #expect(temp.names(in: "cloud/obsidian").count == 3)
        #expect(!temp.exists("hdd"))
        #expect(try store.loadState().debts.count == 1)
        #expect(try await coordinator.statusReport().overall == .ok)

        time.advance(-3600)
        try temp.directory("hdd")
        let result = try await coordinator.tick()
        #expect(result.runs.map(\.trigger) == [.catchUp])
        #expect(result.notices == [.destinationCaughtUp(destinationId: disk.id, destinationName: "HDD")])
        #expect(temp.names(in: "hdd/obsidian").count == 1)
        #expect(try store.loadState().debts.isEmpty)
    }

    @Test func overdueDiskTriggersDailyConnectReminder() async throws {
        defer { temp.remove() }
        try store.saveConfig(Config(sources: [vault([disk])], destinations: [disk]))

        #expect(try await coordinator.tick() == TickResult())
        #expect(store.loadRuns().isEmpty)

        time.advance(30 * 86_400)
        let reminder = Notice.connectDestination(destinationId: disk.id, destinationName: "HDD")
        #expect(try await coordinator.tick().notices == [reminder])
        #expect(try await coordinator.statusReport().items == [.connectDestination(destinationId: disk.id)])

        time.advance(3600)
        #expect(try await coordinator.tick().notices.isEmpty)
        time.advance(23 * 3600)
        #expect(try await coordinator.tick().notices == [reminder])
    }

    @Test func failedRunIsReportedAndRetriedAfterAnHour() async throws {
        defer { temp.remove() }
        let source = Fixtures.source(kind: .folder(path: temp.path("moved").path, excludes: []), destinations: [cloud], createdAt: created)
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))

        let failed = try await coordinator.tick()
        let message = SourceError.pathMissing(temp.path("moved").path).localizedDescription
        #expect(failed.notices == [.runFailed(sourceId: source.id, sourceName: "Obsidian", message: message)])
        #expect(try await coordinator.statusReport().overall == .error)
        #expect(try await coordinator.nextWake() == start.addingTimeInterval(3600))

        time.advance(600)
        #expect(try await coordinator.tick().runs.isEmpty)

        try temp.file("moved/a.md")
        time.advance(3000)
        let retried = try await coordinator.tick()
        #expect(retried.runs.count == 1)
        #expect(retried.notices.isEmpty)
        #expect(try await coordinator.statusReport().overall == .ok)
    }

    @Test func singleFileExportIsPickedUpAutomatically() async throws {
        defer { temp.remove() }
        let source = photos(.single, [cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        #expect(try await coordinator.tick().notices == [.manualExportDue(sourceId: source.id, sourceName: "Photos")])

        try temp.file("Downloads/takeout-1.zip", "zip", modified: start.addingTimeInterval(-60))
        let result = try await coordinator.tick()
        #expect(result.runs.map(\.trigger) == [.pickup])
        #expect(temp.names(in: "cloud/photos/2026-09-28_100000") == ["_snapshot.json", "takeout-1.zip"])
        #expect(temp.names(in: "Downloads").isEmpty)
        #expect(temp.names(in: "trash") == ["takeout-1.zip"])
        #expect(try await coordinator.statusReport().overall == .ok)
    }

    @Test func multiFileExportWaitsForConfirmation() async throws {
        defer { temp.remove() }
        let source = photos(.multiple, [cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/takeout-1.zip", "one", modified: start.addingTimeInterval(-600))
        try temp.file("Downloads/takeout-2.zip", "two", modified: start.addingTimeInterval(-300))

        #expect(try await coordinator.tick().runs.isEmpty)
        #expect(try await coordinator.statusReport().items == [
            .filesAwaitingPickup(sourceId: source.id, fileCount: 2, totalBytes: 6, downloadInProgress: false),
        ])

        let result = try await coordinator.confirmPickup(sourceId: source.id)
        #expect(result.runs.map(\.trigger) == [.pickup])
        #expect(temp.names(in: "cloud/photos/2026-09-28_100000") == ["_snapshot.json", "takeout-1.zip", "takeout-2.zip"])
        #expect(try await coordinator.statusReport().overall == .ok)
    }

    @Test func confirmationIsIgnoredWhileDownloadIsUnfinished() async throws {
        defer { temp.remove() }
        let source = photos(.multiple, [cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/takeout-1.zip", "one", modified: start.addingTimeInterval(-600))
        try temp.file("Downloads/takeout-2.zip.crdownload", "tw", modified: start)

        #expect(try await coordinator.confirmPickup(sourceId: source.id).runs.isEmpty)
        #expect(temp.exists("Downloads/takeout-1.zip"))
    }

    @Test func manualExportWaitsInPendingUntilDiskReturns() async throws {
        defer { temp.remove() }
        let source = photos(.single, [cloud, disk])
        try store.saveConfig(Config(sources: [source], destinations: [cloud, disk]))
        try temp.file("Downloads/takeout-1.zip", "zip", modified: start.addingTimeInterval(-60))

        _ = try await coordinator.tick()
        #expect(temp.names(in: "cloud/photos") == ["2026-09-28_100000"])
        #expect(temp.names(in: "trash").isEmpty)
        #expect(temp.names(in: "work/pending/\(source.id.uuidString)") == ["2026-09-28_100000"])

        time.advance(5 * 86_400)
        try temp.directory("hdd")
        _ = try await coordinator.tick()
        #expect(temp.names(in: "hdd/photos") == ["2026-09-28_100000"])
        #expect(temp.names(in: "trash") == ["takeout-1.zip"])
        #expect(!temp.exists("work/pending/\(source.id.uuidString)"))
    }

    @Test func runNowIgnoresScheduleAndSameDayCopiesCollapseToNewest() async throws {
        defer { temp.remove() }
        let source = vault([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        _ = try await coordinator.tick()
        time.advance(60)
        #expect(try await coordinator.runNow(sourceId: source.id).runs.map(\.trigger) == [.manual])
        time.advance(60)
        #expect(try await coordinator.runAllNow().runs.count == 1)
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_100200"])
        #expect(store.loadRuns().count == 3)
    }

    @Test func corruptedConfigStopsTheTick() async throws {
        defer { temp.remove() }
        try temp.file("data/config.json", "{ broken")
        await #expect(throws: StoreError.corrupted(file: "config.json")) { try await coordinator.tick() }
    }

    @Test func failingCatchUpIsRetriedOncePerHour() async throws {
        defer { temp.remove() }
        let source = Fixtures.source(kind: .folder(path: temp.path("moved").path, excludes: []), destinations: [disk], createdAt: created)
        try store.saveConfig(Config(sources: [source], destinations: [disk]))
        _ = try await coordinator.tick()
        try temp.directory("hdd")

        time.advance(60)
        #expect(try await coordinator.tick().runs.map(\.trigger) == [.catchUp])
        time.advance(60)
        #expect(try await coordinator.tick() == TickResult())
        time.advance(3600)
        #expect(try await coordinator.tick().runs.count == 1)
    }

    @Test func brokenPickupIsReportedAndDoesNotBlockOtherBackups() async throws {
        let locked = try temp.file("Downloads/takeout-1.zip", "zip", modified: start.addingTimeInterval(-60))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
            temp.remove()
        }
        let photos = photos(.single, [cloud])
        try store.saveConfig(Config(sources: [photos, vault([cloud])], destinations: [cloud]))

        let result = try await coordinator.tick()
        #expect(result.runs.map(\.trigger) == [.pickup, .scheduled])
        #expect(result.runs[0].collectError?.hasPrefix("Не удалось забрать файлы") == true)
        #expect(result.notices.count == 1)
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_100000"])
        #expect(temp.exists("Downloads/takeout-1.zip"))
        #expect(!temp.exists("work/pending/\(photos.id.uuidString)"))

        time.advance(60)
        #expect(try await coordinator.tick().runs.isEmpty)
    }

    @Test func sourceWhoseDestinationsWereDeletedIsNeitherRunNorGreen() async throws {
        defer { temp.remove() }
        let source = vault([cloud])
        try store.saveConfig(Config(sources: [source], destinations: []))

        #expect(try await coordinator.tick() == TickResult())
        #expect(try await coordinator.runNow(sourceId: source.id) == TickResult())
        #expect(store.loadRuns().isEmpty)
        #expect(try store.loadState().sourceState(source.id).lastRun == nil)
        #expect(try await coordinator.statusReport().items == [.noDestinations(sourceId: source.id)])
    }

    @Test func announcesTheQueueBeforeRunningIt() async throws {
        defer { temp.remove() }
        let first = vault([cloud])
        let second = Fixtures.source(name: "Второй", kind: .folder(path: temp.path("vault").path, excludes: []), destinations: [cloud], createdAt: created)
        try store.saveConfig(Config(sources: [first, second], destinations: [cloud]))

        _ = try await coordinator.tick()
        #expect(events.get() == [
            .queued(sourceIds: [first.id, second.id]),
            .collecting(sourceId: first.id),
            .delivering(sourceId: first.id, destinationId: cloud.id),
            .finished(sourceId: first.id),
            .collecting(sourceId: second.id),
            .delivering(sourceId: second.id, destinationId: cloud.id),
            .finished(sourceId: second.id),
        ])

        events.set([])
        time.advance(60)
        _ = try await coordinator.tick()
        #expect(events.get().isEmpty)

        _ = try await coordinator.runAllNow()
        #expect(events.get().first == .queued(sourceIds: [first.id, second.id]))
    }
}

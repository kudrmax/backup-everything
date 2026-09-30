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
        let chains = StepChainRunner(
            chainsRoot: temp.path("work/chains"),
            inbox: inbox,
            runner: runner,
            time: time,
            trash: { url in try FileManager.default.moveItem(at: url, to: temp.path("trash/\(url.lastPathComponent)")) },
            progress: { [events] event in events.set(events.get() + [event]) }
        )
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
            chains: chains,
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

    @Test func deletedCopiesAreNoticedAndRestored() async throws {
        defer { temp.remove() }
        let source = vault([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        _ = try await coordinator.tick()
        try FileManager.default.removeItem(at: temp.path("cloud/obsidian"))

        time.advance(600)
        let result = try await coordinator.tick()
        #expect(result.notices == [.copiesMissing(sourceId: source.id, sourceName: "Obsidian", destinationName: "Cloud")])
        #expect(result.runs.map(\.trigger) == [.catchUp])
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_101000"])
        #expect(try store.loadState().sourceState(source.id).lastSuccess == start.addingTimeInterval(600))

        time.advance(600)
        #expect(try await coordinator.tick() == TickResult())
    }

    @Test func deletingOnlyTheLatestCopyIsNoticedToo() async throws {
        defer { temp.remove() }
        let source = vault([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        _ = try await coordinator.tick()
        time.advance(86_400)
        _ = try await coordinator.tick()
        try FileManager.default.removeItem(at: temp.path("cloud/obsidian/2026-09-29_100000"))

        time.advance(600)
        let result = try await coordinator.tick()
        #expect(result.notices == [.copiesMissing(sourceId: source.id, sourceName: "Obsidian", destinationName: "Cloud")])
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_100000", "2026-09-29_101000"])
    }

    @Test func copiesMadeBeforeTrackingAreVerifiedThroughHistory() async throws {
        defer { temp.remove() }
        let source = vault([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        _ = try await coordinator.tick()
        var legacy = try store.loadState()
        legacy.lastDelivered = [:]
        try store.saveState(legacy)
        try FileManager.default.removeItem(at: temp.path("cloud/obsidian"))

        time.advance(600)
        let result = try await coordinator.tick()
        #expect(result.notices == [.copiesMissing(sourceId: source.id, sourceName: "Obsidian", destinationName: "Cloud")])
    }

    @Test func newlyAttachedDestinationGetsItsCopyRightAway() async throws {
        defer { temp.remove() }
        var source = vault([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        _ = try await coordinator.tick()

        try temp.directory("second")
        let second = Fixtures.localDestination("Second", at: temp.path("second"))
        source.destinationIds.append(second.id)
        try store.saveConfig(Config(sources: [source], destinations: [cloud, second]))

        time.advance(600)
        let result = try await coordinator.tick()
        #expect(result.notices.isEmpty)
        #expect(result.runs.map(\.trigger) == [.catchUp])
        #expect(temp.names(in: "second/obsidian") == ["2026-09-28_101000"])
        #expect(temp.names(in: "cloud/obsidian") == ["2026-09-28_100000"])
    }

    private func claude(_ destinations: [Destination], command: String = #"cp "$BACKUP_INPUT_DIR"/manifest-a.json "$BACKUP_OUTPUT_DIR/archive.zip""#) -> Source {
        Fixtures.source(
            name: "Claude",
            kind: .steps(steps: [
                SourceStep(name: "Запросить экспорт", kind: .manual(instructions: "", watchPath: temp.path("Downloads").path, filePattern: "manifest-*.json", includeInCopy: false)),
                SourceStep(name: "Скачать архивы", kind: .command(command: command, timeoutSeconds: 60)),
            ]),
            schedule: .monthly,
            destinations: destinations,
            createdAt: created
        )
    }

    @Test func stepChainDeliversWhatItsCommandProduced() async throws {
        defer { temp.remove() }
        let source = claude([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))

        #expect(try await coordinator.tick().runs.isEmpty)

        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))
        let result = try await coordinator.tick()

        #expect(result.runs.map(\.trigger) == [.pickup])
        #expect(result.runs.first?.firstFailure == nil)
        #expect(temp.names(in: "cloud/claude/2026-09-28_100000") == ["_snapshot.json", "archive.zip"])
        #expect(temp.names(in: "Downloads").isEmpty)
        #expect(temp.names(in: "trash").sorted() == ["archive.zip", "manifest-a.json"])
        let state = try store.loadState().sourceState(source.id)
        #expect(state.chain == nil)
        #expect(state.lastPickup == start)
        #expect(state.lastRun == start)
        #expect(try await coordinator.statusReport().overall == .ok)
        #expect(events.get().contains(.step(sourceId: source.id, index: 1, count: 2)))
        #expect(events.get().last == .finished(sourceId: source.id))
    }

    @Test func failedStepIsRecordedOnceAndWaitsForTheUser() async throws {
        defer { temp.remove() }
        let source = claude([cloud], command: "echo 'Не скачались архивы: a.zip' >&2; exit 1")
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))

        let failed = try await coordinator.tick()
        let message = try #require(failed.runs.first?.collectError)
        #expect(failed.runs.count == 1)
        #expect(message.hasPrefix("Шаг 2 из 2 «Скачать архивы». Команда завершилась с кодом 1."))
        #expect(message.hasSuffix("Не скачались архивы: a.zip"))
        #expect(failed.notices.contains(.runFailed(sourceId: source.id, sourceName: "Claude", message: message)))
        #expect(store.loadRuns().count == 1)
        let stuck = try store.loadState().sourceState(source.id)
        #expect(stuck.chain?.stepIndex == 1)
        #expect(stuck.chain?.failure?.hasPrefix("Команда завершилась с кодом 1.") == true)
        #expect(stuck.lastError == nil)
        #expect(stuck.retryAfter == nil)
        #expect(events.get().last == .finished(sourceId: source.id))

        time.advance(2 * 3600)
        #expect(try await coordinator.tick().runs.isEmpty)
        #expect(try await coordinator.runAllNow().runs.isEmpty)
        #expect(store.loadRuns().count == 1)

        #expect(try await coordinator.runNow(sourceId: source.id).runs.count == 1)
        #expect(store.loadRuns().count == 2)

        _ = try await coordinator.restartChain(sourceId: source.id)
        #expect(try store.loadState().sourceState(source.id).chain == nil)
        #expect(temp.names(in: "trash") == ["manifest-a.json"])
        #expect(!temp.exists("work/chains/\(source.id.uuidString)"))
    }

    @Test func chainPositionIsSavedBeforeTheCommandRuns() async throws {
        defer { temp.remove() }
        let stateFile = store.stateURL.path
        let source = claude([cloud], command: #"grep -q '"stepIndex" : 1' '\#(stateFile)' && echo saved > "$BACKUP_OUTPUT_DIR/ok.txt""#)
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))

        let result = try await coordinator.tick()
        #expect(result.runs.first?.firstFailure == nil)
        #expect(temp.exists("cloud/claude/2026-09-28_100000/ok.txt"))
    }

    @Test func chainWithoutDestinationsLeavesTheFileAlone() async throws {
        defer { temp.remove() }
        let source = claude([])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))

        #expect(try await coordinator.tick().runs.isEmpty)
        #expect(temp.names(in: "Downloads") == ["manifest-a.json"])
        #expect(try store.loadState().sourceState(source.id).chain == nil)
    }

    @Test func finishedChainCatchesUpAnUnpluggedDiskFromPending() async throws {
        defer { temp.remove() }
        let source = claude([cloud, disk])
        try store.saveConfig(Config(sources: [source], destinations: [cloud, disk]))
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))

        _ = try await coordinator.tick()
        #expect(temp.names(in: "cloud/claude") == ["2026-09-28_100000"])
        #expect(try store.loadState().debts.map(\.destinationId) == [disk.id])
        #expect(temp.names(in: "work/pending/\(source.id.uuidString)") == ["2026-09-28_100000"])

        time.advance(86_400)
        try temp.directory("hdd")
        let caughtUp = try await coordinator.tick()
        #expect(caughtUp.runs.map(\.trigger) == [.catchUp])
        #expect(temp.names(in: "hdd/claude") == ["2026-09-28_100000"])
        #expect(try store.loadState().debts.isEmpty)
        #expect(!temp.exists("work/pending/\(source.id.uuidString)"))
    }

    @Test func chainThatOpensWithACommandStartsOnSchedule() async throws {
        defer { temp.remove() }
        let source = Fixtures.source(
            name: "Отчёт",
            kind: .steps(steps: [SourceStep(name: "Собрать", kind: .command(command: #"echo data > "$BACKUP_OUTPUT_DIR/report.txt""#, timeoutSeconds: 60))]),
            schedule: .daily,
            destinations: [cloud],
            createdAt: created
        )
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))

        #expect(try await coordinator.tick().runs.map(\.trigger) == [.pickup])
        #expect(temp.names(in: "cloud/отчёт") == ["2026-09-28_100000"])

        time.advance(3600)
        #expect(try await coordinator.tick().runs.isEmpty)
        time.advance(23 * 3600)
        #expect(try await coordinator.tick().runs.count == 1)
    }

    @Test func idleChainRemindsAboutItsFirstManualStep() async throws {
        defer { temp.remove() }
        let source = claude([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))

        let idle = try await coordinator.tick()
        #expect(idle.runs.isEmpty)
        #expect(idle.notices == [.manualExportDue(sourceId: source.id, sourceName: "Claude")])
        #expect(try await coordinator.statusReport().items == [.manualExportDue(sourceId: source.id)])

        time.advance(3600)
        #expect(try await coordinator.tick().notices.isEmpty)
    }

    @Test func finishedChainOwesItsPackageUntilItIsDelivered() async throws {
        defer { temp.remove() }
        let source = claude([cloud], command: #"mkdir "$BACKUP_OUTPUT_DIR/empty""#)
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))

        let result = try await coordinator.tick()

        #expect(result.runs.first?.collectError == SourceError.emptyResult.localizedDescription)
        #expect(try store.loadState().debts.map(\.destinationId) == [cloud.id])
        #expect(temp.names(in: "work/pending/\(source.id.uuidString)") == ["2026-09-28_100000"])
    }

    @Test func scheduledSourcesRunBeforeStepChains() async throws {
        defer { temp.remove() }
        try store.saveConfig(Config(sources: [claude([cloud]), vault([cloud])], destinations: [cloud]))
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))

        #expect(try await coordinator.tick().runs.map(\.sourceName) == ["Obsidian", "Claude"])
    }

    @Test func newManifestHeldBackByAnUnfinishedDownloadIsReported() async throws {
        defer { temp.remove() }
        let source = claude([cloud], command: "exit 1")
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        try temp.file("Downloads/manifest-a.json", "{}", modified: start.addingTimeInterval(-60))
        #expect(try await coordinator.tick().runs.count == 1)

        time.advance(600)
        try temp.file("Downloads/manifest-b.json", "{}", modified: start.addingTimeInterval(300))
        let leftover = try temp.file("Downloads/conversations-000.zip.crdownload", "partial", modified: start.addingTimeInterval(300))
        #expect(try await coordinator.tick().runs.isEmpty)
        #expect(try await coordinator.statusReport().items == [
            .filesAwaitingPickup(sourceId: source.id, fileCount: 1, totalBytes: 2, downloadInProgress: true),
        ])

        try FileManager.default.removeItem(at: leftover)
        #expect(try await coordinator.tick().runs.count == 1)
        #expect(temp.names(in: "work/chains/\(source.id.uuidString)/input") == ["manifest-b.json"])
    }

    @Test func workFilesOfDeletedSourcesGoToTheTrash() async throws {
        defer { temp.remove() }
        let kept = claude([cloud])
        let gone = UUID()
        let goneExport = UUID()
        try store.saveConfig(Config(sources: [kept], destinations: [cloud]))
        var state = AppState()
        state.updateSource(kept.id) {
            $0.chain = ChainState(stepIndex: 1, stepId: kept.steps[1].id, startedAt: start, stepEnteredAt: start, failure: "ждёт повтора")
        }
        try store.saveState(state)
        try temp.file("work/chains/\(kept.id.uuidString)/input/manifest-kept.json", "{}")
        try temp.file("work/chains/\(gone.uuidString)/input/manifest-old.json", "{}")
        try temp.file("work/pending/\(goneExport.uuidString)/2026-09-27_100000/archive.zip", "zip")
        try temp.directory("work/pending/.incoming-\(UUID().uuidString)")

        _ = try await coordinator.tick()

        #expect(temp.names(in: "trash") == ["archive.zip", "manifest-old.json"])
        #expect(temp.names(in: "work/chains") == [kept.id.uuidString])
        #expect(temp.names(in: "work/pending").count == 1)
    }
}

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
                providers: DefaultSourceProviderFactory(runner: runner, stagingRoot: temp.path("work/staging"), inbox: inbox, trash: trash),
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

    // MARK: Facts belong to a place

    /// A copy proven in the old folder says nothing about the new one: until a copy is proven there, the source is not
    /// fresh, and the check copies it there at once, without a “Copy missing” notice.
    @Test func movedFolderForgetsTheCopiesOfItsOldPlace() async throws {
        defer { temp.remove() }
        var first = try local("First")
        let source = weekly([first])
        try store.saveConfig(Config(sources: [source], destinations: [first]))
        _ = try await coordinator.tick()
        #expect(try await coordinator.statusReport().overall == .ok)

        try temp.directory("moved")
        first.kind = .localFolder(path: temp.path("moved").path)
        try store.saveConfig(Config(sources: [source], destinations: [first]))
        time.advance(600)
        let current = try await coordinator.currentStatus()
        #expect(current.state.deliveredCopyDate(sourceId: source.id, destinationId: first.id) == nil)
        #expect(current.state.lastDeliveredSnapshot(sourceId: source.id, destinationId: first.id) == nil)
        #expect(current.report.overall == .attention)
        #expect(!current.report.fresh.contains(source.id))

        let result = try await coordinator.tick()
        #expect(result.notices.isEmpty)
        #expect(result.runs.map(\.trigger) == [.catchUp])
        #expect(temp.names(in: "moved/obsidian").count == 1)
        #expect(try await coordinator.statusReport().overall == .ok)
    }

    /// Another remote or folder in the cloud is another place: it is checked right away, not a day after the old one was.
    @Test func cloudPointedElsewhereIsCheckedAndCopiedToAtOnce() async throws {
        defer { temp.remove() }
        _ = try #require(RcloneLocator().find(), "rclone is required: brew install rclone")
        try temp.directory("remote")
        try temp.directory("remote2")
        var cloud = Destination(name: "Cloud", kind: .rclone(remote: ":local", path: temp.path("remote").path))
        let source = weekly([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        _ = try await coordinator.tick()

        cloud.kind = .rclone(remote: ":local", path: temp.path("remote2").path)
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        time.advance(600)
        #expect(try await coordinator.statusReport().overall == .attention)

        let result = try await coordinator.tick()
        #expect(result.notices.isEmpty)
        #expect(result.runs.map(\.trigger) == [.catchUp])
        #expect(temp.names(in: "remote2/obsidian").count == 1)
        #expect(try await coordinator.statusReport().overall == .ok)
    }

    /// The name and the rhythm of a destination are not its place: its copies stay known.
    @Test func renamedDestinationKeepsItsCopies() async throws {
        defer { temp.remove() }
        var first = try local("First")
        let source = weekly([first])
        try store.saveConfig(Config(sources: [source], destinations: [first]))
        _ = try await coordinator.tick()

        first.name = "Renamed"
        first.expectedEvery = .days(7)
        try store.saveConfig(Config(sources: [source], destinations: [first]))
        time.advance(600)
        #expect(try await coordinator.tick() == TickResult())
        #expect(try await coordinator.statusReport().overall == .ok)
        #expect(try store.loadState().deliveredCopyDate(sourceId: source.id, destinationId: first.id) == start)
    }

    /// A destination taken off a source and added back still holds its copy: the check finds it there and the copy counts
    /// again at once, instead of “no copy yet” until the next backup.
    @Test func destinationAddedBackWithItsCopyCountsAtOnce() async throws {
        defer { temp.remove() }
        let first = try local("First")
        let second = try local("Second")
        var source = weekly([first, second])
        try store.saveConfig(Config(sources: [source], destinations: [first, second]))
        _ = try await coordinator.tick()

        source.destinationIds = [first.id]
        try store.saveConfig(Config(sources: [source], destinations: [first, second]))
        time.advance(600)
        _ = try await coordinator.tick()
        #expect(try store.loadState().deliveredCopyDate(sourceId: source.id, destinationId: second.id) == nil)

        source.destinationIds = [first.id, second.id]
        try store.saveConfig(Config(sources: [source], destinations: [first, second]))
        time.advance(600)
        let result = try await coordinator.tick()

        #expect(result == TickResult())
        let state = try store.loadState()
        #expect(state.deliveredCopyDate(sourceId: source.id, destinationId: second.id) == start)
        #expect(state.lastDeliveredSnapshot(sourceId: source.id, destinationId: second.id) == "2026-09-28_100000")
        #expect(try await coordinator.statusReport().overall == .ok)
    }

    /// Copies of another source with the same folder name are not this source's copy.
    @Test func destinationAddedBackWithOnlyAnotherSourcesCopyGetsItsOwn() async throws {
        defer { temp.remove() }
        let first = try local("First")
        let second = try local("Second")
        let source = weekly([first])
        try temp.file("second/obsidian/2026-09-27_100000/a.md", "foreign")
        try temp.file("second/obsidian/2026-09-27_100000/_snapshot.json", """
        {"sourceId":"\(UUID().uuidString)","sourceName":"Other","collectedAt":"2026-09-27T10:00:00Z","fileCount":1,"totalBytes":7}
        """)
        try store.saveConfig(Config(sources: [source], destinations: [first, second]))
        _ = try await coordinator.tick()

        var added = source
        added.destinationIds.append(second.id)
        try store.saveConfig(Config(sources: [added], destinations: [first, second]))
        time.advance(600)
        let result = try await coordinator.tick()

        #expect(result.notices.isEmpty)
        #expect(result.runs.map(\.trigger) == [.catchUp])
        #expect(temp.names(in: "second/obsidian").count == 2)
    }

    // MARK: Catch-up and a failing source

    /// The vault can no longer be read, so the scheduled backup fails. A catch-up copy of yesterday's snapshot to a newly
    /// added disk must not make the source green and must not cancel the hourly retry of the failed backup.
    @Test func catchUpOfAnOldCopyDoesNotHideThatTheSourceItselfFails() async throws {
        defer { temp.remove() }
        let cloud = try local("Cloud")
        var source = vault([cloud])
        try store.saveConfig(Config(sources: [source], destinations: [cloud]))
        _ = try await coordinator.tick()

        time.advance(86_400)
        try FileManager.default.moveItem(at: temp.path("vault"), to: temp.path("vault-moved"))
        let failed = try await coordinator.tick()
        #expect(failed.runs.first?.collectError != nil)
        #expect(try await coordinator.statusReport().overall == .error)
        let retryAt = time.now.addingTimeInterval(SchedulePlanner.retryInterval)
        #expect(try await coordinator.nextWake() == retryAt)

        time.advance(600)
        let second = try local("Second")
        source.destinationIds.append(second.id)
        try store.saveConfig(Config(sources: [source], destinations: [cloud, second]))
        #expect(try await coordinator.tick().runs.map(\.trigger) == [.catchUp])

        #expect(try await coordinator.statusReport().overall == .error)
        #expect(try await coordinator.nextWake() == retryAt)

        try FileManager.default.moveItem(at: temp.path("vault-moved"), to: temp.path("vault"))
        time.advance(3000)
        #expect(try await coordinator.tick().runs.map(\.trigger) == [.scheduled])
        #expect(try await coordinator.statusReport().overall == .ok)
    }

    // MARK: Disabled sources

    /// A disabled source is neither collected nor caught up, so connecting the disk would not pay its debt:
    /// the app must not keep asking to connect the disk every day.
    @Test func disabledSourceDoesNotKeepAskingToConnectTheDisk() async throws {
        defer { temp.remove() }
        let disk = Fixtures.localDestination("Disk", at: temp.path("disk"), expectedEvery: .days(30))
        var source = vault([disk])
        try store.saveConfig(Config(sources: [source], destinations: [disk]))
        _ = try await coordinator.tick()
        #expect(try store.loadState().debts.count == 1)

        source.enabled = false
        try store.saveConfig(Config(sources: [source], destinations: [disk]))

        time.advance(86_400 + 60)
        let result = try await coordinator.tick()
        #expect(!result.notices.contains { if case .connectDestination = $0 { true } else { false } })
        #expect(try await coordinator.statusReport().items.isEmpty)
        #expect(try await coordinator.nextWake() == nil)
        #expect(try store.loadState().debts.count == 1)
    }

    /// The debt waits while the source is disabled: once it is enabled again, the disk is asked for and caught up.
    @Test func reenabledSourceCatchesUpTheDiskItStillOwes() async throws {
        defer { temp.remove() }
        let disk = Fixtures.localDestination("Disk", at: temp.path("disk"), expectedEvery: .days(30))
        var source = weekly([disk])
        try store.saveConfig(Config(sources: [source], destinations: [disk]))
        _ = try await coordinator.tick()
        source.enabled = false
        try store.saveConfig(Config(sources: [source], destinations: [disk]))
        time.advance(86_400)
        _ = try await coordinator.tick()

        source.enabled = true
        try store.saveConfig(Config(sources: [source], destinations: [disk]))
        time.advance(60)
        let reminded = try await coordinator.tick()
        #expect(reminded.notices.contains { if case .connectDestination = $0 { true } else { false } })

        try temp.directory("disk")
        time.advance(60)
        let caughtUp = try await coordinator.tick()
        #expect(caughtUp.runs.map(\.trigger) == [.catchUp])
        #expect(caughtUp.notices.contains(.destinationCaughtUp(destinationId: disk.id, destinationName: "Disk")))
        #expect(try store.loadState().debts.isEmpty)
    }
}
